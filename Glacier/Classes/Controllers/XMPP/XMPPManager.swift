//
//  XMPPManager.swift
//  ChatSecureCore
//
//  Created by Chris Ballinger on 11/27/17.
//  Copyright © 2017 Chris Ballinger. All rights reserved.
//

import Foundation
import XMPPFramework

@objc public extension XMPPStream {
    /// Stream tags should be the ChatAccount uniqueId
    @objc var accountId: String? {
        return tag as? String
    }
}

public extension XMPPModule {
    /// key for Account
    var accountId: String? {
        return xmppStream?.accountId
    }
    
    func xmppAccount() -> ChatAccountModel? {
        guard let accountId = self.accountId,
              let account = ChatAccountModel.getXMPPAccount(uniqueId: accountId) else {
                return nil
        }
        return account
    }
    
    func xmppAccount(_ transaction: GRDBReadTransaction) -> ChatAccountModel? {
        guard let accountId = self.accountId,
              let account = ChatAccountModel.getXMPPAccount(uniqueId: accountId, transaction: transaction) else {
                return nil
        }
        return account
    }
}


public extension XMPPMessageArchiveManagement {
    @objc func fetchHistory(archiveJID: XMPPJID? = nil, userJID: XMPPJID? = nil, since: Date? = nil) {
        
        var fields: [XMLElement] = []
        
        if let userJID = userJID {
            let with = XMPPMessageArchiveManagement.field(withVar: "with", type: nil, andValue: userJID.bare)
            fields.append(with)
        }
        
        if let since = since {
            //NSLog("***** fetchHistory since \(since)")
            let xmppDateString = (since as NSDate).xmppDateTimeString
            
            let start = XMPPMessageArchiveManagement.field(withVar: "start", type: nil, andValue: xmppDateString)
            fields.append(start)
        }
        //print("***** retrieving \(archiveJID ?? xmppStream?.myJID?.bareJID) from \(since)")
        retrieveMessageArchive(at: archiveJID ?? xmppStream?.myJID?.bareJID, withFields: fields, with: nil)
    }
    
    /*@objc func fetchLatestMessage() {
        retrieveMyLatestMessageArchive()
    }*/
    

    /** Fetches history for a thread after the most recent message */
    @objc func fetchHistoryForThread(_ thread: ChatThreadModel) {
        var archiveJID: XMPPJID? = nil
        var userJID: XMPPJID? = nil
        var lastMessageDate: Date? = nil
        
        if thread.isGroupThread() {
            if let room = ChatRoom.roomFromThread(thread.grdbRecord!) {
                let roomModel = ChatRoomModel(room: room)
                archiveJID = roomModel.roomJID
                if let lastMsgId = thread.lastMessageIdentifier, let message = ChatRoomMessageModel.getMessage(with: lastMsgId) {
                    lastMessageDate = message.messageDate
                }
                
            }
        } else {
            if let bud = ChatBuddy.buddyFromThread(thread.grdbRecord!), let account = xmppAccount() {
                let budModel = ChatBuddyModel(buddy: bud)
                userJID = budModel.bareJID
                archiveJID = account.bareJID
                if let lastMsgId = thread.lastMessageIdentifier, let message = ChatMessageModel.getMessage(with: lastMsgId) {
                    lastMessageDate = message.messageDate
                }
            }
        }

        fetchHistory(archiveJID: archiveJID, userJID: userJID, since: lastMessageDate)
    }
}

#if !TARGET_IS_EXTENSION
/// Formerly known in Obj-C as OTRXMPPManager
public extension XMPPManager {
    @objc func disconnectBuddiesAndRooms(_ shouldDisconnectBuddies:Bool) {
        //Reset buddy info to offline
        let acctId = self.chatAccount.uniqueId
        var allRooms:[ChatRoomModel]?
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            if shouldDisconnectBuddies == true {
                let allBuddies = ChatBuddyModel.getAllBuddies(for: acctId, transaction: transaction)
                for buddy in allBuddies {
                    self.disconnectBuddy(buddy, transaction: transaction)
                }
                //if (!self.streamManagementDelegate.streamManagementEnabled) {
                //    BuddyCache.shared().purgeAllProperties(buddies: allBuddies)
                //}
            }
            
            let rooms = ChatRoomModel.allXMPPRooms(for: acctId, transaction: transaction)
            //xmppRoomDidLeave
            for room in rooms {
                let allOccs = ChatRoomOccupantModel.allXMPPRoomOccupants(for: room.uniqueId, transaction: transaction)
                for occ in allOccs {
                    occ.role = .none
                    occ.grdbRecord?.grdbSave(transaction: transaction)
                }
            }
            allRooms = rooms
        }, completionQueue: self.workQueue, completion: {
            if let allRooms = allRooms {
                BuddyCache.shared().purgeAllProperties(rooms: allRooms)
                
                DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                    for room in allRooms {
                        room.grdbRecord?.touch(transaction)
                    }
                })
            }
        })
    }
    
    func disconnectBuddy(_ buddy: ChatBuddyModel, transaction: GRDBReadTransaction) {
        let newStatus:ThreadStatus = .offline
        BuddyCache.shared().setStatusMessage(OFFLINE_STRING(), buddyId: buddy.uniqueId)
        BuddyCache.shared().setChatState(.gone, buddyId:buddy.uniqueId)
        BuddyCache.shared().setThreadStatus(.offline, buddyId: buddy.uniqueId, resource:nil)
        buddy.touchBuddy(transaction)
    }
    
    @objc func getPausedMessage(_ buddyUniqueId:String) -> XMPPMessage? {
        //var xMessage:XMPPMessage?

        guard let buddy = ChatBuddyModel.getBuddy(uniqueId: buddyUniqueId) else { return nil }
        if buddy.lastSentChatState() == .paused {
            return nil
        }
        let xMessage = XMPPMessage(type: "chat", to: XMPPJID(string: buddy.username))
        xMessage.addPausedChatState()
        BuddyCache.shared().setLastSentChatState(.paused, buddy: buddy)
        return xMessage
    }
    
    @objc func getInactiveMessage(_ buddyUniqueId:String) -> XMPPMessage? {
        //var xMessage:XMPPMessage?
        guard let buddy = ChatBuddyModel.getBuddy(uniqueId: buddyUniqueId) else { return nil }
        if buddy.lastSentChatState() == .inactive {
            return nil
        }
        let xMessage = XMPPMessage(type: "chat", to: XMPPJID(string: buddy.username))
            
        if BuddyCache.shared().lastSentChatState(buddy: buddy) != .inactive {
            xMessage.addInactiveChatState()
            BuddyCache.shared().setLastSentChatState(.inactive, buddy: buddy)
        } else {
            return nil
        }
        return xMessage
    }
    
    /*@objc func getChatStateToSend(_ chatState: ChatState, buddyUniqueId:String) -> XMPPMessage? {
        var xMessage:XMPPMessage?
        if !(self.loginStatus == OTRLoginStatus.authenticated) {
            return
        }
        
        self.workQueue.async {
            guard let buddy = ChatBuddyModel.getBuddy(uniqueId: buddyUniqueId) else { return }
            if buddy.lastSentChatState() == chatState {
                return
            }
            let xMessage = XMPPMessage(type: "chat", to: XMPPJID(string: buddy.username))
            var shouldSend = true
            
            if chatState == .active {
                //Timers
                DispatchQueue.main.async {
                    self.pausedChatStateTimer(forBuddyObjectID: buddy.uniqueId).invalidate()
                    self.restartInactiveChatStateTimer(forBuddyObjectID: buddyUniqueId)
                }
                
                xMessage.addActiveChatState()
            } else if chatState == .composing {
                if BuddyCache.shared().lastSentChatState(buddy: buddy) != .composing {
                    xMessage.addComposingChatState()
                } else {
                    shouldSend = false
                }
                
                //Timers
                DispatchQueue.main.async {
                    self.restartPausedChatStateTimer(forBuddyObjectID: buddy.uniqueId)
                    self.inactiveChatStateTimer(forBuddyObjectID: buddy.uniqueId).invalidate()
                }
            } else if chatState == .inactive {
                if BuddyCache.shared().lastSentChatState(buddy: buddy) != .inactive {
                    xMessage.addInactiveChatState()
                } else {
                    shouldSend = false
                }
            } else if chatState == .paused {
                xMessage.addPausedChatState()
            } else if chatState == .gone {
                xMessage.addGoneChatState()
            } else {
                shouldSend = false
            }
            
            if(shouldSend && self.loginStatus == OTRLoginStatus.authenticated)
            {
                BuddyCache.shared().setLastSentChatState(chatState, buddy: buddy)
                if let xstream = self.xmppStream {
                    xstream.sendXMLElement(xMessage)
                }
            }
        }
    }*/
}
#endif
