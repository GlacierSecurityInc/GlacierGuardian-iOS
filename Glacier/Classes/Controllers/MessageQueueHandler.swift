//
//  MessageQueueHandler.swift
//  ChatSecure
//
//  Created by David Chiles on 5/4/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

import Foundation
import XMPPFramework
import CocoaLumberjack

/// This is just small struct to store the necessary inormation about a message while we wait for delegate callbacks from the XMPPStream
private struct OutstandingMessageInfo {
    let messageKey:String
    let messageCollection:String
    let messageSecurity:OTRMessageTransportSecurity
    let timer:Timer?
    let completion:((_ success: Bool, _ retryTimeout: TimeInterval) -> Void)
}

/// Needed so we can store the struct in a dictionary
extension OutstandingMessageInfo: Hashable {
    var hashValue: Int {
        get {
            return "\(self.messageKey)\(self.messageCollection)".hashValue
        }
    }
}

extension OutstandingMessageInfo: Equatable {}
private func ==(lhs: OutstandingMessageInfo, rhs: OutstandingMessageInfo) -> Bool {
    return lhs.messageKey == rhs.messageKey && lhs.messageCollection == rhs.messageCollection
}

public class MessageQueueHandler:NSObject {
    
    public var accountRetryTimeout:TimeInterval = 30
    public var otrTimeout:TimeInterval = 7
    public var messageRetryTimeout:TimeInterval = 10
    public var maxFailureCount:UInt = 2
    
    let operationQueue = OperationQueue()
    fileprivate var outstandingMessages = [String:OutstandingMessageInfo]()
    fileprivate var outstandingBuddies = [String:OutstandingMessageInfo]()
    fileprivate let isolationQueue = DispatchQueue(label: "MessageQueueHandler-IsolationQueue", attributes: [])
    fileprivate var accountLoginNotificationObserver:NSObjectProtocol?
    fileprivate var retryList: [OutstandingMessageInfo] = []
    
    @objc override public init() {
        self.operationQueue.maxConcurrentOperationCount = 1
        super.init()
#if !TARGET_IS_EXTENSION
        self.accountLoginNotificationObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: kOTRProtocolLoginSuccess), object: nil, queue: self.operationQueue, using: { [weak self] (notification) in
            self?.handleAccountLoginNotification(notification)
        })
#endif
    }
    
    deinit {
        if let observer = self.accountLoginNotificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    //MARK: Access to outstanding messages and account
    
    fileprivate func waitingForBuddy(_ buddyKey:String,messageKey:String, messageCollection:String, messageSecurity:OTRMessageTransportSecurity, timer:Timer,completion:@escaping (_ success: Bool, _ retryTimeout: TimeInterval) -> Void) {
        
        let messageInfo = OutstandingMessageInfo(messageKey: messageKey, messageCollection: messageCollection,messageSecurity:messageSecurity, timer:nil, completion: completion)
        
        self.isolationQueue.async {
            self.outstandingBuddies.updateValue(messageInfo, forKey: buddyKey)
        }
    }
    
    fileprivate func popWaitingBuddy(_ buddyKey:String) -> OutstandingMessageInfo? {
        var messageInfo:OutstandingMessageInfo? = nil
        self.isolationQueue.sync {
            messageInfo = self.outstandingBuddies.removeValue(forKey: buddyKey)
        }
        return messageInfo
    }
    
    fileprivate func waitingForMessage(_ messageKey:String,messageCollection:String,messageSecurity:OTRMessageTransportSecurity,completion:@escaping (_ success: Bool, _ retryTimeout: TimeInterval) -> Void) {
        let messageInfo = OutstandingMessageInfo(messageKey: messageKey, messageCollection: messageCollection, messageSecurity:messageSecurity, timer:nil, completion: completion)
        let key = "\(messageKey)\(messageCollection)"
        
        self.isolationQueue.async {
            self.outstandingMessages.updateValue(messageInfo, forKey: key)
        }
    }
    
    /**
     * Remove a waiting message info from the outstaning message dictionary. After the message info is removed the completion block should be called.
     * This ensures that the outstandingMessages dictionary is accessed from the correct queue.
     *
     * - parameter messageKey: The database messsage key.
     * - parameter messageCollection: The database message key.
     * - returns: The OutstandingMessageInfo if one exists. Removed from the waiting dictioanry.
     */
    fileprivate func popWaitingMessage(_ messageKey:String,messageCollection:String) -> OutstandingMessageInfo? {
        var messageInfo:OutstandingMessageInfo? = nil
        let key = "\(messageKey)\(messageCollection)"
        self.isolationQueue.sync {
            messageInfo = self.outstandingMessages.removeValue(forKey: key)
        }
        
        return messageInfo
    }
    
    //MARK: Database Functions
    
    fileprivate func fetchMessage(_ key:String, collection:String) -> MessageProtocol? {
        var message:MessageProtocol?
        if collection == ChatRoomMessageModel.collection() {
            message = ChatRoomMessageModel.getMessage(with: key)
        } else {
            message = ChatMessageModel.getMessage(with: key)
        }
        return message
    }
    
#if !TARGET_IS_EXTENSION
    //MARK: XMPPManager functions
    @objc public func addMessage(_ message:MessageProtocol) {
        let messageInfo = OutstandingMessageInfo(messageKey: message.messageKey, messageCollection: message.messageCollection, messageSecurity:message.messageSecurity, timer:nil, completion:{(success, retryTimeout) in
            //do stuff
        })
        self.sendMessage(messageInfo)
    }
    
    fileprivate func sendMessage(_ outstandingMessage:OutstandingMessageInfo) {
        self.operationQueue.addOperation { [weak self] in
            guard let strongSelf = self else {
                outstandingMessage.completion(true, 0.0)
                return
            }
            
            strongSelf.sendMessage(outstandingMessage, completion: outstandingMessage.completion)
        }
    }
    
    fileprivate func sendDirectMessage(_ message: OutgoingChatMessage,
                                       buddy: ChatBuddyModel,
                                       account: ChatAccountModel,
                                       accountProtocol: XMPPManager,
                                       completion:@escaping (_ success: Bool, _ retryTimeout: TimeInterval) -> Void) {
        switch message.messageSecurity {
        case .plaintext:
            self.waitingForMessage(message.uniqueId, messageCollection: message.messageCollection, messageSecurity:message.messageSecurity, completion: completion)
            OTRProtocolManager.sharedInstance().send(message)
            break
        case .OMEMO:
            self.sendOMEMOMessage(message: message, accountProtocol: accountProtocol, completion: completion)
            break
        case .invalid, .plaintextWithOTR, .OTR:
            fatalError("Invalid message security. This should never happen... so let's crash!")
            break
        @unknown default: //handle as plaintext
            self.waitingForMessage(message.uniqueId, messageCollection: message.messageCollection, messageSecurity:message.messageSecurity, completion: completion)
            OTRProtocolManager.sharedInstance().send(message)
        }
    }
    
    fileprivate func sendGroupMessage(_ message: ChatRoomMessageModel,
                                      thread: ChatThreadModel,
                                      accountProtocol: XMPPManager,
                                      completion:@escaping (_ success: Bool, _ retryTimeout: TimeInterval) -> Void) {
        let roomManager = accountProtocol.roomManager
        guard let roomJidString = message.roomJID,
            let roomJid = XMPPJID(string: roomJidString),
            let room = roomManager.room(for: roomJid),
            let roomMsg = message.grdbRecord else {
            // Can't send a message to nowhere...
            DDLogError("Cannot send group message to nowhere \(message)")
            completion(true, 0.0)
            return
        }
        
        // this is where we send plain if public room
        let xroom = message.room()
        if ((xroom != nil) && (message.messageSecurity != .plaintext)) {
            if let msgText = message.messageText {
                if (msgText.hasSuffix("added to the group") || msgText.hasSuffix("left the group")) {
                    message.messageSecurity = .plaintext;
                    message.save(withThread: thread)
                }
            }
        }
        
        self.waitingForMessage(message.uniqueId, messageCollection: message.messageCollection, messageSecurity:message.messageSecurity, completion: completion)
        
        switch message.messageSecurity {
        case .invalid, .plaintextWithOTR, .OTR:
            assertionFailure("Invalid group message security. This should never happen.")
            DDLogError("Invalid group message security. This should never happen.")
            return
        case .plaintext:
            room.sendRoomMessage(roomMsg)
        case .OMEMO:
            sendOMEMOMessage(message: message, accountProtocol: accountProtocol, completion: completion)
        @unknown default:
            room.sendRoomMessage(roomMsg)
        }
        
        if let sentMessage = message.copyMessage() as? ChatRoomMessageModel {
            sentMessage.grdbRecord?.state = ChatRoomMessageState.pendingSent.rawValue
            sentMessage.save()
        }
    }
    
    fileprivate func sendMessage(_ outstandingMessage:OutstandingMessageInfo, completion:@escaping (_ success: Bool, _ retryTimeout: TimeInterval) -> Void) {
        
        let messageKey = outstandingMessage.messageKey
        let messageCollection = outstandingMessage.messageCollection
        let anyMessage = self.fetchMessage(messageKey, collection: messageCollection)
        
        guard let message = anyMessage else {
            // Somehow we have an action without a message. This is very strange. Do not like.
            // We tell the queue broker that we handle it successfully so it will be rmeoved and go on to the next action.
            completion(true, 0.0)
            return
        }
        
        let threadOwner = message.threadOwner()
        var acc:ChatAccountModel? = nil

        if let owner = threadOwner {
            acc = ChatAccountModel.getChatAccount(owner.threadAccountIdentifier)
        }
        
        guard let thread = threadOwner, let account = acc else {
            completion(true, 0.0)
            return
        }
        
        //Get the XMPP procol manager associated with this message and therefore account
        guard let accountProtocol = OTRProtocolManager.sharedInstance().xmppManager(forChatAccount: account) else {
            completion(true, 0.0)
            return
        }
        
        /**
         * Message is considered successuflly sent if the stream responds with didSendMessage.
         * When XEP-0198 is enabled and when an ack is reveived in (x) seconds then it is later makered as failed. It is up to the user to resubmit
         * a msesage to be sent.
         */
        //Some way to store a message dictionary with the key and block
        
        //Ensure protocol is connected or if not and autologin then connnect
        if (accountProtocol.loginStatus == .authenticated) {
            if let groupMessage = message as? ChatRoomMessageModel {
                sendGroupMessage(groupMessage, thread: thread, accountProtocol: accountProtocol, completion: completion)
            } else if let chatMsg = message as? ChatMessageModel, let buddy = chatMsg.buddy(), let cm = chatMsg.grdbRecord {
                let directMessage = OutgoingChatMessage(message: cm)
                sendDirectMessage(directMessage, buddy: buddy, account: account, accountProtocol: accountProtocol, completion: completion)
            } else {
                // Unsupported message type
                completion(true, 0.0)
                return
            }
        } else {
            retryList.append(outstandingMessage)
            accountProtocol.connectUserInitiated(false)
            completion(false, 0.0)
        }
    }
    
    //Mark: Callback for Account
    
    fileprivate func handleAccountLoginNotification(_ notification:Notification) {
        guard let userInfo = notification.userInfo as? [String:AnyObject] else {
            return
        }
        if let accountKey = userInfo[kOTRNotificationAccountUniqueIdKey] as? String, let accountCollection = userInfo[kOTRNotificationAccountCollectionKey] as? String  {
            self.didConnectAccount(accountKey, accountCollection: accountCollection)
        }
    }
    
    fileprivate func didConnectAccount(_ accountKey:String, accountCollection:String) {
        self.retryList.forEach({ (outstandingMsg) in
            self.sendMessage(outstandingMsg)
        })
        
        self.retryList.removeAll()
        /*self.operationQueue.addOperation { [weak self] in
            guard let strongSelf = self else { return }
            DispatchQueue.global().async {
                //
            }
        }*/
    }
#endif
    
    
}

#if !TARGET_IS_EXTENSION
//MARK: Callback from protocol
extension MessageQueueHandler: OTRXMPPMessageStatusModuleDelegate {
    
    public func didSendMessage(_ messageKey: String, messageCollection: String) {
        guard let messageInfo = self.popWaitingMessage(messageKey, messageCollection: messageCollection) else {
            return;
        }
        
        //Update date sent
        var msgprot:MessageProtocol?
        if messageCollection == ChatRoomMessageModel.collection() {
            msgprot = ChatRoomMessageModel.getMessage(with: messageKey)
        } else {
            msgprot = ChatMessageModel.getMessage(with: messageKey)
        }
        guard let msg = msgprot else {
            return
        }
        //let copy = msg.copy()
        if let message = msg as? ChatRoomMessageModel {
            message.grdbRecord?.state = ChatRoomMessageState.sent.rawValue
            message.save()
        } else if let message = msg as? ChatMessageModel {
            message.grdbRecord?.dateSent = Date()
            message.grdbRecord?.readDate = Date()
            message.grdbRecord?.modified = Date()
            message.save()
        }
        
        messageInfo.completion(true, 0.0)
    }
    
    public func didFailToSendMessage(_ messageKey:String, messageCollection:String, error:NSError?) {
        guard let messageInfo = self.popWaitingMessage(messageKey, messageCollection: messageCollection) else {
            return;
        }
        
        //Even though this action failed we need to keep the queue moving.
        messageInfo.completion(true, 0.0)
    }
}
#endif

#if !TARGET_IS_EXTENSION
// Message sending logic
extension MessageQueueHandler {
    typealias MessageQueueHandlerCompletion = (_ success: Bool, _ retryTimeout: TimeInterval) -> Void
    
    func sendOMEMOMessage(message:MessageProtocol, accountProtocol:XMPPManager,completion:@escaping MessageQueueHandlerCompletion) {
        guard let text = message.messageText, text.count > 0 else {
            completion(true, 0.0)
            return
        }
        guard let signalCoordinator = accountProtocol.omemoSignalCoordinator else {
            guard let message = message.copyMessage() else {
                return
            }
            message.messageError = NSError.chatSecureError(EncryptionError.omemoNotSuported, userInfo: nil)
            message.save()
            completion(true, 0.0)
            return
        }
        self.waitingForMessage(message.uid, messageCollection: message.messageCollection, messageSecurity:message.messageSecurity, completion: completion)
        
        signalCoordinator.encryptAndSendMessage(message, completion: { (success, error) in
            //if success == true {
            //    if let outmessage = message as? OutgoingChatMessage {
            //        outmessage.grdbRecord?.dateSent = Date()
            //        outmessage.grdbRecord?.readDate = Date()
            //        outmessage.save()
            //    }
            //} else {
            if success == false {
                // plain text if OMEMO not available?
                if message is OutgoingChatMessage {
                    OTRProtocolManager.sharedInstance().send(message as! OutgoingChatMessage)
                }
                //IOSM-338 derivative - no longer want to send unencrypted?
                
                //Something went wrong getting ready to send the message
                //Save error object to message
                guard let message = message.copyMessage() else {
                    return
                }
                    
                //IOSM#75
                if let message = message as? ChatRoomMessageModel {
                    message.grdbRecord?.state = ChatRoomMessageState.sent.rawValue
                    message.save()
                } else if let message = message as? OutgoingChatMessage {
                    message.grdbRecord?.dateSent = Date()
                    message.grdbRecord?.readDate = Date()
                    message.save()
                }
                
                if let messageInfo = self.popWaitingMessage(message.uid, messageCollection: message.messageCollection) {
                    //Even though we were not succesfull in sending a message. The action needs to be removed from the queue so the next message can be handled.
                    messageInfo.completion(true, 0.0)
                }
            }
        })
    }
}
#endif
