//
//  RoomStorage.swift
//  ChatSecureCore
//
//  Created by Chris Ballinger on 12/7/17.
//  Copyright © 2017 Chris Ballinger. All rights reserved.
//

import Foundation
import XMPPFramework
import GRDB

@objc public class RoomStorage: NSObject {
    
    // MARK: Properties
    private let capabilities: XMPPCapabilities
    private let fileTransfer: FileTransferManager
    private let vCardModule: XMPPvCardTempModule
    /// This is public because of a test-related circular dependency with OTROMEMOSignalCoordinator
    public var omemoModule: OMEMOModule?
    @objc public let workQueue:DispatchQueue
    
    // MARK: Init
    
    @objc public init(capabilities: XMPPCapabilities,
                      fileTransfer: FileTransferManager,
                      vCardModule: XMPPvCardTempModule,
                      omemoModule: OMEMOModule? = nil) {
        self.capabilities = capabilities
        self.fileTransfer = fileTransfer
        self.vCardModule = vCardModule
        self.omemoModule = omemoModule
        self.workQueue = DispatchQueue(label: "RoomStorage-work", attributes: [])
    }
    
    // MARK: Public
    
    /// This is used in the OTRXMPPRoomManager to insert
    /// the realJID of room members/admins/etc
    @objc public func insertOccupantItems(_ items: [XMLElement],
                                        into room: XMPPRoom) {
        let occupants = items.map { (element) in
            OccupantInfo(jid: nil, presence: nil, item: element)
        }
        insertOccupants(occupants, into: room)
    }
    
    /// body param is optional and is for overriding the xmppMessage's body
    public func insertIncoming(_ xmppMessage: XMPPMessage,
                               body: String?,
                               original: String?,
                               delayed: Date?,
                               into xmppRoom: XMPPRoom,
                               split: Bool,
                               isOutgoingFromOtherDevice: Bool,
                               transaction: GRDBWriteTransaction? = nil,
                               preSave: MessageStorage.PreSave? = nil) {
        
        // Don't process incoming message with reactions. Reactions are processed under MessageStorage.handleMessageReaction() method.
        if let reactions = xmppMessage.chatMessageReactions as? [String: Any], !reactions.isEmpty {
            return
        }
        
        //IOSM-486, IOSM-557 added split
        if xmppMessage.isUsingExplicitEncryption(namespace: .omemo),
            body == nil {
            
            DDLogWarn("Group OMEMO message received but couldn't decrypt body")
            return
        }
        guard let senderJID = xmppMessage.from else {
            // No sender JID?
            return
        }
        
        var acct:ChatAccountModel?
        var xStream:XMPPStream?
        if let transaction = transaction {
            acct = xmppRoom.xmppAccount(transaction)
        } else {
            acct = xmppRoom.xmppAccount()
            xStream = xmppRoom.xmppStream
        }
        
        guard let account = acct else {
            return
        }
        
        // TODO unify this with the non-MUC receipt logic
        if OTRProtocolManager.sharedInstance().isAccountIdConnected(account.uniqueId), let xmppStream = xStream { //IOSM#43
            ChatRoomMessageModel.handleDeliveryReceiptRequest(message: xmppMessage, xmppStream: xmppStream)
        }
        //IOSM#8 if this is a displayed, we are done
        if self.handleDisplayedResponse(message: xmppMessage, xmppRoom: xmppRoom, transaction: transaction) {
            return //if this is a displayed, we are done
        }
            
        // If this is a receipt, we are done
        if xmppMessage.hasReceiptResponse {
            return
        }
            
        let stanzaId = xmppMessage.extractStanzaId(chatAccount: account)
        let originId = xmppMessage.originId
        
        var cmessage:ChatRoomMessageModel?
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            if let _ = self.existingSentMessage(xmppMessage: xmppMessage, stanzaId: stanzaId, originId: originId, transaction: transaction) {
                // DDLogVerbose("Discarding duplicate MUC message: \(duplicate) \(xmppMessage)")
                if (!split) { //IOSM-486, IOSM-557
                    return
                }
            }
            
            var _room:ChatRoomModel?
            do {
                _room = try ChatRoomModel.fetch(xmppRoom: xmppRoom, transaction: transaction)
            } catch {
                DDLogError("RoomStorage.fetch with error: \(error)")
            }
            
            var newroom = false
            if _room == nil, let key = xmppRoom.chatRoomKey {
                _room = ChatRoomModel(uniqueId: key)
                _room?.grdbRecord?.lastRoomMessageId = "" // Hack to make it show up in list
                _room?.grdbRecord?.accountUniqueId = account.uniqueId
                _room?.roomJID = xmppRoom.roomJID
                newroom = true
            }
            //self.copy() as? Self
            guard let room = _room, //.copy() as? ChatRoomModel,
                  let roomJID = room.roomJID else {
                DDLogError("Could not find or create room for \(xmppRoom)")
                return
            }
            
            
            if xmppMessage.element(forName: "x", xmlns: XMPPMUCUserNamespace) != nil,
               xmppMessage.element(forName: "x", xmlns: XMPPConferenceXmlns) != nil {
                DDLogWarn("Received invitation to current room: \(room)")
                return
            }
            
            let message = ChatRoomMessageModel(message: xmppMessage, delayed: delayed, room: room)
            if isOutgoingFromOtherDevice {
                message.grdbRecord?.state = ChatRoomMessageState.sent.rawValue
                message.senderId = account.uniqueId
                message.senderDisplayName = account.displayName
            }
            // override body if this was an encrypted message
            if let body = body {
                message.messageText = body
            }
            
            if let msgText = message.messageText {
                if (msgText.hasSuffix("added to the group") || msgText.hasSuffix("left the group")) {
                    message.grdbRecord?.originalText = msgText
                    message.grdbRecord?.memberUpdate = true
                }
            }
            
            if (message.grdbRecord?.originalText == nil && original != nil) {
                message.grdbRecord?.originalText = original
            }
            
            message.grdbRecord?.originId = originId
            message.grdbRecord?.stanzaId = stanzaId
            
            let occupant = ChatRoomOccupantModel.occupant(jid: senderJID, realJID: message.realJID, roomJID: roomJID, accountId: account.uniqueId, createIfNeeded: true, transaction: transaction)
            if let roomId = room.grdbRecord?.id {
                occupant?.grdbRecord?.chatRoomId = roomId
            }
            if message.grdbRecord?.buddyUniqueId == nil, occupant?.buddyUniqueId != nil {
                message.grdbRecord?.buddyUniqueId = occupant?.buddyUniqueId
            }
            
            room.grdbRecord?.lastRoomMessageId = message.uniqueId
            
            if (xmppMessage.hasMarkableChatMarker) {
                message.grdbRecord?.markable = true
            }
            
            //this needs a thread. If it's a new room it's likely a new thread
            if newroom {
                var thread = ChatThread(uniqueId: room.uniqueId)
                if let aid = account.grdbRecord?.id {
                    thread.accountUniqueId = aid
                }
                //let threadModel = ChatThreadModel(thread: thread)
                thread.messageDate = message.messageDate
                thread.isGroupThread = true
                thread.modified = Date()
                thread.grdbSave(transaction: transaction)
                
                var chatThread:ChatThread?
                do {
                    chatThread = try ChatThread.filter(Column("uniqueId") == room.uniqueId).fetchOne(transaction.database)
                } catch {
                    DDLogError("MessageStorage.getThread with error: \(error)")
                }
                
                if var cthread = chatThread {
                    room.chatThreadId = cthread.id!
                    room.grdbRecord?.grdbSave(transaction: transaction)
                    
                    var chatRoom:ChatRoom?
                    do {
                        chatRoom = try ChatRoom
                            .filter(Column("uniqueId") == room.uniqueId)
                            .fetchOne(transaction.database)
                    } catch {
                        DDLogError("MessageStorage.getThread with error: \(error)")
                    }
                    
                    if let croom = chatRoom {
                        occupant?.grdbRecord?.grdbSave(transaction: transaction)
                        message.grdbRecord?.chatRoomId = croom.id!
                        if let preSave = preSave {
                            preSave(message, room.uniqueId, transaction)
                        } else {
                            message.grdbRecord?.grdbSave(transaction: transaction)
                        }
                        cthread.lastMessageId = message.uid
                        cthread.modified = Date()
                        cthread.grdbSave(transaction: transaction)
                    }
                }
            } else {
                room.grdbRecord?.grdbSave(transaction: transaction)
                occupant?.grdbRecord?.grdbSave(transaction: transaction)
                                    
                //if var mrec = message.grdbRecord {
                message.grdbRecord?.chatRoomId = room.grdbRecord!.id!
                if let preSave = preSave {
                    preSave(message, room.uniqueId, transaction)
                } else {
                    message.grdbRecord?.grdbSave(transaction: transaction)
                }
                                        
                do {
                    if var thread = try message.grdbRecord?.chatThread.fetchOne(transaction.database) {
                        thread.lastMessageId = message.uid
                        thread.messageDate = message.messageDate
                        thread.modified = Date()
                        thread.grdbSave(transaction: transaction)
                    }
                } catch {
                    DDLogDebug("ChatRoomMessage.threadOwner with error: \(error)")
                }
                
                /*room.saveThread()
                occupant?.grdbRecord?.storeInGRDB()
                message.grdbRecord?.chatRoomId = room.grdbRecord!.id!
                if let preSave = preSave {
                    preSave(message)
                } else {
                    message.grdbRecord?.storeInGRDB(completion: {
                        DispatchQueue.global().async {
                            if let threadOwner = message.threadOwner() {
                                threadOwner.lastMessageIdentifier = message.uid
                                threadOwner.threadDate = message.messageDate
                                threadOwner.grdbRecord?.modified = Date()
                                threadOwner.saveThread()
                            }
                        }
                    })
                }*/
            }
            
            if room.grdbRecord?.isArchived == false {
                DispatchQueue.main.async {
                    Application.shared.showLocalNotification(message)
                }
            }
            cmessage = message
            
        }, completionQueue: self.workQueue, completion: {
            if let message = cmessage {
                self.fileTransfer.createAndDownloadItemsIfNeeded(message: message, force: false)
                MessageStorage.markAsReadIfVisible(message: message, account: account)
                if delayed == nil, let acctLastDate = account.grdbRecord?.lastHistoryFetchDate, message.messageDate > acctLastDate {
                    account.grdbRecord?.lastHistoryFetchDate = message.messageDate
                    account.saveXMPPAccountAsync()
                }
            }
        })
            
        /*self.fileTransfer.createAndDownloadItemsIfNeeded(message: message, force: false)
            
        if room.grdbRecord?.isArchived == false {
            DispatchQueue.main.async {
                Application.shared.showLocalNotification(message)
            }
        }
  
        MessageStorage.markAsReadIfVisible(message: message, account: account)*/
    }
    
    /// Marks a previously sent outgoing message as read.
    /// returns true if done and no more processing needed
    //IOSM#8
    private func handleDisplayedResponse(message: XMPPMessage, xmppRoom: XMPPRoom, transaction: GRDBWriteTransaction?) -> Bool {
        guard message.hasDisplayedChatMarker,
            !message.isErrorMessage,
            let responseId = message.chatMarkerID else {
                return false
        }
        
        if let myRoomJID = xmppRoom.myRoomJID,
            let messageJID = message.from, myRoomJID.isEqual(to: messageJID) {
                return true
        }
        
        var roomMessage: ChatRoomMessageModel?
        if let msgWithElementId = ChatRoomMessageModel.getMessage(elementId: responseId, originId: responseId, stanzaId: nil, transaction: transaction) {
            roomMessage = msgWithElementId
        } else if let msgWithStanzaId = ChatRoomMessageModel.getMessage(withStanzaId: responseId) {
            roomMessage = msgWithStanzaId
        }
        
        guard let displayedMessage = roomMessage else {return true }
        
        //if displayedMessage.grdbRecord?.isDisplayed != true {
            displayedMessage.grdbRecord?.isDisplayed = true
            displayedMessage.grdbRecord?.read = true
            displayedMessage.grdbRecord?.modified = Date()
        if let fromstr = message.from?.resource, fromstr.count > 0 {
            displayedMessage.addDisplayedJid(fromstr)
            if let transaction = transaction {
                displayedMessage.grdbRecord?.grdbSave(transaction: transaction)
            } else {
                displayedMessage.save()
            }
                /*if let thread = displayedMessage.threadOwner() {
                    thread.saveThread()
                    //let tkey = displayedMessage.threadId
                    /*DispatchQueue.main.async {
                        let messagesVC = OTRAppDelegate.appDelegate.chatRoomViewController
                        if messagesVC.isViewLoaded, messagesVC.view.window != nil,
                           let key = messagesVC.threadKey, tkey == key
                        {
                            messagesVC.updateDisplayedMessage()
                        }
                    }*/
                }*/
            }
        //}
        return true
    }
    
    // MARK: Private
    
    private struct OccupantInfo {
        /// JID of the occupant inside the room
        var jid: XMPPJID?
        /// optional presence information
        var presence: XMPPPresence?
        /// additional item information about occupant
        /// containing role, affiliation, public JID, etc
        var item: XMLElement?
    }
    
    private func insertOccupants(_ occupants:[OccupantInfo],
                                 into room: XMPPRoom) {
        guard let fetchedRoom: ChatRoomModel = ChatRoomModel.fetch(xmppRoom: room),
              let grdbRecord = fetchedRoom.grdbRecord,
              ChatRoomModel.getXMPPRoom(uniqueId: grdbRecord.uniqueId) != nil else {
            return
        }
        
        guard let accountId = room.accountId else {
            assert(room.accountId != nil)
            DDLogError("No accountId attached to room!")
            return
        }
        
        let chatRoomKey = room.chatRoomKey
        let xstream = self.omemoModule?.xmppStream
        
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            let account = ChatAccountModel.getXMPPAccount(uniqueId: accountId, transaction: transaction)
            occupants.forEach({ (occupantInfo) in
                let presenceJID = occupantInfo.jid
                let item = occupantInfo.item
                // Will be nil in anonymous rooms (and semi-anonymous rooms if we are not moderators)
                var realJID: XMPPJID? = nil
                if let buddyJidString = item?.attributeStringValue(forName: "jid") {
                    realJID = XMPPJID(string: buddyJidString)
                }
                guard let occupant = ChatRoomOccupantModel.occupant(jid: presenceJID, realJID: realJID, roomJID: room.roomJID, accountId: accountId, createIfNeeded: true, transaction: transaction) else {
                    DDLogWarn("Could not create room occupant")
                    return
                }
                    
                var roomModel:ChatRoomModel?
                if let ckey = chatRoomKey {
                    do {
                        roomModel = try ChatRoomModel.getXMPPRoom(uniqueId: ckey, transaction: transaction)
                    } catch {}
                }
                    
                if let room = roomModel {
                    if let presence = occupantInfo.presence, let presenceJID = presence.from {
                        if let rid = room.grdbRecord?.id {
                            occupant.grdbRecord?.chatRoomId = rid
                        }
                        BuddyCache.shared().setJid(presenceJID.full, online: presence.presenceType != .unavailable, room:room)
                    }
                    if let roomid = room.grdbRecord?.id {
                        occupant.grdbRecord?.chatRoomId = roomid
                    }
                }
                // Update their role/affiliation information
                if let role = item?.attributeStringValue(forName: "role") {
                    occupant.role = RoomOccupantRole(stringValue: role)
                }
                if let affiliation = item?.attributeStringValue(forName: "affiliation") {
                    occupant.affiliation = RoomOccupantAffiliation(stringValue: affiliation)
                }
                    
                // it's best to map "real" buddies to room occupants when we can
                if let realJID = realJID?.bareJID {
                    var buddy = ChatBuddyModel.fetchBuddy(jid: realJID, accountUniqueId: accountId, transaction: transaction)
                    if buddy == nil {
                        // if an existing buddy is not found
                        // let's create an 'untrusted' room buddy,
                        // this facilitates vCard fetch and OMEMO key fetch
                        // this buddy is not considered on the user's roster
                        //create ChatThread first, on completion create Buddy
                            
                        if account?.bareJID == realJID {
                            //print("***** found my own account")
                        } else {
                            let buddyModel = ChatBuddyModel(jid: realJID, accountId: accountId)
                            //buddyModel.trustLevel = .untrusted
                            buddyModel.grdbRecord?.grdbSave(transaction: transaction)
                            DDLogInfo("Created non-roster buddy for room \(realJID) \(room)")
                            buddy = buddyModel.grdbRecord
                        }
                    }
                    occupant.grdbRecord?.buddyUniqueId = buddy?.uniqueId
                    /// Fetch vCard for avatar
                    //self.vCardModule.fetchvCardTemp(for: realJID, ignoreStorage: false)
                    //get this manually if possible...below
                        
                    /// Fetch DeviceIds for prepping future OMEMO sessions
                    if self.omemoModule == nil, let account = account, let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account) {
                        self.omemoModule = xmpp.omemoSignalCoordinator?.omemoModule
                    }
                        
                    // check for existing vcard
                    var vtemp:XMPPvCardTemp?
                    if let myjid = xstream?.myJID, realJID.isEqual(to: myjid, options: .bare) {
                        vtemp = account?.vCardTemp
                    } else {
                        vtemp = ChatBuddyModel.fetchBuddyModel(jid: realJID, accountUniqueId: accountId, transaction: transaction)?.vCardTemp
                    }
                    if vtemp == nil, xstream?.isAuthenticated == true {
                        self.vCardModule.forceFetchvCardTemp(for: realJID)
                    }
                        
                    self.omemoModule?.performBlock(async: true, {
                        self.omemoModule?.fetchDeviceIds(for: realJID, elementId: nil)
                    })
                }
                
                guard occupant.buddyUniqueId != nil else { return }
                occupant.grdbRecord?.grdbSave(transaction: transaction)
            })
        })
    }
    
    // same as existing message but don't care about delayed
    private func existingSentMessage(xmppMessage: XMPPMessage,
                                 stanzaId: String?,
                                 originId: String?, transaction:GRDBWriteTransaction?) -> ChatRoomMessageModel? {
        // Only use elementId as a fallback if originId and stanzaId are missing
        var elementId: String? = nil
        if originId == nil, stanzaId == nil {
            elementId = xmppMessage.elementID
        }
        var result:ChatRoomMessageModel? = nil
        if let roomMessage = ChatRoomMessageModel.getMessage(elementId: elementId, originId: originId, stanzaId: stanzaId, transaction: transaction) {
            if roomMessage.senderJID == xmppMessage.from?.full {
                result = roomMessage
            } else if let msgText = roomMessage.messageText, (msgText.hasSuffix("added to the group") || msgText.hasSuffix("left the group")) {
                // this else if is because ownJID/senderJID is null for new rooms
                result = roomMessage
            } else {
                DDLogWarn("Found matching MUC message but intended for different recipient \(roomMessage) \(xmppMessage)")
            }
        }
        
        return result
    }
    
}


// MARK: - XMPPRoomStorage
extension RoomStorage: XMPPRoomStorage {
    public func configure(withParent aParent: XMPPRoom, queue: DispatchQueue) -> Bool {
        return true
    }
    
    public func handle(_ presence: XMPPPresence, room: XMPPRoom) {
        if let item = presence.element(forName: "x", xmlns: XMPPMUCUserNamespace)?.element(forName: "item") {
            let occupant = OccupantInfo(jid: presence.from, presence: presence, item: item)
            insertOccupants([occupant], into: room)
        } else {
            DDLogError("Could not extract occupant item from presence \(presence)")
        }
    }
    
    public func handleIncomingMessage(_ message: XMPPMessage, room: XMPPRoom) {
        guard let myRoomJID = room.myRoomJID,
            let messageJID = message.from else {
                DDLogError("Discarding invalid MUC message \(message)")
                return
        }
        if myRoomJID.isEqual(to: messageJID),
           !message.wasDelayed {
            // DDLogVerbose("Discarding duplicate outgoing MUC message \(message)")
            // this can happen with MAM messages if both devices open
        }
        
        // plain text location
        guard var messageString = message.body,
            messageString.count > 0 else {
            insertIncoming(message, body: nil, original: nil, delayed: message.delayedDeliveryDate, into: room, split: false, isOutgoingFromOtherDevice: false)
            return
        }
        
        if (messageString.hasPrefix("Sent encrypted message") || messageString.hasPrefix("Message cannot be decrypted")) { //IOSM-605
            return
        }
        
        insertIncoming(message, body: nil, original: nil, delayed: message.delayedDeliveryDate, into: room, split: false, isOutgoingFromOtherDevice: false)
    }
    
    public func handleFailedIncomingMessage(_ message: XMPPMessage, room: XMPPRoom, transaction: GRDBWriteTransaction) -> Bool {
        var insert = true
        if let messageString = message.body, messageString.count > 0 {
            if (messageString.contains("encrypted message") || messageString.contains("Message cannot be decrypted")) {
                //IOSM-338 duplicate check
                // this is also done in insertIncoming but I don't get the result
                if let account = room.xmppAccount(transaction) {
                    let stanzaId = message.extractStanzaId(chatAccount: account)
                    let originId = message.originId
                    if let _ = self.existingSentMessage(xmppMessage: message, stanzaId: stanzaId, originId: originId, transaction: transaction) {
                        // DDLogVerbose("Discarding duplicate MUC message: \(duplicate) \(xmppMessage)")
                        insert = false
                    }
                }
                if insert {
                    insertIncoming(message, body: getFailedDecryptMessage(), original: nil, delayed: message.delayedDeliveryDate, into: room, split: false, isOutgoingFromOtherDevice: false, transaction: transaction)
                }
            }
        }
        return insert
    }
    
    // just for fun
    static var failedMsgNum:Int = -1
    public func getFailedDecryptMessage() -> String {
        return "Message cannot be decrypted" //IOSM-531
        //For more information visit https://glaciersecurity.zendesk.com/hc/en-us/articles/360027880632"
        /*RoomStorage.failedMsgNum = RoomStorage.failedMsgNum+1
        if (RoomStorage.failedMsgNum > 9) {
            RoomStorage.failedMsgNum = 0
        }
        switch RoomStorage.failedMsgNum {
            case 0:
                return "Couldn't decrypt, restarting flux capacitor"
            case 1:
                return "Couldn't decrypt, recalibrating earth's orbit"
            case 2:
                return "Couldn't decrypt, starting particle accelerator"
            case 3:
                return "Couldn't decrypt, initiating ludicrous speed"
            case 4:
                return "Couldn't decrypt, turning on anti-gravity mode"
            case 5:
                return "Couldn't decrypt, entering subatomic realm"
            case 6:
                return "Couldn't decrypt, mapping human genome"
            case 7:
                return "Couldn't decrypt, negotiating peace treaty"
            case 8:
                return "Couldn't decrypt, hunting for Red October"
            default:
                return "Couldn't decrypt message(s), re-syncing Glacier keys"
        }*/
    }
    
    public func handleOutgoingMessage(_ message: XMPPMessage, room: XMPPRoom) {
        // DDLogVerbose("Handle outgoing group message \(message) \(room)")
    }
    
    public func handleDidLeave(_ xmppRoom: XMPPRoom) {
        //handled in XMPPManager if is stream disconnect
        guard let room = ChatRoomModel.fetch(xmppRoom: xmppRoom) else { //?.copyAsSelf() else {
            return
        }
        room.joined = false
        room.grdbRecord?.touch()
    }
    
    public func handleDidJoin(_ xmppRoom: XMPPRoom, withNickname nickname: String) {
        guard let room = ChatRoomModel.fetch(xmppRoom: xmppRoom) else { //?.copyAsSelf() else {
            return
        }
        room.joined = true
        room.ourJID = xmppRoom.myRoomJID
        room.saveThread()
    }
    
    // handle subscription to room
    public func handleSubscription(_ xmppRoom: XMPPRoom, to toJid:XMPPJID, withNickname nickname: String) {
        guard let room = ChatRoomModel.fetch(xmppRoom: xmppRoom) else {
            return
        }
            
        if (!room.isMuted) {
            xmppRoom.subscribe(toRoom: toJid, withNick:nickname)
        }
    }
}

// MARK: - XEP-0380: Explicit Message Encryption
// TODO: Move me somewhere else
/// XEP-0380: Explicit Message Encryption
/// https://xmpp.org/extensions/xep-0380.html
public extension XMPPMessage {
    /// XEP-0380: Explicit Message Encryption
    static let emeXmlns = "urn:xmpp:eme:0"
    
    enum EncryptionNamespace: String {
        case otr = "urn:xmpp:otr:0"
        //case omemo = "eu.siacs.conversations.axolotl"
        case omemo = "com.glaciersecurity.glaciermessenger.axolotl"
        case pgp = "urn:xmpp:openpgp:0"
    }
    
    struct ExplicitEncryption {
        var namespace: EncryptionNamespace
        var name: String?
    }
    
    func isUsingExplicitEncryption(namespace: EncryptionNamespace) -> Bool {
        return explicitMessageEncryption?.namespace == namespace
    }
    
    var explicitMessageEncryption: ExplicitEncryption? {
        guard let element = element(forName: "encryption", xmlns: XMPPMessage.emeXmlns),
        let namespaceString = element.attributeStringValue(forName: "namespace"),
            let namespace = EncryptionNamespace(rawValue: namespaceString) else {
            return nil
        }
        let name = element.attributeStringValue(forName: "name")
        return ExplicitEncryption(namespace: namespace, name: name)
    }
}
