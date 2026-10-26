//
//  RoomManager.swift
//  ChatSecureCore
//
//  Created by Chris Ballinger on 11/17/17.
//  Copyright © 2017 Chris Ballinger. All rights reserved.
//

import Foundation
import GRDB

public extension GlacierXMPPRoomManager {
    
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
                        // A group we just learned about has no messages yet, so it
                        // would sort to the bottom of the chat list by last activity
                        // and be easy to miss. Date it from when we discovered it.
                        thread.messageDate = Date()
                        
                        if let accountId = self.accountId, let acct = try ChatAccountModel.getXMPPAccount(uniqueId: accountId, transaction: transaction), let aid = acct.grdbRecord?.id {
                            thread.accountUniqueId = aid
                        }
                        //let threadModel = ChatThreadModel(thread: thread)
                        thread.grdbSave(transaction: transaction)
                    
                        if let rethread = try ChatThread.getChatThread(uniqueId: room.uniqueId, transaction: transaction) {
                            room.chatThreadId = rethread.id!
                            room.grdbRecord?.grdbSave(transaction: transaction)
                            rethread.touch(transaction: transaction)
                            rooms.append(room)
                            //self.performBlock(async: true) {
                            //    self.join(room: room)
                            //}
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
        
        //self.joinRooms(rooms)
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
    
    /// Applies bookmarks read from the server, whether from an explicit fetch or
    /// a live PEP event.
    ///
    /// Additive on purpose: a bookmark can create and join a room here, and can
    /// never remove one. `autojoin="false"` means "bookmarked, don't join", so
    /// those items are skipped rather than acted on.
    @objc func handleIncomingConferenceBookmarks(_ bookmarks: [XMPPConferenceBookmark]) {
        let joinable = bookmarks.filter { $0.autoJoin }
        let skipped = bookmarks.count - joinable.count
        if skipped > 0 {
            DDLogInfo("Bookmarks 2: skipped \(skipped) bookmark(s) with autojoin=false")
        }
        guard !joinable.isEmpty else { return }
        handleIncomingBookmarks(joinable)
    }
    
    /// Publishes a bookmark for every local room of this account except the
    /// given bare JIDs. Used to upstream rooms the bookmarks node doesn't have.
    @objc(publishLocalRoomBookmarksExcluding:)
    func publishLocalRoomBookmarks(excluding excludedJIDs: [String]) {
        guard let accountId = self.accountId else { return }
        let excluded = Set(excludedJIDs)
        var bookmarks: [XMPPConferenceBookmark] = []
        ChatRoomModel.allXMPPRooms(for: accountId).forEach { room in
            guard let jid = room.roomJID?.bare, !excluded.contains(jid),
                  let bookmark = room.bookmark else { return }
            bookmarks.append(bookmark)
        }
        guard !bookmarks.isEmpty else { return }
        DDLogInfo("Bookmarks 2: publishing \(bookmarks.count) local room bookmark(s)")
        bookmarks2Module?.publishBookmarks(bookmarks)
    }
    
    @objc func addRoomsToBookmarks(_ rooms: [ChatRoomModel]) {
        publishConferenceBookmarks(rooms.compactMap { $0.bookmark })
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
        let jids = bookmarks.compactMap { $0.jid }
        guard !jids.isEmpty else { return }
        // Per-item retract. XEP-0048 was a whole-document replace, so two
        // devices writing at once silently lost one of the updates.
        bookmarks2Module?.retractBookmarks(for: jids)
    }
    
    @objc func fetchHistory(for xmppRoom: XMPPRoom) {
        if let room = ChatRoomModel.fetch(xmppRoom: xmppRoom) {
            if let dateToFetch = room.grdbRecord?.lastHistoryFetch {
                //NSLog("***** fetchHistory for \(xmppRoom.roomJID) from \(dateToFetch)")
                self.archiving.fetchHistory(archiveJID: xmppRoom.roomJID, userJID: nil, since: dateToFetch)
            } else {
                //NSLog("***** did not find lastHistoryFetchDate for \(xmppRoom.roomJID)")
                let currentDate = Date()
                var dateComponents = DateComponents()
                dateComponents.day = -7
                let lastWeek = Calendar.current.date(byAdding: dateComponents, to: currentDate)!
                //dateToFetch = lastWeek
                self.archiving.fetchHistory(archiveJID: xmppRoom.roomJID, userJID: nil, since: lastWeek)
            }
            
            room.grdbRecord?.lastHistoryFetch = Date()
            room.saveThread()
        }
    }
}

