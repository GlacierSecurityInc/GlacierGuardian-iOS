//  ChatSecureCore
//  Created by Chris Ballinger on 11/21/17.
//  Copyright © 2017 Chris Ballinger. All rights reserved.

import Foundation
import XMPPFramework
import CocoaLumberjack
import GRDB


@objc public class MessageStorage: XMPPModule {
    /// This gets called before a message is saved, if additional processing needs to be done elsewhere
    public typealias PreSave = (_ message: MessageProtocol, _ buddyId: String?, _ transaction:GRDBWriteTransaction?) -> Void

    // MARK: Properties
    /// Only access this within moduleQueue
    private var mamCatchupInProgress: Bool = false
    
    /// Capabilities must be activated elsewhere
    @objc public let capabilities: XMPPCapabilities
    @objc public let archiving: XMPPMessageArchiveManagement
    @objc public let roomStorage: RoomStorage
    @objc public let roomManager: OTRXMPPRoomManager
    private let carbons: XMPPMessageCarbons
    private let fileTransfer: FileTransferManager
    private var fetchDate = Date()
    private var awaitingJmiPropose: Bool = false
    private var callQuery: Bool = false

    // MARK: Init
    deinit {
        self.carbons.removeDelegate(self)
        self.archiving.removeDelegate(self)
    }
    
    /// Capabilities must be activated elsewhere
    @objc public init(capabilities: XMPPCapabilities,
                      fileTransfer: FileTransferManager,
                      roomStorage: RoomStorage,
                      dispatchQueue: DispatchQueue? = nil) {
        self.capabilities = capabilities
        self.carbons = XMPPMessageCarbons(dispatchQueue: dispatchQueue)
        let archiving = XMPPMessageArchiveManagement(dispatchQueue: dispatchQueue)
        self.archiving = archiving
        self.archiving.resultAutomaticPagingPageSize = NSNotFound
        self.fileTransfer = fileTransfer
        self.roomStorage = roomStorage
        self.roomManager = OTRXMPPRoomManager(roomStorage: roomStorage, archiving: archiving, dispatchQueue: dispatchQueue)
        super.init(dispatchQueue: dispatchQueue)
        self.carbons.addDelegate(self, delegateQueue: self.moduleQueue)
        self.archiving.addDelegate(self, delegateQueue: self.moduleQueue)
    }
    
    // MARK: XMPPModule overrides
    
    @discardableResult override public func activate(_ xmppStream: XMPPStream) -> Bool {
        guard super.activate(xmppStream),
            carbons.activate(xmppStream),
            archiving.activate(xmppStream),
            roomManager.activate(xmppStream)
            else {
            return false
        }
        return true
    }
    
    public override func deactivate() {
        carbons.deactivate()
        archiving.deactivate()
        roomManager.deactivate()
        super.deactivate()
    }
    
    // MARK: Private
    
    /// only if the new date is newer than the old date it will save
    private func updateLastFetch(account: ChatAccountModel, date: Date) {
        // Don't update fetch date from realtime messages if we're currently fetching
        var fetching = false
        performBlock {
            fetching = self.mamCatchupInProgress
        }
        if fetching {
            return
        }
        if let lastFetch = account.grdbRecord?.lastHistoryFetchDate,
            date > lastFetch {
            account.grdbRecord?.lastHistoryFetchDate = date
            account.saveXMPPAccount()
        }
    }
    
    /// Updates chat state for buddy
    private func handleChatState(message: XMPPMessage, buddy: ChatBuddy) {
        let chatState = ChatState.chatState(from: message.chatState)
        BuddyCache.shared().setChatState(chatState, buddyId: buddy.uniqueId)
        buddy.touch()
    }
    
    /// Marks a previously sent outgoing message as delivered.
    private func handleDeliveryResponse(message: XMPPMessage) {
        guard message.hasReceiptResponse,
            !message.isErrorMessage,
            let responseId = message.receiptResponseID else {
                return
        }
        
        ChatMessageModel.setDelivered(elementId: responseId, originId: nil, stanzaId: nil)
    }
    
    /// Marks a previously sent outgoing message as read.
    private func handleDisplayedResponse(message: XMPPMessage) {
        guard message.hasDisplayedChatMarker,
            !message.isErrorMessage,
            let responseId = message.chatMarkerID else {
                return
        }
        
        ChatMessageModel.setDisplayed(elementId: responseId, originId: responseId, stanzaId: nil)
    }
    
    /// It is a violation of the XMPP spec to discard messages with duplicate stanza elementIds. We must use XEP-0359 stanza-id only.
    private func isDuplicate(message: ChatMessage) -> Bool {
        var result = false
        let buddyUniqueId = message.buddyUniqueId
        let oid = message.originId
        let sid = message.stanzaId
        if oid == nil, sid == nil {
            return false
        }
        if let foundMessage = ChatMessageModel.getMessage(elementId: oid, originId: oid, stanzaId: sid), foundMessage.threadId == buddyUniqueId {
            result = true
        }
        
        return result
    }
    
    /// Handles both MAM and Carbons
    public func handleForwardedMessage(_ xmppMessage: XMPPMessage,
                                        forJID: XMPPJID,
                                        body: String?,
                                        original: String?,
                                        accountId: String,
                                        delayed: Date?,
                                        isIncoming: Bool,
                                        isOutgoingFromOtherDevice: Bool,
                                        split: Bool,
                                        preSave: PreSave? = nil ) {
        //IOSM-486, IOSM-557 added split
        guard !xmppMessage.isErrorMessage else {
            DDLogWarn("Discarding forwarded error message: \(xmppMessage)")
            return
        }
        // Inject MAM messages into group chat storage
        if xmppMessage.containsGroupChatElements {
            DDLogVerbose("Injecting forwarded MAM message into room: \(xmppMessage)")
            
            if let roomJID = xmppMessage.from?.bareJID {
                if let room = roomManager.room(for: roomJID) {
                    //IOSM-540 placeholder...maybe a better place to set lastHistoryFetch
                    if body == nil, let unwrapped = xmppMessage.omemo_offline() {
                        var isOutFromOtherDevice = isOutgoingFromOtherDevice
                        var bod = body
                        let xmsg = XMPPMessage(from: unwrapped)
                        if let fromresource = xmsg.from?.resource {
                            if let account = ChatAccountModel.getXMPPAccount(uniqueId: accountId), fromresource == account.displayName {
                                isOutFromOtherDevice = true
                            }
                        }
                        if body == nil, let unwrappedbod = xmsg.body {
                            bod = unwrappedbod
                        }
                        roomStorage.insertIncoming(xmsg, body: bod, original: bod, delayed: delayed, into: room, split: false, isOutgoingFromOtherDevice: isOutFromOtherDevice, transaction:nil)
                    } else {
                        roomStorage.insertIncoming(xmppMessage, body: body, original: original, delayed: delayed, into: room, split: false, isOutgoingFromOtherDevice: isOutgoingFromOtherDevice, transaction:nil)
                    }
                } else {
                    if xmppMessage.element(forName: "x", xmlns: XMPPMUCUserNamespace)?.element(forName:"invite") != nil {
                        roomManager.xmppMUC(nil, roomJID: roomJID, didReceiveInvitation: xmppMessage)
                    }
                }
            return
        }

        ChatBuddyModel.getBuddyAndAccount(jid: forJID, accountUniqueId: accountId, queue: self.moduleQueue, completion: { [weak self] (buddy, account) in
            guard let buddy = buddy?.grdbRecord, let account = account, let self = self else {return}
            
            var _message: ChatMessageModel? = nil
            
            if isIncoming {
                self.handleDeliveryResponse(message: xmppMessage)
                self.handleChatState(message: xmppMessage, buddy: buddy)
                self.handleDisplayedResponse(message: xmppMessage) // and hasDisplayed below
                
                // If this is a receipt, we are done
                if xmppMessage.hasReceiptResponse || xmppMessage.hasDisplayedChatMarker {
                    return
                }
                
                let grec = ChatMessageModel.getMessage(outgoing: false, xmppMessage: xmppMessage, body: body, account: account, buddy: buddy, capabilities: self.capabilities)
                let incomingMessage = IncomingChatMessage(message: grec)
                
                // mark message as read if this is a MAM catchup
                if delayed != nil {
                }
                
                if xmppMessage.hasMarkableChatMarker {
                    incomingMessage.grdbRecord?.markable = true
                }
                
                _message = incomingMessage
            } else {
                var isoutOther = isOutgoingFromOtherDevice
                if let fromjid = xmppMessage.from?.bareJID, fromjid == account.bareJID {
                    isoutOther = true
                }
                
                if isoutOther, xmppMessage.containsJmiElements {
                    //if this is a proceed from other device, I should probably end call
                    if xmppMessage.containsProceedElement {
                        CallManager.sharedCallManager().reportCallCancelled()
                    }
                    return
                }
                
                //IOSM-584 If this is a receipt from a MAM device, we are done
                if isoutOther && (xmppMessage.hasReceiptResponse || xmppMessage.hasDisplayedChatMarker || xmppMessage.hasReceivedChatMarker) {
                    return
                }
                
                let grec = ChatMessageModel.getMessage(outgoing: true, xmppMessage: xmppMessage, body: body, account: account, buddy: buddy, capabilities: self.capabilities)
                let outgoing = OutgoingChatMessage(message: grec)
                
                outgoing.grdbRecord?.dateSent = delayed ?? Date()
                outgoing.grdbRecord?.readDate = Date()
                outgoing.grdbRecord?.outgoingFromDifferentDevice = isoutOther
                _message = outgoing
            }
            guard let message = _message, let text = message.messageText, text.count > 0 else {
                DDLogWarn("Discarding empty message: \(xmppMessage)")
                return
            }
            
            // Bail out if we receive duplicate messages identified by XEP-0359
            //IOSM-486, IOSM-557 added split
            var chatmsg = message.grdbRecord!
            if !split, self.isDuplicate(message: chatmsg) {
                DDLogWarn("Duplicate forwarded message received: \(xmppMessage)")
                return
            }
            
            if let expiretime = xmppMessage.element(forName: "x", xmlns: "jabber:x:msgexpire") {
                chatmsg.expires = expiretime.attributeStringValue(forName:"seconds")
            }
            chatmsg.originalText = original
            
            if xmppMessage.element(forName: "x", xmlns: "jabber:x:systemupdate") != nil {
                chatmsg.systemUpdate = true
            }
            
            if let delayed = delayed {
                chatmsg.date = delayed
            }
            message.grdbRecord = chatmsg
            
            DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                var chatThread = message.threadOwner(transaction)
                if chatThread == nil {
                    do {
                        chatThread = try ChatThread.filter(Column("uniqueId") == buddy.uniqueId).fetchOne(transaction.database)
                    } catch {
                        DDLogError("MessageStorage.getThread with error: \(error)")
                    }
                }
                if chatThread == nil {
                    var newThread = ChatThread(uniqueId: buddy.uniqueId)
                    newThread.messageDate = message.messageDate
                    newThread.isGroupThread = false
                    newThread.lastMessageId = message.uid
                    newThread.accountUniqueId = (account.grdbRecord?.id)!
                    newThread.modified = Date()
                    newThread.grdbSave(transaction: transaction)

                    do {
                        chatThread = try ChatThread.filter(Column("uniqueId") == buddy.uniqueId).fetchOne(transaction.database)
                    } catch {
                        DDLogError("MessageStorage.getThread with error: \(error)")
                    }
                }

                if var cthread = chatThread {
                    if let preSave = preSave {
                        preSave(message, buddy.uniqueId, transaction)
                    } else {
                        message.grdbRecord?.grdbSave(transaction: transaction)
                    }

                    if buddy.chatThreadId == -1, let ctid = cthread.id {
                        var bud = buddy
                        bud.chatThreadId = ctid
                        do {
                            try bud.update(transaction.database, columns: [Column("chatThreadId")])
                        } catch {
                            DDLogError("MessageStorage buddy threadID update with error: \(error)")
                        }
                    }

                    //update with new date/lastMessage
                    if (message is IncomingChatMessage || message is OutgoingChatMessage) {
                        cthread.messageDate = message.messageDate
                        cthread.lastMessageId = message.uid
                        cthread.modified = Date()
                        cthread.grdbSave(transaction: transaction)
                    }
                } else {
                    print("***** can't find thread!!!")
                }
            }, completionQueue: self.moduleQueue, completion: {
                if let incoming = message as? IncomingChatMessage {
                    // We only want to send receipts and show notifications for "real time" messages
                    // undelivered messages still go through the "handleDirectMessage" path,
                    // so MAM messages have been delivered to another device
                    self.finishHandlingIncomingMessage(incoming, account: account, showNotification:(delayed == nil), from: forJID.bare)
                } else if let outgoing = message as? OutgoingChatMessage {
                    if outgoing.grdbRecord?.outgoingFromDifferentDevice == true {
                        self.fileTransfer.createAndDownloadItemsIfNeeded(message: message, force: false)
                        /// mark as read if on screen
                        MessageStorage.markAsReadIfVisible(message: message, account: account)
                    }
                }
                if delayed == nil {
                    self.updateLastFetch(account: account, date: message.messageDate)
                }

                self.handleExpiration(message)
            })
        })
    }
    
    private func handleExpiration(_ message:ChatMessageModel) {
        var updateExpires = false
        if let buddyThread = message.xmppBuddy() {
            //IOSM#6
            if ((buddyThread.expiresIn == nil && message.messageExpires != nil) ||
                (buddyThread.expiresIn != nil && message.messageExpires == nil) ||
                !(buddyThread.expiresIn == message.messageExpires)) {
                buddyThread.expiresIn = message.messageExpires
                updateExpires = true
            }

            //IOSM#6
            let tkey = buddyThread.threadIdentifier
            if (updateExpires){
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let messagesVC = OTRAppDelegate.appDelegate.chatViewController

                    if messagesVC.isViewLoaded,
                        messagesVC.view.window != nil,
                        let key = messagesVC.threadKey, tkey == key
                    {
                        messagesVC.updateExpiresState()
                    }
                }
            }
        }
    }
    
    /// Inserts direct message into database
    public func handleDirectMessage(_ message: XMPPMessage,
                                    body: String?,
                                    original: String?,
                                    accountId: String,
                                    split: Bool,
                                    preSave: PreSave? = nil) {
        if let reactions = message.chatMessageReactions as? [String: Any], !reactions.isEmpty {
            return
        }
        
        //IOSM-486, IOSM-557 added split
        guard let fromJID = message.from else { return }
        ChatBuddyModel.getBuddyAndAccount(jid: fromJID, accountUniqueId: accountId, queue: self.moduleQueue, completion: { [weak self] (buddy, account) in
            guard let buddy = buddy, let account = account, let self = self else {return}

            // Update ChatState
            self.handleChatState(message: message, buddy: buddy.grdbRecord!)
            
            // Handle Delivery Receipts
            self.handleDeliveryResponse(message: message)
            self.handleDisplayedResponse(message: message) // and hasDisplayed below
            
            // Update lastSeenDate
            // If we receive a message from an online buddy that counts as them interacting with us
            let status = BuddyCache.shared().threadStatus(buddyId: buddy.uniqueId)
            if status != .offline,
                !message.hasReceiptResponse,
                !message.hasDisplayedChatMarker, 
                !message.isErrorMessage {
                BuddyCache.shared().setLastSeen(date:Date(), buddyModel: buddy)
            }
            
            // Handle errors
            guard !message.isErrorMessage else {
                if let elementId = message.elementID,
                    let existingMessage = OutgoingChatMessage.message(forMessageId: elementId) {
                    if let outgoing = existingMessage as? OutgoingChatMessage {
                        let nsError = OTRXMPPError.error(for: message) as NSError
                        let gerr = GlacierError.init(domain: nsError.domain, code: nsError.code, description: nsError.description)
                        outgoing.grdbRecord?.error = gerr
                        outgoing.save(withThread: outgoing.threadOwner())
                    }
                }
                return
            }
            
            let grec = ChatMessageModel.getMessage(outgoing: false, xmppMessage: message, body: body, account: account, buddy: buddy.grdbRecord!, capabilities: self.capabilities)
            let incoming = IncomingChatMessage(message: grec)
            
            // Check for duplicates
            //IOSM-486, IOSM-557 added split, might not work how I want
            if !split, self.isDuplicate(message: incoming.grdbRecord!) {
                DDLogWarn("Duplicate message received: \(message)")
                return
            }
            guard let text = incoming.messageText, text.count > 0 else {
                // discard empty message text
                return
            }
            
            // check message expiration
            if let expiretime = message.element(forName: "x", xmlns: "jabber:x:msgexpire") {
                incoming.messageExpires = expiretime.attributeStringValue(forName:"seconds")
            }
            incoming.grdbRecord?.originalText = original
            
            if message.element(forName: "x", xmlns: "jabber:x:systemupdate") != nil {
                incoming.grdbRecord?.systemUpdate = true
            }
            
            if message.hasMarkableChatMarker {
                incoming.grdbRecord?.markable = true
            }
            
            let stanzaId = message.extractStanzaId(chatAccount: account)
            incoming.grdbRecord?.stanzaId = stanzaId
            
            DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                var chatThread = incoming.threadOwner(transaction)
                if chatThread == nil {
                    do {
                        chatThread = try ChatThread.filter(Column("uniqueId") == buddy.uniqueId).fetchOne(transaction.database)
                    } catch {
                        DDLogError("MessageStorage.getThread with error: \(error)")
                    }
                }
                if chatThread == nil {
                    var newThread = ChatThread(uniqueId: buddy.uniqueId)
                    newThread.messageDate = incoming.messageDate
                    newThread.isGroupThread = false
                    newThread.accountUniqueId = (account.grdbRecord?.id)!
                    newThread.modified = Date()
                    newThread.grdbSave(transaction: transaction)

                    do {
                        chatThread = try ChatThread.filter(Column("uniqueId") == buddy.uniqueId).fetchOne(transaction.database)
                    } catch {
                        DDLogError("MessageStorage.getThread with error: \(error)")
                    }
                }

                if var cthread = chatThread {
                    if let preSave = preSave {
                        preSave(incoming, buddy.uniqueId, transaction)
                    } else {
                        incoming.grdbRecord?.grdbSave(transaction: transaction)
                    }

                    if var bud = buddy.grdbRecord, bud.chatThreadId == -1, let ctid = cthread.id {
                        bud.chatThreadId = ctid
                        do {
                            try bud.update(transaction.database, columns: [Column("chatThreadId")])
                        } catch {
                            DDLogError("MessageStorage buddy threadID update with error: \(error)")
                        }
                    }

                    //update with new date/lastMessage
                    cthread.messageDate = incoming.messageDate
                    cthread.lastMessageId = incoming.uid
                    cthread.modified = Date()
                    cthread.grdbSave(transaction: transaction)
                } else {
                    print("***** can't find thread!!!")
                }
            }, completionQueue: self.moduleQueue, completion: {
                self.finishHandlingIncomingMessage(incoming, account: account, showNotification:true, from: fromJID.bare)
                self.updateLastFetch(account: account, date: incoming.messageDate)

                self.handleExpiration(incoming)
            })
        })
    }
    
    //IOSM-338c
    public func handleFailedIncomingMessage(_ message: XMPPMessage,
                                    body: String?,
                                    original: String?,
                                    accountId: String) -> Bool {
        var insert = true
        
        if let account = ChatAccountModel.getXMPPAccount(uniqueId: accountId),
            let fromJID = message.from,
            let buddy = ChatBuddyModel.fetchBuddy(jid: fromJID, accountUniqueId: accountId) {
                
            let grec = ChatMessageModel.getMessage(outgoing: false, xmppMessage: message, body: body, account: account, buddy: buddy, capabilities: self.capabilities)
            let incoming = IncomingChatMessage(message: grec)
            
            // Check for duplicates
            if self.isDuplicate(message: incoming.grdbRecord!) {
                insert = false
            }
        }

        if insert {
            self.handleDirectMessage(message, body: "Message cannot be decrypted", original: nil, accountId: accountId, split: false) //IOSM-531
        }
        
        return insert
    }
    
    private func finishHandlingIncomingMessage(_ message: IncomingChatMessage, account: ChatAccountModel, showNotification:Bool, from:String) {
        guard let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account) else {
            return
        }
        xmpp.sendDeliveryReceipt(for: message)
        
        self.fileTransfer.createAndDownloadItemsIfNeeded(message: message, force: false)
        if showNotification {
            DispatchQueue.main.async {
                Application.shared.showLocalNotification(message)
            }
        } 
        
        /// mark as read if on screen
        MessageStorage.markAsReadIfVisible(message: message, account: account)
    }
    
    @objc public func fetchHistoryForVoip() {
        guard let appDelegate = Application.shared.delegate as? OTRAppDelegate, appDelegate.voipNotification == true else { return }
        
        self.performBlock(async: true) {
            DDLogInfo("***** fetchHistoryForVoip")
            appDelegate.voipNotification = false
            self.awaitingJmiPropose = true
            self.callQuery = true
            self.archiving.retrieveMyLatestMessageArchive()
        }
    }
    
    private func addStanzaIdToChatMessageIfAvailable(_ message: XMPPMessage) {
        guard let type = message.attributeStringValue(forName: "type"),
              (type.lowercased() == "chat" || type.lowercased() == "groupchat"),
              let id = message.attributeStringValue(forName: "id"),
              let stanzaElement = message.element(forName: "stanza-id", xmlns: "urn:xmpp:sid:0"),
              let stanzaId = stanzaElement.attributeStringValue(forName: "id") else {
            return
        }
        
        guard let chatMessage = ChatMessageModel.message(forMessageId: id, checkIncomingType: false) as? ChatMessageModel else {
            guard let chatRoomMessage = ChatRoomMessageModel.getMessage(withXmppId: id) else {
                return
            }
            if chatRoomMessage.grdbRecord?.stanzaId == nil {
                chatRoomMessage.grdbRecord?.stanzaId = stanzaId
                chatRoomMessage.save()
            }
            return
        }
        
        if chatMessage.grdbRecord?.stanzaId == nil {
            chatMessage.grdbRecord?.stanzaId = stanzaId
            chatMessage.save()
        }
    }
}

// MARK: - Extensions

extension MessageStorage: XMPPCapabilitiesDelegate {
    public func xmppCapabilities(_ sender: XMPPCapabilities, didDiscoverCapabilities caps: XMLElement, for jid: XMPPJID) {
        
    }
}

extension MessageStorage: XMPPStreamDelegate {
    public func xmppStreamDidAuthenticate(_ sender: XMPPStream) {
        DispatchQueue.main.async {
            let appDelegate = Application.shared.delegate as? OTRAppDelegate  //IOSM#80
            DDLogInfo("***** MessageStorage xmppStreamDidAuthenticate with voipNotification \(appDelegate?.voipNotification ?? false)")
            if appDelegate?.voipNotification == true {
                self.performBlock(async: true) {
                    DDLogInfo("***** xmppStreamDidAuthenticate with voipNotification")
                    appDelegate?.voipNotification = false
                    self.awaitingJmiPropose = true
                    self.callQuery = true
                    self.archiving.retrieveMyLatestMessageArchive()
                    return
                }
            } else if Application.shared.applicationState != .background || appDelegate?.silentUpdate == true {
                self.performBlock(async: true) {
                    self.mamCatchupInProgress = false
                    guard let account = self.xmppAccount() else { return }
                    // if we've never fetched MAM before, try to fetch the last week
                    // otherwise fetch since the last time we fetched
                    
                    self.performBlock {
                        self.mamCatchupInProgress = true
                    }
                    let currentDate = Date()
                    if let dateToFetch = account.grdbRecord?.lastHistoryFetchDate {
                        self.archiving.fetchHistory(archiveJID: nil, userJID: nil, since: dateToFetch)
                    } else {
                        var dateComponents = DateComponents()
                        dateComponents.day = -7
                        let lastWeek = Calendar.current.date(byAdding: dateComponents, to: currentDate)!
                        self.archiving.fetchHistory(archiveJID: nil, userJID: nil, since: lastWeek)
                    }
                    self.fetchDate = currentDate
                }
            }
        }
    }
    
    public func xmppStream(_ sender: XMPPStream, didReceive message: XMPPMessage) {
        // If the message is for user reaction, update existing message with the reactions
        // and return. We don't save reactions as messages.
        if let reactions = message.chatMessageReactions as? [String: Any],
           let senderJid = reactions[ChatMessageReaction.Constants.senderJid] as? String,
           let reactions = reactions[ChatMessageReaction.Constants.reactions] as? [String] {
            handleMessageReaction(message, senderJid: senderJid, reactions: reactions)
            return
        }
        
        // Android uses stanzaId as the id for linking reaction with the messages
        // Thus, stanzaId needs to be added to the messages sent from iOS
        if let account = ChatAccountModel.firstAccount(),
           let from = message.attributeStringValue(forName: "from"),
           let displayName = from.splitToArray(separator: "/").last,
           displayName.lowercased() == account.displayName.lowercased() {
            addStanzaIdToChatMessageIfAvailable(message)
        }
           
        // We don't handle incoming group chat messages here
        guard !message.containsGroupChatElements,
            // We handle carbons elsewhere via XMPPMessageCarbonsDelegate
            !message.isMessageCarbon,
            // We handle MAM elsewhere as well
            message.mamResult == nil,
            // OMEMO messages cannot be processed here
            !message.omemo_hasEncryptedElement(.conversationsLegacy),
            // Call info cannot be processed here
            !message.containsCallElements,
            !message.containsJmiElements,
            let accountId = sender.accountId else {
            return
        }
        
        // plain text location
        guard var messageString = message.body,
            messageString.count > 0 else {
                handleDirectMessage(message, body: nil, original: nil, accountId: accountId, split: false)
                return
        }

        handleDirectMessage(message, body: nil, original: nil, accountId: accountId, split: false)
    }
    
    private func handleMessageReaction(_ message: XMPPMessage,
                                       senderJid: String,
                                       reactions: [String]) {
        
        guard let id = message.reactionsId else { return }
        
        var chatMessageReactions = [ChatMessageReaction]()
        guard let chatMessage = ChatMessageModel.message(forMessageId: id, checkIncomingType: false) as? ChatMessageModel else {
            var roomMessage: ChatRoomMessageModel?
            if let msgWithXmppId = ChatRoomMessageModel.getMessage(withXmppId: id) {
                roomMessage = msgWithXmppId
            } else if let msgWithStanzaId = ChatRoomMessageModel.getMessage(withStanzaId: id) {
                roomMessage = msgWithStanzaId
            }
            
            guard let chatRoomMessage = roomMessage else {
                return
            }
            if var messageReactions = chatRoomMessage.grdbRecord?.reactions {
                if let index = messageReactions.firstIndex(where: { $0.senderJid == senderJid }) {
                    var senderReactions = messageReactions[index]
                    senderReactions.reactions = reactions
                    messageReactions.remove(at: index)
                    if !reactions.isEmpty {
                        messageReactions.insert(senderReactions, at: index)
                    }
                } else {
                    messageReactions.append(ChatMessageReaction(senderJid: senderJid, reactions: reactions))
                }
                chatMessageReactions = messageReactions
            } else {
                chatMessageReactions = [ ChatMessageReaction(senderJid: senderJid, reactions: reactions) ]
            }
            
            chatRoomMessage.grdbRecord?.reactions = chatMessageReactions.isEmpty ? nil : chatMessageReactions
            chatRoomMessage.grdbRecord?.modified = Date()
            chatRoomMessage.save()
            return
        }
        
        if var messageReactions = chatMessage.grdbRecord?.reactions {
            if let index = messageReactions.firstIndex(where: { $0.senderJid == senderJid }) {
                var senderReactions = messageReactions[index]
                senderReactions.reactions = reactions
                messageReactions.remove(at: index)
                if !reactions.isEmpty {
                    messageReactions.insert(senderReactions, at: index)
                }
            } else {
                messageReactions.append(ChatMessageReaction(senderJid: senderJid, reactions: reactions))
            }
            chatMessageReactions = messageReactions
        } else {
            chatMessageReactions = [ ChatMessageReaction(senderJid: senderJid, reactions: reactions) ]
        }
        
        chatMessage.grdbRecord?.reactions = chatMessageReactions.isEmpty ? nil : chatMessageReactions
        chatMessage.grdbRecord?.modified = Date()
        chatMessage.save()
    }
}

extension MessageStorage: XMPPMessageCarbonsDelegate {

    public func xmppMessageCarbons(_ xmppMessageCarbons: XMPPMessageCarbons, didReceive message: XMPPMessage, outgoing isOutgoing: Bool) {
        guard let accountId = xmppMessageCarbons.xmppStream?.accountId,
        !message.omemo_hasEncryptedElement(.conversationsLegacy) else {
            return
        }
        var _forJID: XMPPJID? = nil
        if !isOutgoing {
            _forJID = message.from
        } else {
            _forJID = message.to
        }
        guard let forJID = _forJID else { return }
        handleForwardedMessage(message, forJID: forJID, body: nil, original: nil, accountId: accountId, delayed: nil, isIncoming: !isOutgoing, isOutgoingFromOtherDevice: false, split: false)
    }
}

extension MessageStorage: XMPPMessageArchiveManagementDelegate {
    public func xmppMessageArchiveManagement(_ xmppMessageArchiveManagement: XMPPMessageArchiveManagement, didFinishReceivingMessagesWith resultSet: XMPPResultSet) {
        mamCatchupInProgress = false
        
        if callQuery == false {
            guard let accountId = xmppMessageArchiveManagement.xmppStream?.accountId,
                  let account = ChatAccountModel.getXMPPAccount(uniqueId: accountId) else {
                return
            }
            account.grdbRecord?.lastHistoryFetchDate = self.fetchDate
            account.saveXMPPAccountAsync()
        }
        self.callQuery = false
    }
    
    public func xmppMessageArchiveManagement(_ xmppMessageArchiveManagement: XMPPMessageArchiveManagement, didFailToReceiveMessages error: XMPPIQ) {
        DDLogError("Failed to receive messages \(String(describing: error))")
    }
    
    public func xmppMessageArchiveManagement(_ xmppMessageArchiveManagement: XMPPMessageArchiveManagement, didReceiveMAMMessage message: XMPPMessage) {
        guard let accountId = xmppMessageArchiveManagement.xmppStream?.accountId,
            let myJID = xmppMessageArchiveManagement.xmppStream?.myJID,
            let result = message.mamResult,
            let forwarded = result.forwardedMessage,
            let from = forwarded.from,
              !forwarded.omemo_hasEncryptedElement(.conversationsLegacy) else {
                DDLogVerbose("Discarding incoming MAM message \(message)")
                return
        }
        
        if forwarded.containsJmiElements {
            if let origto = message.to, origto.bare == from.bare, origto.resource != from.resource {
                return
            }
            
            if self.awaitingJmiPropose == true, let propose = forwarded.element(forName: "propose", xmlnsPrefix: CallManager.JINGLE_MESSAGE) {
                DDLogInfo("***** didReceiveMAMMessage and awaitingJmiPropose")
                let caller = forwarded.fromStr ?? ""
                let callid = propose.attributeStringValue(forName: "id") ?? ""
                if let uuid = UUID(uuidString: callid) {
                    var callType:CallType = .audio
                    if CallManager.sharedCallManager().hasVideoDescription(in: propose) {
                        callType = .video
                    }
                    
                    CallManager.sharedCallManager().handleJMIPropose(uuid: uuid, callId: callid, caller: caller, callType: callType)
                }
                self.awaitingJmiPropose = false
            }
            return
        }
        
        if let unwrapped = forwarded.omemo_offline(), unwrapped.omemo_hasEncryptedElement(.conversationsLegacy) {
            return
        }
        
        let delayed = result.forwardedStanzaDelayedDeliveryDate
        let isIncoming = !from.isEqual(to: myJID, options: .bare)
        var _forJID: XMPPJID? = nil
        if isIncoming {
            _forJID = forwarded.from
        } else {
            _forJID = forwarded.to
        }
        guard let forJID = _forJID else { return }
        
        var isOutgoingFromOtherDevice = false
        if let origto = message.to {
            if (origto.bare == from.bare && origto.resource != from.resource) {
                isOutgoingFromOtherDevice = true
            }
        }
        
        handleForwardedMessage(forwarded, forJID: forJID, body: nil, original: nil, accountId: accountId, delayed: delayed, isIncoming: isIncoming, isOutgoingFromOtherDevice: isOutgoingFromOtherDevice, split: false)
    }
}

// MARK: - Private Extensions

extension XMPPMessage {
    /// We don't want any group chat stuff ending up in here, including invites
    var containsGroupChatElements: Bool {
        let message = self
        guard message.messageType != .groupchat,
        message.element(forName: "x", xmlns: XMPPMUCUserNamespace) == nil,
            message.element(forName: "x", xmlns: XMPPConferenceXmlns) == nil else {
                return true
        }
        
        if let offline = message.omemo_offline() {
            let offmsg = XMPPMessage(from: offline)
            guard offmsg.messageType != .groupchat,
                  offmsg.element(forName: "x", xmlns: XMPPMUCUserNamespace) == nil,
                  offmsg.element(forName: "x", xmlns: XMPPConferenceXmlns) == nil else {
                return true
            }
        } else if let mam = message.mamResult, let forwarded = mam.forwardedMessage {
            if let offline = forwarded.omemo_offline() {
                let offmsg = XMPPMessage(from: offline)
                guard offmsg.messageType != .groupchat,
                      offmsg.element(forName: "x", xmlns: XMPPMUCUserNamespace) == nil,
                      offmsg.element(forName: "x", xmlns: XMPPConferenceXmlns) == nil else {
                    return true
                }
            }
        }
        
        return false
    }
    
    var containsCallElements: Bool {
        let message = self
        guard message.element(forName: "x", xmlns: "jabber:x:callupdate") == nil else {
            return true
        }
        return false
    }
    
    var containsJmiElements: Bool {
        let message = self
        guard message.elements(forXmlns: "urn:xmpp:jingle-message:0").count == 0 else {
            return true
        }
        return false
    }
    
    var containsProceedElement: Bool {
        let message = self
        guard message.element(forName: "proceed", xmlns: "urn:xmpp:jingle-message:0") == nil else {
            return true
        }
        return false
    }
}

extension ChatState {
    static func chatState(from fromState: XMPPMessage.ChatState?) -> ChatState {
        guard let from = fromState else {
            return .unknown
        }
        var chatState: ChatState = .unknown
        switch from {
        case .composing:
            chatState = .composing
        case .paused:
            chatState = .paused
        case .active:
            chatState = .active
        case .inactive:
            chatState = .inactive
        case .gone:
            chatState = .gone
        }
        return chatState
    }
}

extension String {
    static let OTRWhitespaceStart = String(bytes: [0x20,0x09,0x20,0x20,0x09,0x09,0x09,0x09,0x20,0x09,0x20,0x09,0x20,0x09,0x20,0x20], encoding: .utf8)!
    
    /// for separately handling OTR messages
    var isOtrText: Bool {
        return self.contains("?OTR") || self.contains(String.OTRWhitespaceStart)
    }
}

extension ChatMessageModel {
    public static func message(forMessageId messageId: String, incoming: Bool) -> MessageProtocol? {
        var deliveredMessage: MessageProtocol? = nil
        if let message = ChatMessageModel.getMessage(elementId: messageId, originId: nil, stanzaId: nil), message.isMessageIncoming == incoming {
            deliveredMessage = message
        }
        
        return deliveredMessage
    }

    public static func message(forMessageId messageId: String, checkIncomingType: Bool = true) -> MessageProtocol? {
        guard checkIncomingType else {
            if let message = ChatMessageModel.getMessage(elementId: messageId, originId: nil, stanzaId: nil) {
                return message
            }
            return nil
        }
        
        if self is IncomingChatMessage.Type {
            return self.message(forMessageId: messageId, incoming: true)
        } else {
            return self.message(forMessageId: messageId, incoming: false)
        }
    }
    
    static func getMessage(outgoing: Bool, xmppMessage: XMPPMessage, body: String?, account: ChatAccountModel, buddy: ChatBuddy, capabilities: XMPPCapabilities) -> ChatMessage {
        var message = ChatMessage()
        message.text = body ?? xmppMessage.body
        message.buddyUniqueId = buddy.uniqueId
        message.chatBuddyId = buddy.id!
        if let delayed = xmppMessage.delayedDeliveryDate {
            message.date = delayed
        } else {
            message.date = Date()
        }
        if let elementId = xmppMessage.elementID {
            message.xmppId = elementId
        }
        
        if outgoing {
            message.msgSenderId = account.uniqueId
            message.msgSenderDisplayName = account.displayName
            message.type = ChatMessageType.outgoing.rawValue
        } else {
            message.msgSenderId = buddy.uniqueId
            let cbuddy = ChatBuddyModel(buddy: buddy)
            message.msgSenderDisplayName = cbuddy.displayName
            message.type = ChatMessageType.incoming.rawValue
        }
        
        message.parentObjectCollection = ChatMessageModel.collection()
        message.parentObjectKey = buddy.uniqueId
        
        // Extract XEP-0359 stanza-id
        message.originId = xmppMessage.originId
        message.stanzaId = xmppMessage.extractStanzaId(chatAccount: account)
        
        return message
    }
}

extension NSCopying {
    /// Creates a deep copy of the object
    func copyAsSelf() -> Self? {
        return self.copy() as? Self
    }
}

public extension MessageStorage {
    //IOSM-443 added account
    @objc static func markAsReadIfVisible(message: MessageProtocol, account: ChatAccountModel) {
        guard message.isMessageRead == false else {
            return
        }
        OTRAppDelegate.visibleThread({ (key, collection) in
            guard let key = key,
            let collection = collection,
            key == message.threadId,
            collection == message.threadCollection else {
                return
            }
            
            if message.isMessageRead == false, let message = message.copyMessage() {
                if let incoming = message as? IncomingChatMessage {
                    incoming.grdbRecord?.modified = Date()
                    incoming.grdbRecord?.read = true
                    
                    var shouldShowReadReceipts = true
                    if let buddyUniqueId = incoming.grdbRecord?.buddyUniqueId,
                       let buddy = ChatBuddyModel.getBuddy(uniqueId: buddyUniqueId),
                       let chatThread = ChatThread.getChatThread(threadId: buddy.chatThreadId) {
                        shouldShowReadReceipts = chatThread.shouldShowReadReceipts
                    }
                    
                    //IOSM-443
                    if shouldShowReadReceipts, message.isMarkable == true, let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account) {
                        xmpp.sendReadReceipt(message)
                    }
                } else if let roomMessage = message as? ChatRoomMessageModel {
                    roomMessage.grdbRecord?.modified = Date()
                    roomMessage.grdbRecord?.read = true
                    
                    var shouldShowReadReceipts = true
                    if let roomJid = roomMessage.roomJID,
                       let xmppJid = XMPPJID(string: roomJid),
                       let chatRoom = ChatRoomModel.getXMPPRoom(roomJid: xmppJid),
                       let chatThread = ChatThread.getChatThread(threadId: chatRoom.chatThreadId) {
                        shouldShowReadReceipts = chatThread.shouldShowReadReceipts
                    }
                    
                    //IOSM-443
                    if shouldShowReadReceipts, message.isMarkable == true, let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account) {
                        xmpp.sendReadReceipt(message)
                    }
                }
                message.save()
            }
        })
    }
}

public extension XMPPMessage {
    /// Safely extracts XEP-0359 stanza-id
    @objc func extractStanzaId(chatAccount: ChatAccountModel) -> String? {
        let stanzaIds = self.stanzaIds
        guard stanzaIds.count > 0 else {
            return nil
        }
        
        if let myJID = chatAccount.bareJID, let sid = stanzaIds[myJID] {
            return sid
        }
        if let fromJID = self.from?.bareJID,
            let sid = stanzaIds[fromJID] {
            return sid
        }
        return nil
    }
}
