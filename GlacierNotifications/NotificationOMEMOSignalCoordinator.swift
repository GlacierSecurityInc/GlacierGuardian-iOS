//
//  NotificationOMEMOSignalCoordinator.swift
//  GlacierNotifications
//
//  Created by Andy Friedman on 9/23/20.
//  Copyright © 2020 Glacier. All rights reserved.
//

import UIKit
import XMPPFramework
import KissXML
import CocoaLumberjack
import SignalProtocolObjC
import os

/// Privacy-safe diagnostic log for the push-decrypt path (subsystem "com.glaciersec.push").
/// Logs only non-sensitive facts — never JIDs, ciphertext, or decrypted plaintext.
private let pushLog = Logger(subsystem: "com.glaciersec.push", category: "Envelope")

@objc public protocol NotificationMessageDelegate: NSObjectProtocol {
    func decryptedMessage(_ message:NotificationMessage)
    func failedToDecryptMessage(_ message:NotificationMessage)
}

/**
 * This is the glue between XMPP/OMEMO and Signal
 */
@objc open class NotificationOMEMOSignalCoordinator: NSObject {
    
    public let signalEncryptionManager:AccountSignalEncryptionManager
    public let omemoStorageManager:OMEMOStorageManager
    @objc public let accountKey:String
    @objc open weak var omemoModule:OMEMOModule?
    @objc open weak var omemoModuleQueue:DispatchQueue?
    @objc open var callbackQueue:DispatchQueue
    @objc public let workQueue:DispatchQueue
    
    @objc open weak var delegate:NotificationMessageDelegate?

    fileprivate var myJID:XMPPJID? {
        get {
            return omemoModule?.xmppStream?.myJID
        }
    }
    let preKeyCount:UInt = 100
    fileprivate var outstandingXMPPStanzaResponseBlocks:[String: (Bool) -> Void]
    /// callbacks for when fetching device Id list
    private var deviceIdFetchCallbacks:[XMPPJID: (Bool) -> Void] = [:]
    /// OMEMO-over-push: sender's real bare JID supplied by the push payload (group messages).
    /// When set, extractAddressFromGroupMessage uses it directly instead of the DB occupant cache.
    private var pushSuppliedRealJID:XMPPJID?
    /// OMEMO-over-push: the message's stable identifiers, supplied by the sealed envelope.
    /// When set (push path only), the decrypt sink persists the message to the shared DB using
    /// these as the dedup key so the app's later MAM/live insert collapses onto the same row.
    /// Both nil on the MAM fallback path, which stays display-only. Cleared after each message.
    private var pushSuppliedOriginId:String?
    private var pushSuppliedStanzaId:String?
    
    /**
     Create a NotificationOMEMOSignalCoordinator for an account.
     
     - parameter accountKey: The accounts unique yap key
     - parameter notificationDelegate: The notification message delegate
 `  */
    @objc public required init(accountKey:String, notificationDelegate:NotificationMessageDelegate) throws {
        try self.signalEncryptionManager = AccountSignalEncryptionManager(accountKey: accountKey)
        self.omemoStorageManager = OMEMOStorageManager(accountKey: accountKey, accountCollection: ChatAccountModel.collection())
        self.accountKey = accountKey
        self.delegate = notificationDelegate
        self.outstandingXMPPStanzaResponseBlocks = [:]
        self.callbackQueue = DispatchQueue(label: "NotificationOMEMOSignalCoordinator-callback", attributes: [])
        self.workQueue = DispatchQueue(label: "NotificationOMEMOSignalCoordinator-work", attributes: [])
    }
    
    /**
     Checks that a jid matches our own JID using XMPPJIDCompareBare
     */
    fileprivate func isOurJID(_ jid:XMPPJID) -> Bool {
        guard let ourJID = self.myJID else {
            return false;
        }
        
        return jid.isEqual(to: ourJID, options: .bare)
    }
    
    /** Always call on internal work queue */
    fileprivate func callAndRemoveOutstandingBundleBlock(_ elementId:String,success:Bool) {
        
        guard let outstandingBlock = self.outstandingXMPPStanzaResponseBlocks[elementId] else {
            return
        }
        outstandingBlock(success)
        self.outstandingXMPPStanzaResponseBlocks.removeValue(forKey: elementId)
    }
    
    /** Always call on internal work queue */
    fileprivate func callAndRemoveOutstandingDeviceIdFetch(_ jid:XMPPJID,success:Bool) {
        guard let outstandingBlock = self.deviceIdFetchCallbacks[jid] else {
            return
        }
        outstandingBlock(success)
        self.deviceIdFetchCallbacks.removeValue(forKey: jid)
    }
    
    
    /**
     OMEMO-over-push entry point. Decrypts a message carried directly in the push payload,
     bypassing the MAM round-trip. All work here is local (Signal + GRDB) — no network — so
     it is much faster than the MAM path. Success/failure is reported through the existing
     `NotificationMessageDelegate` callbacks, exactly like the MAM path.

     - parameter base64Payload: base64 of the serialized `<encrypted>` element
     - parameter messageFrom:   bare from — room JID for group chats, sender JID for 1:1
     - parameter messageType:   stanza type, e.g. "groupchat" / "chat"
     - parameter senderRealJID: sender's real bare JID (group messages only); nil otherwise
     - returns: `true` if a well-formed `<encrypted>` element was parsed and handed to
       decryption (the delegate will report the result); `false` if the payload was malformed,
       in which case the caller should fall back to the MAM path.
     */
    /**
     OMEMO-over-push entry point for the sealed-box metadata envelope. Opens the `ge` envelope
     locally (libsodium, no network), recovers the routing fields, and hands them to the
     existing `decryptPushPayload`. Returns `true` if the envelope opened and decryption was
     attempted (the delegate reports the result); `false` if the envelope is unknown/tampered/
     malformed, so the caller falls back to MAM.
     */
    @objc public func openSealedPushEnvelope(kid: String, base64Data: String) -> Bool {
        guard let fields = PushMetadataEnvelope.open(kid: kid, base64Data: base64Data) else {
            return false
        }
        return decryptPushPayload(base64Payload: fields.payloadB64,
                                  messageFrom: fields.from,
                                  messageType: fields.type,
                                  senderRealJID: fields.sender,
                                  originId: fields.origin,
                                  stanzaId: fields.sid)
    }

    @objc public func decryptPushPayload(base64Payload: String, messageFrom: String, messageType: String, senderRealJID: String?, originId: String?, stanzaId: String?) -> Bool {
        guard let xmlData = Data(base64Encoded: base64Payload, options: .ignoreUnknownCharacters),
              let xmlString = String(data: xmlData, encoding: .utf8),
              let encrypted = try? DDXMLElement(xmlString: xmlString) else {
            pushLog.error("decrypt: <encrypted> base64/XML parse failed")
            return false
        }

        // sid / <key rid> / <iv> / <payload>. These accessors read child elements by name and
        // are NOT namespace-filtered, so they work regardless of which OMEMO namespace the
        // server stamps on the <encrypted> element.
        let senderDeviceId = encrypted.omemo_senderDeviceId()
        guard senderDeviceId > 0,
              let keyData = encrypted.omemo_keyData(), keyData.count > 0,
              let iv = encrypted.omemo_iv(),
              let fromJID = XMPPJID(string: messageFrom) else {
            pushLog.error("decrypt: malformed <encrypted> header (sid=\(senderDeviceId, privacy: .public))")
            return false
        }
        let payload = encrypted.omemo_payload()
        pushLog.info("decrypt: group=\(messageType == "groupchat", privacy: .public) sid=\(senderDeviceId, privacy: .public) hasPayload=\(payload != nil, privacy: .public)")

        // Reconstruct just enough of the stanza for the existing classification / room
        // attribution code to work unchanged: isGroupChatMessage checks type == "groupchat",
        // and the group room lookup keys off message.from.bareJID.
        let message = XMPPMessage(type: messageType)
        message.addAttribute(withName: "from", stringValue: messageFrom)
        message.addChild(encrypted)

        // Group attribution: use the supplied real JID directly (the occupant cache is
        // unreliable in the extension). Cleared in defer so it never leaks to a later message.
        if let real = senderRealJID, real.count > 0 {
            self.pushSuppliedRealJID = XMPPJID(string: real)
        } else {
            self.pushSuppliedRealJID = nil
        }
        // Stable identifiers for persistence (push path only). Cleared in the same defer so a
        // later message decrypted on this coordinator can never inherit a stale id.
        self.pushSuppliedOriginId = (originId?.isEmpty == false) ? originId : nil
        self.pushSuppliedStanzaId = (stanzaId?.isEmpty == false) ? stanzaId : nil
        defer {
            self.pushSuppliedRealJID = nil
            self.pushSuppliedOriginId = nil
            self.pushSuppliedStanzaId = nil
        }

        processKeyData(keyData, iv: iv, senderDeviceId: senderDeviceId, forJID: fromJID, payload: payload, delayed: nil, forwarded: false, isIncoming: true, message: message, originalMessage: message)
        return true
    }

    /// transforms incoming group message into JID matching a 1:1 Buddy
    private func extractAddressFromGroupMessage(_ message: XMPPMessage) -> XMPPJID? {
        // OMEMO-over-push: the push payload supplies the sender's real bare JID directly.
        // The extension's occupant cache is populated only by the foreground app, so on a
        // cold push it's usually stale/missing — prefer the supplied JID and skip the DB lookup.
        if let suppliedJID = self.pushSuppliedRealJID {
            return suppliedJID.bareJID
        }

        if let fromJID = message.from {
            let roomJID = fromJID.bareJID
            // This formula is defined in XMPPRoom.roomYapKey
            let accountId = accountKey
            var _occupant: ChatRoomOccupantModel? = ChatRoomOccupantModel.occupant(jid: fromJID, realJID: nil, roomJID: roomJID, accountId: accountId, createIfNeeded: false)

            // we've found the existing 1:1 buddy!
            if let buddy = _occupant?.buddy() {
                return XMPPJID(string: buddy.username)//buddyModel.bareJID
            } else {
                if let occupant = _occupant, let realJid = occupant.realJID {
                    return realJid.bareJID
                }

                /*if let user = fromJID.resource {
                    if let userjid = handleNoBuddy(message, fromname: user) {
                        return userjid
                    }
                }*/

                // No usable real JID. Previously this returned the occupant nick
                // (occupant.jid?.resource) as if it were a JID, which Signal then silently
                // failed to decrypt against. Fail cleanly so the caller can fall back.
                return nil
            }
        }
        return nil
    }
    
    func handleNoBuddy(_ message: XMPPMessage, fromname: String) -> XMPPJID? {
        var budjid: XMPPJID? = nil
        if let account = ChatAccountModel.getXMPPAccount(uniqueId: self.accountKey) {
            ChatBuddyModel.getAllBuddies(for: account.uniqueId).forEach { (buddy) in
                let tempjid = XMPPJID(string: buddy.username)
                if (fromname == buddy.displayName || fromname == tempjid?.user) {
                    budjid = tempjid
                    return
                }
            }
            
            let fromJID = message.from
            if (account.displayName == fromJID?.resource) {
                budjid = XMPPJID(string: account.username)
            }
        }
        
        return budjid
    }
    
    @objc public func processUnencryptedData(_ isIncoming: Bool, message: XMPPMessage, forJID: XMPPJID) {
        var decryptedMsg = NotificationMessage()
        guard let myJID = self.myJID else {
            delegate?.failedToDecryptMessage(decryptedMsg)
            return
        }
        var _addressJID: XMPPJID? = nil
        var isIncoming = isIncoming
        
        // handle incoming group chat messages slightly differently
        if message.isGroupChatMessage {
            if let groupAddressJID = extractAddressFromGroupMessage(message) {
                _addressJID = groupAddressJID
                if groupAddressJID.isEqual(to: myJID, options: .bare) {
                    isIncoming = false
                } else {
                    isIncoming = true
                }
            } else {
                DDLogWarn("Found Incoming OMEMO group message, but corresponding Buddy could not be found!")
                delegate?.failedToDecryptMessage(decryptedMsg)
                return
            }
        } else {
            if !isIncoming {
                delegate?.failedToDecryptMessage(decryptedMsg)
                return
            } else {
                _addressJID = forJID.bareJID
            }
            
        }
        guard let addressJID = _addressJID else {
            delegate?.failedToDecryptMessage(decryptedMsg)
            return
        }
        
        decryptedMsg = getBuddyInfo(decryptedMsg, from: addressJID)
        let displayName = decryptedMsg.from
        if message.isGroupChatMessage {
            if let fromJID = message.from {
                let roomJID = fromJID.bareJID
                
                let accountId = accountKey
                let roomUniqueId = ChatRoomModel.createUniqueId(accountId, jid: roomJID.bare)
                let roomLocalPart = roomJID.bare.components(separatedBy: "@").first ?? roomJID.bare
                if let xroom = ChatRoomModel.getXMPPRoom(uniqueId: roomUniqueId) {
                    // threadName falls back to the bare room JID when no roomName/subject is
                    // set (common in the extension on a cold push) — never show a domain in the
                    // title; use the room JID local part instead.
                    let roomName = xroom.threadName
                    decryptedMsg.from = (roomName.isEmpty || roomName.contains("@")) ? roomLocalPart : roomName
                    decryptedMsg.threadId = xroom.threadIdentifier
                } else if roomLocalPart.count > 0 {
                    //decryptedMsg.from = "#" + roomLocalPart
                    decryptedMsg.from = roomLocalPart
                }
                decryptedMsg.threadCollection = ChatRoomModel.collection()
            }
        } else {
            decryptedMsg.threadCollection = ChatBuddyModel.collection()
        }
        
        guard var messageString = message.body, messageString.count > 0 else {
            if (displayName != nil && message.isGroupChatMessage) {
                decryptedMsg.message = "From: " + displayName!
            }
            //delegate?.failedToDecryptMessage(decryptedMsg)
            return
        }
        
        if (messageString.hasPrefix("geo:")) {
            messageString = "Location Received"
        }
        
        messageString = getMediaString(messageString)
        
        if (displayName != nil && message.isGroupChatMessage) {
            decryptedMsg.message = displayName! + ": " + messageString
        } else {
            decryptedMsg.message = messageString
        }
        
        delegate?.decryptedMessage(decryptedMsg)
    }
    
    @objc public func processKeyData(_ keyData: [OMEMOKeyData], iv: Data, senderDeviceId: UInt32, forJID: XMPPJID, payload: Data?, delayed: Date?, forwarded: Bool, isIncoming: Bool, message: XMPPMessage, originalMessage: XMPPMessage) {
        var isIncoming = isIncoming
        let aesGcmBlockLength = 16
        var decryptedMsg = NotificationMessage()
        guard let encryptedPayload = payload, encryptedPayload.count > 0, let myJID = self.myJID else {
            delegate?.failedToDecryptMessage(decryptedMsg)
            return
        }
        var _addressJID: XMPPJID? = nil
        // handle incoming group chat messages slightly differently
        if message.isGroupChatMessage {
            if let fromJID = message.from {
                let roomJID = fromJID.bareJID
                
                let accountId = accountKey
                let roomUniqueId = ChatRoomModel.createUniqueId(accountId, jid: roomJID.bare)
                let roomLocalPart = roomJID.bare.components(separatedBy: "@").first ?? roomJID.bare
                if let xroom = ChatRoomModel.getXMPPRoom(uniqueId: roomUniqueId) {
                    // threadName falls back to the bare room JID when no roomName/subject is
                    // set (common in the extension on a cold push) — never show a domain in the
                    // title; use the room JID local part instead.
                    let roomName = xroom.threadName
                    decryptedMsg.from = (roomName.isEmpty || roomName.contains("@")) ? roomLocalPart : roomName
                    decryptedMsg.threadId = xroom.threadIdentifier
                } else if roomLocalPart.count > 0 {
                    //decryptedMsg.from = "#" + roomLocalPart
                    decryptedMsg.from = roomLocalPart
                }
                decryptedMsg.threadCollection = ChatRoomModel.collection()
            }
            
            if let groupAddressJID = extractAddressFromGroupMessage(message) {
                _addressJID = groupAddressJID
                if groupAddressJID.isEqual(to: myJID, options: .bare) {
                    isIncoming = false
                } else {
                    isIncoming = true
                }
            } else {
                DDLogWarn("Found Incoming OMEMO group message, but corresponding Buddy could not be found!")
                delegate?.failedToDecryptMessage(decryptedMsg)
                return
            }
        } else {
            if !isIncoming {
                delegate?.failedToDecryptMessage(decryptedMsg)
                return
            } else {
                _addressJID = forJID.bareJID
            }
        }
        guard let addressJID = _addressJID else {
            delegate?.failedToDecryptMessage(decryptedMsg)
            return
        }
        
        //let displayName = getDisplayName(message, from: addressJID)
        var buddyInfoMsg = NotificationMessage()
        buddyInfoMsg = getBuddyInfo(buddyInfoMsg, from: addressJID)
        let displayName = buddyInfoMsg.from
        if !message.isGroupChatMessage {
            decryptedMsg = buddyInfoMsg
            decryptedMsg.threadCollection = ChatBuddyModel.collection()
        }
        
        let rid = self.signalEncryptionManager.registrationId
        
        //Could have multiple matching device id. This is extremely rare but possible that the sender has another device that collides with our device id.
        var unencryptedKeyData: Data?
        for key in keyData where key.deviceId == rid {
            let keydata = key.data
            do {
                unencryptedKeyData = try self.signalEncryptionManager.decryptFromAddress(keydata, name: addressJID.bare, deviceId: senderDeviceId)
                // have successfully decripted the AES key. We should break and use it to decrypt the payload
                break
            } catch let error {
                DDLogError("Error decrypting OMEMO message for \(addressJID): \(error) \(message)")
                if (displayName != nil && message.isGroupChatMessage) {
                    decryptedMsg.message = "From: " + displayName!
                }
                delegate?.failedToDecryptMessage(decryptedMsg)
                return
            }
        }
        
        guard var aesKey = unencryptedKeyData else {
            delegate?.failedToDecryptMessage(decryptedMsg)
            return
        }
        var authTag: Data?
        
        // Treat >=32 bytes OMEMO 'keys' as containing the auth tag.
        // https://github.com/ChatSecure/ChatSecure-iOS/issues/647
        if (aesKey.count >= aesGcmBlockLength * 2) {
            
            authTag = aesKey.subdata(in: aesGcmBlockLength..<aesKey.count)
            aesKey = aesKey.subdata(in: 0..<aesGcmBlockLength)
        }
        
        var tmpBody: Data?
        // If there's already an auth tag, that means the payload
        // doesn't contain the auth tag.
        if authTag != nil { // omemo namespace
            tmpBody = encryptedPayload
        } else { // 'siacs' namespace fallback
            
            tmpBody = encryptedPayload.subdata(in: 0..<encryptedPayload.count - aesGcmBlockLength)
            authTag = encryptedPayload.subdata(in: encryptedPayload.count - aesGcmBlockLength..<encryptedPayload.count)
        }
        guard let tag = authTag, let encryptedBody = tmpBody else {
            if (displayName != nil && message.isGroupChatMessage) {
                decryptedMsg.message = "From: " + displayName!
            }
            delegate?.failedToDecryptMessage(decryptedMsg)
            return
        }
        
        do {
            guard let messageBody = try SignalEncryptionHelper.decryptData(encryptedBody, key: aesKey, iv: iv, authTag: tag),
            var messageString = String(data: messageBody, encoding: String.Encoding.utf8),
            messageString.count > 0 else {
                if (displayName != nil && message.isGroupChatMessage) {
                    decryptedMsg.message = "From: " + displayName!
                }
                delegate?.failedToDecryptMessage(decryptedMsg)
                return
            }

            // Persist the message to the shared DB BEFORE building the display string and
            // before notifying the delegate, so the row is committed while we still hold the
            // extension's time budget. Uses the raw decrypted body (e.g. an aesgcm:// URL),
            // not the "Image received"/"Location Received" display text. No-op unless the
            // sealed envelope supplied an originId (push path only); the MAM fallback stays
            // display-only. Best-effort — a write failure never blocks the notification.
            persistDecryptedPushMessage(rawBody: messageString,
                                        isIncoming: isIncoming,
                                        message: message,
                                        addressJID: addressJID)

            if (messageString.hasPrefix("geo:")) {
                messageString = "Location Received"
            }

            messageString = getMediaString(messageString)

            if (displayName != nil && message.isGroupChatMessage) {
                decryptedMsg.message = displayName! + ": " + messageString
            } else {
                decryptedMsg.message = messageString
            }

            delegate?.decryptedMessage(decryptedMsg)

        } catch let error {
            if (displayName != nil && message.isGroupChatMessage) {
                decryptedMsg.message = "From: " + displayName!
            }
            delegate?.failedToDecryptMessage(decryptedMsg)
            DDLogError("Message decryption error: \(error)")
            return
        }
    }

    /// Persists a freshly decrypted push message to the shared DB so the thread is current the
    /// moment the user opens the app. Runs only on the push path (gated on a non-empty
    /// `pushSuppliedOriginId`, which the MAM fallback never sets) and only for incoming
    /// messages. Resolves the buddy/room + sender attribution the same way the display path
    /// does, then hands off to the synchronous model-level writers. Best-effort: any failure is
    /// logged and swallowed so it can never block or delay the notification.
    fileprivate func persistDecryptedPushMessage(rawBody: String,
                                                 isIncoming: Bool,
                                                 message: XMPPMessage,
                                                 addressJID: XMPPJID) {
        guard isIncoming else { return }
        guard let originId = self.pushSuppliedOriginId, !originId.isEmpty else { return }
        guard rawBody.count > 0 else { return }
        guard let account = ChatAccountModel.getXMPPAccount(uniqueId: self.accountKey) else { return }
        let stanzaId = self.pushSuppliedStanzaId
        let date = message.delayedDeliveryDate ?? Date()

        if message.isGroupChatMessage {
            guard let roomFrom = message.from?.bareJID else { return }
            let roomUniqueId = ChatRoomModel.createUniqueId(self.accountKey, jid: roomFrom.bare)
            guard let room = ChatRoomModel.getXMPPRoom(uniqueId: roomUniqueId) else { return }

            // Sender attribution mirrors getBuddyInfo: prefer a matched buddy, else fall back
            // to the sender's nick/real-jid user part so the row still names a sender.
            var senderDisplay = addressJID.user ?? (message.from?.resource ?? "")
            var buddyUid: String? = nil
            if let buddy = ChatBuddyModel.fetchBuddyModel(jid: addressJID, accountUniqueId: account.uniqueId) {
                senderDisplay = buddy.displayName
                buddyUid = buddy.uniqueId
            }
            let msgSenderId = buddyUid ?? (message.from?.resource ?? senderDisplay)

            let result = ChatRoomMessageModel.persistIncomingRoomMessage(account: account,
                                                            room: room,
                                                            text: rawBody,
                                                            date: date,
                                                            originId: originId,
                                                            stanzaId: stanzaId,
                                                            senderJidFull: message.from?.full,
                                                            realJidBare: addressJID.bare,
                                                            msgSenderId: msgSenderId,
                                                            msgSenderDisplayName: senderDisplay,
                                                            buddyUniqueId: buddyUid,
                                                            omemoDeviceKey: nil)
            logPersistResult(result, group: true, hasStanzaId: stanzaId != nil)
        } else {
            guard let buddy = ChatBuddyModel.fetchBuddyModel(jid: addressJID, accountUniqueId: account.uniqueId) else { return }
            let result = ChatMessageModel.persistIncomingDirectMessage(account: account,
                                                          buddy: buddy,
                                                          text: rawBody,
                                                          date: date,
                                                          originId: originId,
                                                          stanzaId: stanzaId,
                                                          omemoDeviceKey: nil)
            logPersistResult(result, group: false, hasStanzaId: stanzaId != nil)
        }
    }

    /// Privacy-safe diagnostic for the NSE DB-write path. Logs only the outcome, message kind,
    /// and whether a stanza-id was present — never the body, JIDs, or origin/stanza values.
    /// Watch with: `log stream --predicate 'subsystem == "com.glaciersec.push"'`.
    ///   inserted  → the NSE wrote the row (the feature is working)
    ///   duplicate → the app's MAM/live path already stored it (raced and lost — also fine)
    ///   failed    → bad inputs or a write error (see the DDLogError detail)
    fileprivate func logPersistResult(_ result: NSEPersistResult, group: Bool, hasStanzaId: Bool) {
        let outcome: String
        switch result {
        case .inserted:  outcome = "inserted"
        case .duplicate: outcome = "duplicate"
        case .failed:    outcome = "failed"
        }
        pushLog.info("persist: \(outcome, privacy: .public) group=\(group, privacy: .public) hasSid=\(hasStanzaId, privacy: .public)")
    }

    fileprivate func getBuddyInfo(_ message:NotificationMessage, from: XMPPJID) -> NotificationMessage {
        message.from = from.user
        if let account = ChatAccountModel.getXMPPAccount(uniqueId: self.accountKey), let buddy = ChatBuddyModel.fetchBuddy(jid: from, accountUniqueId: account.uniqueId) {
                    
            let tempjid = XMPPJID(string: buddy.username)
            if (from.user == tempjid?.user) {
                message.from = buddy.displayName
                message.threadId = buddy.uniqueId
            }
        }
        return message
    }
    
    fileprivate func getMediaString (_ messageString:String) -> String {
        if messageString.count == 0 || messageString.downloadableURLs.count == 0 {
            return messageString
        }
        var mediaString = messageString
        
        if let fileurl = mediaString.downloadableURLs.first {
            if (fileurl.lastPathComponent.hasSuffix(".null")) {
                let fullPathComponent = fileurl.lastPathComponent
                let end = fullPathComponent.index(fullPathComponent.endIndex, offsetBy: -5)
                let range = fullPathComponent.startIndex..<end
                mediaString = String(fullPathComponent[range])
            }
            
            if (mediaString.contains("#")) {
                let components = mediaString.components(separatedBy: "#")
                mediaString = components[0]
            }
            mediaString = mediaString.lowercased()
            
            if mediaString.hasSuffix(".m4a") || mediaString.hasSuffix(".wav") {
                mediaString = "Audio received"
            } else if mediaString.hasSuffix(".jpg") || mediaString.hasSuffix(".png") || mediaString.hasSuffix(".jpeg") || mediaString.hasSuffix(".gif") {
                mediaString = "Image received"
            } else if mediaString.hasSuffix(".mov") || mediaString.hasSuffix(".qt") || mediaString.hasSuffix(".mp4") {
                mediaString = "Video received"
            } else if mediaString.hasSuffix(".pdf") || mediaString.hasSuffix(".doc") || mediaString.hasSuffix(".docx") {
                mediaString = "File received"
            } else {
                mediaString = "Media received"
            }
        }
        
        return mediaString
    }
}

// MARK: - OMEMOModuleDelegate
extension NotificationOMEMOSignalCoordinator: OMEMOModuleDelegate {
    
    public func omemo(_ omemo: OMEMOModule, publishedDeviceIds deviceIds: [NSNumber], responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
        //DDLogVerbose("publishedDeviceIds: \(responseIq)")

    }
    
    public func omemo(_ omemo: OMEMOModule, failedToPublishDeviceIds deviceIds: [NSNumber], errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        DDLogWarn("failedToPublishDeviceIds: \(String(describing: errorIq))")
    }
    
    public func omemo(_ omemo: OMEMOModule, deviceListUpdate deviceIds: [NSNumber], from fromJID: XMPPJID, incomingElement: XMPPElement) {
        //
    }
    
    public func omemo(_ omemo: OMEMOModule, failedToFetchDeviceIdsFor fromJID: XMPPJID, errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        //
    }
    
    public func omemo(_ omemo: OMEMOModule, publishedBundle bundle: OMEMOBundle, responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
        //DDLogVerbose("publishedBundle: \(responseIq) \(outgoingIq)")
    }
    
    public func omemo(_ omemo: OMEMOModule, failedToPublishBundle bundle: OMEMOBundle, errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        DDLogWarn("failedToPublishBundle: \(String(describing: errorIq)) \(outgoingIq)")
    }
    
    public func omemo(_ omemo: OMEMOModule, fetchedBundle bundle: OMEMOBundle, from fromJID: XMPPJID, responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
        //DDLogVerbose("fetchedBundle: \(responseIq) \(outgoingIq)")

        if (self.isOurJID(fromJID) && bundle.deviceId == self.signalEncryptionManager.registrationId) {
            //DDLogVerbose("fetchedOurOwnBundle: \(responseIq) \(outgoingIq)")

            //We fetched our own bundle
            /*if let ourDatabaseBundle = self.fetchMyBundle() {
                //This bundle doesn't have the correct identity key. Something has gone wrong and we should republish
                if ourDatabaseBundle.identityKey != bundle.identityKey {
                    //DDLogError("Bundle identityKeys do not match! \(ourDatabaseBundle.identityKey) vs \(bundle.identityKey)")
                    omemo.publishBundle(ourDatabaseBundle, elementId: nil)
                }
            }*/
            return;
        }
        
        self.workQueue.async { [weak self] in
            let elementId = outgoingIq.elementID
            if (bundle.preKeys.count == 0) {
                self?.callAndRemoveOutstandingBundleBlock(elementId!, success: false)
                return
            }
            var result = false
            //Consume the incoming bundle. This goes through signal and should hit the storage delegate. So we don't need to store ourselves here.
            do {
                try self?.signalEncryptionManager.consumeIncomingBundle(fromJID.bare, bundle: bundle)
                result = true
            } catch let err {
                DDLogWarn("Error consuming incoming bundle: \(err) \(responseIq.prettyXMLString())")
            }
            self?.callAndRemoveOutstandingBundleBlock(elementId!, success: result)
        }
        
    }
    public func omemo(_ omemo: OMEMOModule, failedToFetchBundleForDeviceId deviceId: UInt32, from fromJID: XMPPJID, errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        //
    }
    
    public func omemo(_ omemo: OMEMOModule, removedBundleId bundleId: UInt32, responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
        
    }
    
    public func omemo(_ omemo: OMEMOModule, failedToRemoveBundleId bundleId: UInt32, errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        DDLogWarn("Error removing bundle: \(String(describing: errorIq))")
    }
    
    public func omemo(_ omemo: OMEMOModule, failedToRemoveDeviceIds deviceIds: [NSNumber], errorIq: XMPPIQ?, elementId: String?) {
        //
    }
    
    public func omemo(_ omemo: OMEMOModule, receivedKeyData keyData: [OMEMOKeyData], iv: Data, senderDeviceId: UInt32, from fromJID: XMPPJID, payload: Data?, message: XMPPMessage) {
        self.processKeyData(keyData, iv: iv, senderDeviceId: senderDeviceId, forJID: fromJID, payload: payload, delayed: nil, forwarded: false, isIncoming: true, message: message, originalMessage: message)
    }
    
    public func omemo(_ omemo: OMEMOModule, receivedForwardedKeyData keyData: [OMEMOKeyData], iv: Data, senderDeviceId: UInt32, for forJID: XMPPJID, payload: Data?, isIncoming: Bool, delayed: Date?, forwardedMessage: XMPPMessage, originalMessage: XMPPMessage) {
        self.processKeyData(keyData, iv: iv, senderDeviceId: senderDeviceId, forJID: forJID, payload: payload, delayed: delayed, forwarded: true, isIncoming: isIncoming, message: forwardedMessage, originalMessage: originalMessage)
    }
}

// MARK: - OMEMOStorageDelegate
extension NotificationOMEMOSignalCoordinator:OMEMOStorageDelegate {
    
    public func configure(withParent aParent: OMEMOModule, queue: DispatchQueue) -> Bool {
        self.omemoModule = aParent
        self.omemoModuleQueue = queue
        return true
    }
    
    public func storeDeviceIds(_ deviceIds: [NSNumber], for jid: XMPPJID) {
        
        /*let isOurDeviceList = self.isOurJID(jid)
        
        
        if (isOurDeviceList) {
            self.omemoStorageManager.storeOurDevices(deviceIds)
        } else {
            self.omemoStorageManager.storeBuddyDevices(deviceIds, buddyUsername: jid.bare, completion: {() -> Void in
            })
        }*/
        callAndRemoveOutstandingDeviceIdFetch(jid, success: true)
    }
    
    public func fetchDeviceIds(for jid: XMPPJID) -> [NSNumber] {
        var devices:[ChatOmemoDevice]?
        
        if self.isOurJID(jid) {
            devices = self.omemoStorageManager.getDevicesForOurAccount(trustedOnly: false)
        } else {
            devices = self.omemoStorageManager.getDevicesForBuddy(jid.bare, trustedOnly:false)
        }
        //Convert from devices array to NSNumber array.
        return (devices?.map({ (device) -> NSNumber in
            return NSNumber(value: device.deviceId)
        })) ?? [NSNumber]()
        
    }

    //Always returns most complete bundle with correct count of prekeys
    public func fetchMyBundle() -> OMEMOBundle? {
        return nil
        /*var _bundle: OMEMOBundle? = nil
        
        do {
            _bundle = try signalEncryptionManager.storage.fetchOurExistingBundle()
            
        } catch let omemoError as OMEMOBundleError {
            switch omemoError {
            case .invalid:
                DDLogError("Found invalid stored bundle!")
                // delete???
                break
            default:
                break
            }
        } catch let error {
            DDLogError("Other error fetching bundle! \(error)")
        }
        let maxTries = 50
        var tries = 0
        while _bundle == nil && tries < maxTries {
            tries = tries + 1
            do {
                _bundle = try self.signalEncryptionManager.generateOutgoingBundle(self.preKeyCount)
            } catch let error {
                DDLogError("Error generating bundle! Try #\(tries)/\(maxTries) \(error)")
            }
        }
        guard let bundle = _bundle else {
            DDLogError("Could not fetch or generate valid bundle!")
            return nil
        }
        
        var preKeys = bundle.preKeys
        
        let keysToGenerate = Int(self.preKeyCount) - preKeys.count
        
        //Check if we don't have all the prekeys we need
        if (keysToGenerate > 0) {
            var start:UInt = 0
            if let maxId = self.signalEncryptionManager.storage.currentMaxPreKeyId() {
                start = UInt(maxId) + 1
            }
            
            if let newPreKeys = self.signalEncryptionManager.generatePreKeys(start, count: UInt(keysToGenerate)) {
                let omemoKeys = OMEMOPreKey.preKeysFromSignal(newPreKeys)
                preKeys.append(contentsOf: omemoKeys)
            }
        }
        
        let newBundle = bundle.copyBundle(newPreKeys: preKeys)
        return newBundle*/
    }

    public func isSessionValid(_ jid: XMPPJID, deviceId: UInt32) -> Bool {
        return self.signalEncryptionManager.sessionRecordExistsForUsername(jid.bare, deviceId: Int32(deviceId))
    }
}

@objc public class NotificationMessage:NSObject {
    @objc public var from:String?
    @objc public var message:String?
    @objc public var threadId:String?
    @objc public var threadCollection:String?
}


// expand to http?
enum URLScheme: String {
    case https = "https"
    case aesgcm = "aesgcm"
    static let downloadableSchemes: [URLScheme] = [.https, .aesgcm]
}

extension URL {
    
    /** URL scheme matches aesgcm:// */
    var isAesGcm: Bool {
        return scheme == URLScheme.aesgcm.rawValue
    }
    
}

public extension NSString {
    var isSingleURLOnly: Bool {
        return (self as String).isSingleURLOnly
    }
}

public extension String {
    
    private var urlRanges: ([URL], [NSRange]) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return ([], [])
        }
        var urls: [URL] = []
        var ranges: [NSRange] = []
        
        let matches = detector.matches(in: self, options: NSRegularExpression.MatchingOptions(rawValue: 0), range: NSRange(location: 0, length: self.utf16.count))
        
        for match in matches where match.resultType == .link {
            if let url = match.url {
                if (!url.absoluteString.hasPrefix("mailto")) {
                    urls.append(url)
                    ranges.append(match.range)
                }
            }
        }
        return (urls, ranges)
    }
    
    /** Grab any URLs from a string */
    var urls: [URL] {
        let (urls, _) = urlRanges
        return urls
    }
    
    /** Returns true if the message is ONLY a single URL */
    var isSingleURLOnly: Bool {
        let (_, ranges) = urlRanges
        guard ranges.count == 1,
            let range = ranges.first,
            range.length == self.count else {
            return false
        }
        return true
    }
    
    /** Use this for extracting potentially downloadable URLs from a message. Currently checks for https:// and aesgcm:// */
    var downloadableURLs: [URL] {
        
        return urlsMatchingSchemes(URLScheme.downloadableSchemes)
    }
    
    fileprivate func urlsMatchingSchemes(_ schemes: [URLScheme]) -> [URL] {
        let urls = self.urls.filter {
            guard let scheme = $0.scheme?.lowercased() else { return false }
            for inScheme in schemes where inScheme.rawValue == scheme {
                return true
            }
            return false
        }
        return urls
    }
}
