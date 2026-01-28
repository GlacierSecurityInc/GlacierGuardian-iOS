//  ChatSecureCore
//  Created by Chris Ballinger on 11/17/17.
//  Copyright © 2017 Chris Ballinger. All rights reserved.

import Foundation
import GRDB

public extension OTRXMPPRoomManager {
    
    @objc func join(room: ChatRoomModel) {
        guard let roomJID = room.roomJID, let roomrec = room.grdbRecord else { return }
        joinRoom(roomJID, withNickname: nil, subject: roomrec.subject, password: roomrec.roomPassword)
    }
    
    private func roomForBookmark(_ bookmark: XMPPBookmark) -> ChatRoomModel? {
        guard let conference = bookmark as? XMPPConferenceBookmark,
            let accountId = self.accountId, let jid = conference.jid?.bare else {
                return nil
        }
        let uid = accountId + jid
        let room = ChatRoomModel(uniqueId: uid, accountId: accountId, jid: jid)
        room.grdbRecord?.subject = conference.bookmarkName
        room.grdbRecord?.roomPassword = conference.password
        return room
    }
    
    private func handleIncomingBookmarks(_ bookmarks: [XMPPBookmark]) {
        var incomingRooms: [ChatRoomModel] = []
        
        bookmarks.forEach({ (bookmark) in
            if let room = self.roomForBookmark(bookmark) {
                incomingRooms.append(room)
            }
        })
        guard incomingRooms.count > 0 else {
            return
        }
        var rooms: [ChatRoomModel] = []
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            incomingRooms.forEach({ (room) in
                do {
                    // Don't overwrite existing rooms with incoming rooms
                    if let existingRoom = try ChatRoomModel.getXMPPRoom(uniqueId: room.uniqueId, transaction: transaction) {
                        rooms.append(existingRoom)
                    } else {
                        var thread = ChatThread(uniqueId: room.uniqueId)
                        thread.isGroupThread = true
                        
                        if let accountId = self.accountId, let acct = try ChatAccountModel.getXMPPAccount(uniqueId: accountId, transaction: transaction), let aid = acct.grdbRecord?.id {
                            thread.accountUniqueId = aid
                        }
                        thread.grdbSave(transaction: transaction)
                    
                        if let rethread = try ChatThread.getChatThread(uniqueId: room.uniqueId, transaction: transaction) {
                            room.chatThreadId = rethread.id!
                            room.grdbRecord?.grdbSave(transaction: transaction)
                            rethread.touch(transaction: transaction)
                            rooms.append(room)
                        }
                    }
                } catch {
                    print("Error handleIncomingBookmarks \(room.uniqueId)")
                }
            })
        }, completion: {
            self.performBlock(async: true) {
                self.joinRooms(rooms)
            }
        })
        
    }
    
    @objc func createRoomIfNeeded(_ jid:XMPPJID, accountId: String, isPublic: Bool, seedNum: Int, completion: @escaping ((_ xRoom: ChatRoomModel?)->Void)) {
        let databaseRoomKey = ChatRoomModel.createUniqueId(accountId, jid: jid.bare)
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do{
                if let xroom = try ChatRoomModel.getXMPPRoom(uniqueId: databaseRoomKey, transaction: transaction) {
                    if xroom.avatarSeedNum < 0 {
                        xroom.avatarSeedNum = xroom.nextAvatarNum(with: seedNum)
                        xroom.grdbRecord?.grdbSave(transaction: transaction)
                        completion(xroom)
                    }
                } else {
                    if let account = ChatAccountModel.getXMPPAccount(uniqueId: accountId, transaction: transaction) {
                        let xroom = ChatRoomModel(accountId: accountId, jid: jid.bare)
                        let thread = ChatThreadModel(accountId: account.accountId, uniqueId: xroom.uniqueId, isGroup: true)
                        thread.grdbRecord?.grdbSave(transaction: transaction)
                        xroom.grdbRecord?.isPublic = isPublic
                        
                        var chatThread:ChatThread?
                        do {
                            chatThread = try ChatThread.filter(Column("uniqueId") == xroom.uniqueId).fetchOne(transaction.database)
                        } catch {
                            DDLogError("RoomManager.getThread with error: \(error)")
                        }
                        
                        if var cthread = chatThread {
                            xroom.chatThreadId = cthread.id!
                            xroom.grdbRecord?.grdbSave(transaction: transaction)
                        }
                        
                        completion(xroom)
                        return
                    }
                }
            } catch {
                completion(nil)
            }
        })
    }
    
    private func joinRooms(_ rooms:[ChatRoomModel]) {
        rooms.forEach({ (room) in
            self.join(room: room)
        })
    }
    
    @objc func addRoomsToBookmarks(_ rooms: [ChatRoomModel]) {
        var bookmarks: [XMPPConferenceBookmark] = []
        rooms.forEach { (room) in
            if let bookmark = room.bookmark {
                bookmarks.append(bookmark)
            }
        }
        bookmarksModule.fetchAndPublish(bookmarksToAdd: bookmarks, completion: { (newBookmarks, responseIq) in
            guard let outBookmarks = newBookmarks else {
                DDLogError("Failed to add bookmarks \(bookmarks)")
                return
            }
            DDLogInfo("New bookmarks \(outBookmarks)")
            self.handleIncomingBookmarks(outBookmarks)
        })
    }
    
    @objc func removeRoomsFromBookmarks(_ rooms: [ChatRoomModel]) {
        var bookmarks: [XMPPConferenceBookmark] = []
        rooms.forEach { (room) in
            if let bookmark = room.bookmark {
                bookmarks.append(bookmark)
            }
        }
        self.removeRooms(from: bookmarks)
    }
    
    @objc func removeRooms(from bookmarks: [XMPPConferenceBookmark]) {
        bookmarksModule.fetchAndPublish(bookmarksToAdd: [], bookmarksToRemove: bookmarks, completion: { (newBookmarks, responseIq) in
            if let newBookmarks = newBookmarks {
                DDLogInfo("New bookmarks \(newBookmarks)")
            } else {
                DDLogWarn("Failed to remove bookmarks \(bookmarks)")
            }
        })
    }
    
    @objc func fetchHistory(for xmppRoom: XMPPRoom) {
        if let room = ChatRoomModel.fetch(xmppRoom: xmppRoom) {
            if let dateToFetch = room.grdbRecord?.lastHistoryFetch {
                self.archiving.fetchHistory(archiveJID: xmppRoom.roomJID, userJID: nil, since: dateToFetch)
            } else {
                let currentDate = Date()
                var dateComponents = DateComponents()
                dateComponents.day = -7
                let lastWeek = Calendar.current.date(byAdding: dateComponents, to: currentDate)!
                //IOSM-541 - archiveJID was nil. Which means this was being queried numerous times?
                self.archiving.fetchHistory(archiveJID: xmppRoom.roomJID, userJID: nil, since: lastWeek)
            }
            
            room.grdbRecord?.lastHistoryFetch = Date()
            room.saveThread()
        }
    }
}

