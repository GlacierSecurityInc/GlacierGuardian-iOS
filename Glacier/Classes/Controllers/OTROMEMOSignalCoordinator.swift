//  ChatSecure
//  Created by David Chiles on 8/4/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.

import UIKit
import XMPPFramework
import CocoaLumberjack
import SignalProtocolObjC
import GRDB

/** 
 * This is the glue between XMPP/OMEMO and Signal
 */
@objc open class OTROMEMOSignalCoordinator: NSObject {

    @objc public static let DeviceListUpdateNotificationName = Notification.Name(rawValue: "DeviceListUpdateNotification")
    
    public let signalEncryptionManager:OTRAccountSignalEncryptionManager
    public let omemoStorageManager:OTROMEMOStorageManager
    @objc public let accountKey:String
    @objc open weak var omemoModule:OMEMOModule?
    @objc open weak var omemoModuleQueue:DispatchQueue?
    @objc open var callbackQueue:DispatchQueue
    @objc public let workQueue:DispatchQueue
    @objc public let messageStorage: MessageStorage
    @objc public let roomManager: OTRXMPPRoomManager
    fileprivate var myjid:XMPPJID?
    
    var semaphore = DispatchSemaphore(value: 1)
    
    private var roomStorage: RoomStorage {
        return roomManager.roomStorage
    }

    fileprivate var myJID:XMPPJID? {
        get {
            if let jid = self.myjid {
                return jid
            }
            return omemoModule?.xmppStream?.myJID
        }
    }
    let preKeyCount:UInt = 100
    fileprivate var outstandingXMPPStanzaResponseBlocks:[String: (Bool) -> Void]
    /// callbacks for when fetching device Id list
    private var deviceIdFetchCallbacks:[XMPPJID: (Bool) -> Void] = [:]

    private var lekList:[UInt32] = []

    private func requestBundlesForOurDevicesIfNeeded(deviceIds: [NSNumber], jid: XMPPJID) {
        guard let omemoModule = self.omemoModule else { return }

        let remoteDeviceIds = Set(deviceIds.map { UInt32(truncating: $0) })
        guard !remoteDeviceIds.isEmpty else { return }

        var missingDeviceIds: [UInt32] = []

        do {
            try DBManager.sharedDB().grdbStorage.read { transaction in
                let storedDevices = ChatOmemoDevice.allOMEMODevices(for: self.accountKey,
                                                                    collection: ChatAccountModel.collection(),
                                                                    transaction: transaction)
                missingDeviceIds = storedDevices.compactMap { device in
                    guard device.publicIdentityKeyData == nil,
                          let deviceId = UInt32(exactly: device.deviceId),
                          remoteDeviceIds.contains(deviceId) else {
                        return nil
                    }
                    return deviceId
                }
            }
        } catch {
            DDLogError("Error reading OMEMO devices for bundle fetch: \(error)")
        }

        guard !missingDeviceIds.isEmpty else { return }

        DDLogInfo("Requesting OMEMO bundles for \(missingDeviceIds.count) of our devices missing identity keys")

        missingDeviceIds.forEach { deviceId in
            omemoModule.fetchBundle(forDeviceId: deviceId, jid: jid, elementId: nil)
        }
    }
    
    private struct SessionVars {
        var key:String
        var collection:String
        var devices: [ChatOmemoDevice]
        var trustedDevices: [ChatOmemoDevice]
        var user: String?
    }
    
    /**
     Create a OTROMEMOSignalCoordinator for an account. 
     
     - parameter accountKey: The accounts unique key
 `  */
    @objc public required init(accountKey:String,
                               messageStorage: MessageStorage,
                               roomManager: OTRXMPPRoomManager) throws {
        try self.signalEncryptionManager = OTRAccountSignalEncryptionManager(accountKey: accountKey)
        self.omemoStorageManager = OTROMEMOStorageManager(accountKey: accountKey, accountCollection: ChatAccountModel.collection())
        self.accountKey = accountKey
        self.outstandingXMPPStanzaResponseBlocks = [:]
        self.callbackQueue = DispatchQueue(label: "OTROMEMOSignalCoordinator-callback", attributes: [])
        self.workQueue = DispatchQueue(label: "OTROMEMOSignalCoordinator-work", attributes: [])
        self.messageStorage = messageStorage
        self.roomManager = roomManager
    }
    
    @objc public func setJID(_ jid:XMPPJID) {
        self.myjid = jid
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
     This must be called before sending every message. It ensures that for every device there is a session and if not the bundles are fetched.
     
     - parameter buddyKey: The key for the buddy to check
     - parameter completion: The completion closure called on callbackQueue. If it successfully was able to fetch all the bundles or if it wasn't necessary. If there were no devices for this buddy it will also return flase
     */
    @objc open func prepareSessionForBuddy(_ buddyKey:String, completion:@escaping (Bool) -> Void) {
        let sessionVars = self.prepSession(buddyKey, collection: ChatBuddyModel.collection(), transaction: nil)
        self.prepareSession(sessionVars, completion: completion)
    }
    
    @objc open func prepareSessionForBuddy(_ buddyKey:String, transaction: GRDBWriteTransaction, completion:@escaping (Bool) -> Void) {
        let sessionVars = self.prepSession(buddyKey, collection: ChatBuddyModel.collection(), transaction: transaction)
        self.prepareSession(sessionVars, completion: completion)
    }
    
    /**
     This must be called before sending every message. Gets the variables ready to be used for preparing the session.
     
     - parameter key: The key for the buddy or account to check
     - parameter collection: The key for the buddy or account to check
     - parameter transaction: Used if we are currently inside a DB transaction
     */
    private func prepSession(_ key:String, collection:String, transaction:GRDBWriteTransaction?) -> SessionVars {
        var devices:[ChatOmemoDevice] = []
        var trustedDevices:[ChatOmemoDevice] = [] //IOSM#75
        var user:String? = nil
        
        //Get all the devices ID's for this buddy as well as their username for use with signal and XMPPFramework.
        if let transaction = transaction {
            devices = ChatOmemoDevice.allOMEMODevices(for: key, collection: collection, transaction: transaction)
            trustedDevices = ChatOmemoDevice.allOMEMODevices(for: key, collection: collection, transaction: transaction, trusted: true) //IOSM#75
            user = self.fetchUsername(key, collection: collection, transaction:transaction)
        } else {
            do {
                try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                    devices = ChatOmemoDevice.allOMEMODevices(for: key, collection: collection, transaction: transaction)
                    trustedDevices = ChatOmemoDevice.allOMEMODevices(for: key, collection: collection, transaction: transaction, trusted: true) //IOSM#75
                    user = self.fetchUsername(key, collection: collection, transaction:transaction)
                })
            } catch {
                DDLogError("ChatOmemoDevice.allOMEMODevices error: \(error)")
            }
        }
        
        //IOSM#75
        if trustedDevices.count == 0, devices.count > 0 {
            for device in devices {
                var deviceCopy = device
                deviceCopy.trustLevel = device.trustLevel
                if ((deviceCopy.trustLevel == OMEMOTrustLevel.trustedUser.rawValue || deviceCopy.trustLevel == OMEMOTrustLevel.trustedTofu.rawValue) && device.isExpired()) {
                    if let date = Calendar.current.date(byAdding: .day, value: -44, to: Date()) {
                        deviceCopy.lastSeenDate = date
                        if let transaction = transaction {
                            deviceCopy.grdbSave(transaction: transaction)
                        } else {
                            deviceCopy.save()
                        }
                    }
                }
            }
        }
        
        return SessionVars(key: key, collection: collection, devices: devices, trustedDevices: trustedDevices, user: user)
    }
    
    /**
     This must be called before sending every message. It ensures that for every device there is a session and if not the bundles are fetched.
     
     - parameter vars: The session variables for the buddy or account
     - parameter completion: The completion closure called on callbackQueue. If it successfully was able to fetch all the bundles or if it wasn't necessary. If there were no devices for this buddy it will also return false
     */
    private func prepareSession(_ vars:SessionVars, completion:@escaping (Bool) -> Void) {
        
        guard let username = vars.user,
            let jid = XMPPJID(string:username) else {
            self.callbackQueue.async(execute: {
                completion(false)
            })
            return
        }
        
        var devices = vars.devices
        let bundleFetch = { [weak self] in
            guard let strongself = self else {
                return
            }
            var finalSuccess = true
            let group = DispatchGroup()
            
            //For each device Check if we have a session. If not then we need to fetch it from their XMPP server.
            var fetchlist:[Int] = []
            do {
                try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                    for device in devices where UInt32(device.deviceId) != self?.signalEncryptionManager.storage.getLocalRegistrationId(transaction) {
                        if !strongself.signalEncryptionManager.sessionRecordExistsForUsername(username, deviceId: Int32(device.deviceId), transaction:transaction) || device.publicIdentityKeyData == nil {
                            //No session for this buddy and device combo. We need to fetch the bundle.
                            
                            fetchlist.append(device.deviceId)
                        }
                    }
                })
            } catch {
                DDLogDebug("OTROMEMOSignalCoordinator.bundleFetch: \(error)")
            }
            
            for devid in fetchlist {
                let elementId = UUID().uuidString
                
                group.enter()
                // Hold on to a closure so that when we get the call back from OMEMOModule we can call this closure.
                strongself.outstandingXMPPStanzaResponseBlocks[elementId] = { success in
                    if (!success) {
                        finalSuccess = false
                    }
                    
                    group.leave()
                }
                //Fetch the bundle
                strongself.omemoModule?.fetchBundle(forDeviceId: UInt32(devid), jid: jid, elementId: elementId)
            }
            
            if let cQueue = self?.callbackQueue {
                group.notify(queue: cQueue) {
                    completion(finalSuccess)
                }
            }
        }
        
        let deviceFetch = { [weak self] in
            guard let sself = self else {
                return
            }
            var deviceFetchSuccess = true
            let group = DispatchGroup()
            let elementId = UUID().uuidString
            
            group.enter()
            // Hold on to a closure so that when we get the call back from OMEMOModule we can call this closure.
            self?.deviceIdFetchCallbacks[jid] = { success in
                if (!success) {
                    deviceFetchSuccess = false
                }
                group.leave()
            }
            //Fetch the bundle
            self?.omemoModule?.fetchDeviceIds(for: jid, elementId: elementId)
            
            group.notify(queue: sself.workQueue) {
                devices = ChatOmemoDevice.allOMEMODevices(for: vars.key, collection: vars.collection)
                if deviceFetchSuccess == false {
                    DDLogWarn("Could not fetch devices for \(jid)")
                }
                if devices.count > 0 {
                    DDLogVerbose("Fetched \(devices.count) devices on the fly while sending message for \(jid)")
                    bundleFetch()
                } else {
                    self?.callbackQueue.async {
                        completion(false)
                    }
                }
            }
        }
        
        self.workQueue.async {
            // We are trying to send to someone but haven't fetched any devices
            // this might happen if we aren't subscribed to someone's presence in a group chat
            if devices.count == 0 {
                deviceFetch()
            } else {
                bundleFetch()
            }
        }
    }
    
    /**
     This must be called before sending every message. It ensures that for every device there is a session and if not the bundles are fetched.
     
     - parameter key: The key for the buddy or account to check
     - parameter collection: The key for the buddy or account to check
     - parameter completion: The completion closure called on callbackQueue. If it successfully was able to fetch all the bundles or if it wasn't necessary. If there were no devices for this buddy it will also return flase
     */
                        }
                    }
                })
            } catch {
                DDLogDebug("OTROMEMOSignalCoordinator.bundleFetch: \(error)")
            }
            
            for devid in fetchlist {
                let elementId = UUID().uuidString
                
                group.enter()
                // Hold on to a closure so that when we get the call back from OMEMOModule we can call this closure.
                strongself.outstandingXMPPStanzaResponseBlocks[elementId] = { success in
                    if (!success) {
                        finalSuccess = false
                    }
                    
                    group.leave()
                }
                //Fetch the bundle
                strongself.omemoModule?.fetchBundle(forDeviceId: UInt32(devid), jid: jid, elementId: elementId)
            }
            
            if let cQueue = self?.callbackQueue {
                group.notify(queue: cQueue) {
                    completion(finalSuccess)
                }
            }
        }
        
        let deviceFetch = { [weak self] in
            guard let sself = self else {
                return
            }
            var deviceFetchSuccess = true
            let group = DispatchGroup()
            let elementId = UUID().uuidString
            
            group.enter()
            // Hold on to a closure so that when we get the call back from OMEMOModule we can call this closure.
            self?.deviceIdFetchCallbacks[jid] = { success in
                if (!success) {
                    deviceFetchSuccess = false
                }
                group.leave()
            }
            //Fetch the bundle
            self?.omemoModule?.fetchDeviceIds(for: jid, elementId: elementId)
            
            group.notify(queue: sself.workQueue) {
                devices = ChatOmemoDevice.allOMEMODevices(for: key, collection: collection)
                if deviceFetchSuccess == false {
                    DDLogWarn("Could not fetch devices for \(jid)")
                }
                if devices.count > 0 {
                    DDLogVerbose("Fetched \(devices.count) devices on the fly while sending message for \(jid)")
                    bundleFetch()
                } else {
                    self?.callbackQueue.async {
                        completion(false)
                    }
                }
            }
        }
        
        self.workQueue.async {
            // We are trying to send to someone but haven't fetched any devices
            // this might happen if we aren't subscribed to someone's presence in a group chat
            if devices.count == 0 {
                deviceFetch()
            } else {
                bundleFetch()
            }
        }
    }*/
    
    fileprivate func fetchUsername(_ key:String, collection:String, transaction:GRDBReadTransaction?) -> String? {
        if let transaction = transaction {
            if collection == ChatAccountModel.collection() {
                if let acct = ChatAccountModel.getXMPPAccount(uniqueId: key, transaction: transaction) {
                    return acct.username
                }
            } else {
                if let buddy = ChatBuddyModel.getBuddy(uniqueId: key, transaction:transaction) {
                    return buddy.username
                }
            }
        } else {
            if collection == ChatAccountModel.collection() {
                if let acct = ChatAccountModel.getXMPPAccount(uniqueId: key) {
                    return acct.username
                }
            } else {
                if let buddy = ChatBuddyModel.getBuddy(uniqueId: key) {
                    return buddy.username
                }
            }
        }

        return nil
    }
    
    /**
     Check if we have valid sessions with our other devices and if not fetch their bundles and start sessions.
     */
    func prepareSessionWithOurDevices(_ transaction:GRDBWriteTransaction?, completion:@escaping (_ success:Bool) -> Void) {
        let sessionVars = self.prepSession(self.accountKey, collection: ChatAccountModel.collection(), transaction: transaction)
        self.prepareSession(sessionVars, completion: completion)
    }
    
    fileprivate func encryptPayloadWithSignalForDevice(_ device:ChatOmemoDevice, payload:Data, transaction: GRDBReadTransaction) throws -> OMEMOKeyData? {
        var user = self.fetchUsername(device.parentKey, collection: device.parentCollection, transaction: transaction)
        if let username = user {
            let encryptedKeyData = try self.signalEncryptionManager.encryptToAddress(payload, name: username, deviceId: UInt32(device.deviceId))
            var isPreKey = false
            if (encryptedKeyData.type == .preKeyMessage) {
                isPreKey = true
            }
            return OMEMOKeyData(deviceId: UInt32(device.deviceId), data: encryptedKeyData.data, isPreKey: isPreKey)
        }
        return nil
    }
    
    /**
     Gathers necessary information to encrypt a message to the buddy and all this accounts devices that are trusted. Then sends the payload via OMEMOModule
     
     - parameter messageBody: The boddy of the message
     - parameter buddyKey: The unique buddy key. Used for looking up the username and devices
     - parameter messageId: The preffered XMPP element Id to be used.
     - parameter completion: The completion block is called after all the necessary omemo preperation has completed and sendKeyData:iv:toJID:payload:elementId:expiration is invoked
     */
    open func encryptAndSendMessage(_ message: MessageProtocol, completion:@escaping (_ success: Bool, _ error: Error?) -> Void) {
        // Gather bundles for buddy and account here
        let group = DispatchGroup()
        var buddyKeys: [String] = []
        // destinationJID is either the XMPPRoom JID or ChatBuddyModel JID
        var destinationJID: XMPPJID?
        var sessionVars: [SessionVars] = []
        let prepareCompletion = { (success:Bool) in
            group.leave()
        }
        do {
            try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                var _destinationJID: XMPPJID?
                if let roomMessage = message as? ChatRoomMessageModel {
                    buddyKeys = roomMessage.allBuddyKeysForOutgoingMessage(transaction)
                    do {
                        _destinationJID = try roomMessage.room(transaction)?.roomJID
                    } catch {
                        print("Error getting buddy keys")
                    }
                } else if let directMessage = message as? OutgoingChatMessage {
                    buddyKeys = [message.threadId]
                    _destinationJID = directMessage.xmppBuddy(transaction)?.bareJID
                }
                guard buddyKeys.count > 0, let destJID = _destinationJID else {
                    completion(false, NSError.chatSecureError(OTROMEMOError.noDevicesForBuddy, userInfo: nil))
                    return
                }
                destinationJID = destJID
                buddyKeys.forEach { (key) in
                    group.enter()
                    let budVars = self.prepSession(key, collection: ChatBuddyModel.collection(), transaction: transaction)
                    sessionVars.append(budVars)
                }
                group.enter()
                let ourVars = self.prepSession(self.accountKey, collection: ChatAccountModel.collection(), transaction: transaction)
                sessionVars.append(ourVars)
                //Even if something went wrong fetching bundles we should push ahead. We may have sessions that can be used.
            })
        } catch {
            DDLogError("encryptAndSend error \(error)")
        }
        
        for vars in sessionVars {
            self.prepareSession(vars, completion: prepareCompletion)
        }
                
        group.notify(queue: self.workQueue) {
            var gcmData:Data = Data()
            var ivData:Data = Data()
            var ourDevicesKeyData:[OMEMOKeyData] = []
            var buddyKeyDataArray:[OMEMOKeyData] = []
            do {
                try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                    //Strong self work here
                    var buddies: [ChatBuddyModel] = buddyKeys.compactMap({ key in
                        ChatBuddyModel.getBuddy(uniqueId: key, transaction: transaction)
                    })
                    
                    guard buddies.count > 0 else {
                        completion(false, NSError.chatSecureError(OTROMEMOError.noDevicesForBuddy, userInfo: nil))
                        return
                    }
                    
                    guard let messageBody = message.messageText,
                          let iv = OTRSignalEncryptionHelper.generateIV(), let keyData = OTRSignalEncryptionHelper.generateSymmetricKey(), let messageBodyData = messageBody.data(using: String.Encoding.utf8) else {
                        
                        let error = NSError.chatSecureError(OTROMEMOError.unknownError, userInfo: nil)
                        completion(false,error)
                        
                        return
                    }
                    ivData = iv
                    
                    do {
                        //Create the encrypted payload
                        let gcm = try OTRSignalEncryptionHelper.encryptData(messageBodyData, key: keyData, iv: ivData)
                        gcmData = gcm.data
                        
                        // this does the signal encryption. If we fail it doesn't matter here. We end up trying the next device and fail later if no devices worked.
                        let encryptClosure:(ChatOmemoDevice) -> (OMEMOKeyData?) = { device in
                            do {
                                // new OMEMO format puts auth tag inside omemo session
                                let payload = keyData + gcm.authTag
                                return try self.encryptPayloadWithSignalForDevice(device, payload: payload, transaction: transaction)
                            } catch {
                                return nil
                            }
                        }
                        
                        /**
                         1. Get all devices for this buddy.
                         2. Filter only devices that are trusted.
                         3. encrypt to those devices.
                         4. Remove optional values
                         */
                        buddyKeyDataArray = buddyKeys.flatMap({ key in
                            self.omemoStorageManager.getDevicesForParentKey(key, collection: ChatBuddyModel.collection(), trustedOnly: true, transaction: transaction).map(encryptClosure).compactMap{ $0 }
                        })
                        
                        // Stop here if we were not able to encrypt to any of the buddies
                        if (buddyKeyDataArray.count == 0) {
                            self.callbackQueue.async(execute: {
                                let error = NSError.chatSecureError(OTROMEMOError.noDevicesForBuddy, userInfo: nil)
                                completion(false,error)
                            })
                            return
                        }
                        
                        /**
                         1. Get all devices for this this account.
                         2. Filter only devices that are trusted and not ourselves.
                         3. encrypt to those devices.
                         4. Remove optional values
                         */
                        
                        ourDevicesKeyData = self.omemoStorageManager.getDevicesForOurAccount(trustedOnly: true, transaction: transaction).filter({ (device) -> Bool in
                            return UInt32(device.deviceId) != self.signalEncryptionManager.storage.getLocalRegistrationId(transaction)
                        }).map(encryptClosure).compactMap{ $0 }
                    } catch let err {
                        //This should only happen if we had an error encrypting the payload
                        self.callbackQueue.async(execute: {
                            completion(false,err)
                        })
                        return
                    }
                })
            } catch {
                DDLogError("encryptAndSend error \(error)")
            }
                        
            // Combine teh two arrays for all key data
            let keyDataArray = ourDevicesKeyData + buddyKeyDataArray
                        
            //Make sure we have encrypted the symetric key to someone
            if (keyDataArray.count > 0), let destinationJID = destinationJID {
                // new OMEMO format puts auth tag inside omemo session
                let finalPayload = gcmData//.data
                            
                if let omemoCoord = self.omemoModule?.omemoStorage as? OTROMEMOSignalCoordinator {
                    if let myBundle = omemoCoord.fetchMyBundle() {
                        var eid = message.remoteMessageId
                        if (eid == nil || eid?.count == 0) {
                            eid = UUID().uuidString
                        }
                        var omemoMessage = XMPPMessage.omemo_message(withKeyData: keyDataArray, iv: ivData, senderDeviceId: myBundle.deviceId, to: destinationJID, payload: finalPayload, elementId: eid, xmlNamespace: self.omemoModule!.xmlNamespace)
                                    
                        if message is ChatRoomMessageModel {
                            omemoMessage.addAttribute(withName: "type", stringValue: "groupchat")
                            omemoMessage.addReceiptRequest()
                            omemoMessage.addMarkableChatMarker() //IOSM#8 read receipts
                            omemoMessage.addBody("Message cannot be decrypted.") //IOSM-605
                            self.sendOnStream(omemoMessage)
                        } else if message is OutgoingChatMessage {
                            omemoMessage.addMarkableChatMarker() //IOSM#8 read receipts
                            omemoMessage.addBody("Message cannot be decrypted.") //IOSM-605
                            if let expiration = message.messageExpires {
                                let expiresElement = XMLElement(name: "x", xmlns: "jabber:x:msgexpire")
                                expiresElement.addAttribute(withName: "seconds", stringValue: expiration)
                                omemoMessage.addChild(expiresElement)
                            }
                            self.sendOnStream(omemoMessage)
                        }
                    }
                } else if message is ChatRoomMessageModel,
                    let groupMessage = self.omemoModule?.message(forKeyData: keyDataArray, iv: ivData, to: destinationJID, payload: finalPayload, elementId: message.remoteMessageId)
                {
                    groupMessage.addAttribute(withName: "type", stringValue: "groupchat")
                    groupMessage.addReceiptRequest()
                    groupMessage.addMarkableChatMarker() //IOSM#8 read receipts
                    groupMessage.addBody("Message cannot be decrypted.") //IOSM-605
                    self.sendOnStream(groupMessage)
                } else if message is OutgoingChatMessage {
                    self.omemoModule?.sendKeyData(keyDataArray, iv: ivData, to: destinationJID, payload: finalPayload, elementId: message.remoteMessageId, expiration: message.messageExpires)
                }
                            
                self.callbackQueue.async(execute: {
                    completion(true,nil)
                })
                return
            } else {
                self.callbackQueue.async(execute: {
                    let error = NSError.chatSecureError(OTROMEMOError.noDevices, userInfo: nil)
                    completion(false,error)
                })
                return
            }
        }
    }
    
    private func prepSessionForCall(_ buddyjid:String) {
        
        do {
            let budjid = XMPPJID(string: buddyjid)!
            try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                let acct = ChatAccountModel.firstAccount()
                if let buddy = ChatBuddyModel.fetchBuddy(jid: budjid, accountUniqueId: acct!.uniqueId, transaction: transaction) {
                
                    let group = DispatchGroup()
                    let prepareCompletion = { (success:Bool) in
                        group.leave()
                    }
                    
                    //prepareSessionForBuddy
                    group.enter()
                    let budVars = self.prepSession(buddy.uniqueId, collection: ChatBuddyModel.collection(), transaction: transaction)
                    self.prepareSession(budVars, completion: prepareCompletion)
                }
            })
        } catch {
            DDLogError("prepSessionForCall error \(error)")
        }
        
        //return buddyId
    }
    
    open func getPayloadForCall(_ fingerprint:String, buddyjid:String, deviceId:String, senderDeviceId:UInt32) -> XMLElement? {
        
        guard let ivData = OTRSignalEncryptionHelper.generateIV(), let keyData = OTRSignalEncryptionHelper.generateSymmetricKey(), let fingerprintData = fingerprint.data(using: String.Encoding.utf8) else {
            return nil
        }
        
        self.prepSessionForCall(buddyjid)
            
        do {
            let gcm = try OTRSignalEncryptionHelper.encryptData(fingerprintData, key: keyData, iv: ivData)
            let gcmData = gcm.data //this then goes to finalPayload and omemo_message to build the xmpp. what's the other payload? that one is omemoKeyData
            let payload = keyData + gcm.authTag
            let rid = UInt32(deviceId)
                        
            let encryptedKeyData = try self.signalEncryptionManager.encryptToAddress(payload, name: buddyjid, deviceId: rid!)
                        
            var isPreKey = false
            if (encryptedKeyData.type == .preKeyMessage) {
                isPreKey = true
            }
            let omemoKeyData = OMEMOKeyData(deviceId: rid!, data: encryptedKeyData.data, isPreKey: isPreKey)
                        
            let encryptedElement = XMLElement.omemo_keyTransport(withKeyData: [omemoKeyData], iv: ivData, senderDeviceId: senderDeviceId, xmlNamespace: .conversationsLegacy)
            let b64 = gcmData.base64EncodedString(options: [])
            let payloadElement = XMLElement(name: "payload", stringValue: b64)
            encryptedElement.addChild(payloadElement)
                        
            return encryptedElement
        } catch let err {
            DDLogError("getPayloadForCall error \(err)")
        }
                
        return nil
    }
    
    open func getDecryptedPayload(_ keyData:[OMEMOKeyData], senderDeviceId:UInt32, iv:Data, payload:Data, addressjid:String) -> String? {
        var decryptedPayload:String?
        let rid = self.signalEncryptionManager.registrationId
        
        //Could have multiple matching device id. This is extremely rare but possible that the sender has another device that collides with our device id.
        var unencryptedKeyData: Data?
        for key in keyData where key.deviceId == rid {
            let keydata = key.data
            do {
                unencryptedKeyData = try self.signalEncryptionManager.decryptFromAddress(keydata, name: addressjid, deviceId: senderDeviceId)
                // have successfully decripted the AES key. We should break and use it to decrypt the payload
                break
            } catch let error {
                
            }
        }
        
        guard var aesKey = unencryptedKeyData else {
            return nil
        }
        var authTag: Data?
        let aesGcmBlockLength = 16
        
        if (aesKey.count >= aesGcmBlockLength * 2) {
            authTag = aesKey.subdata(in: aesGcmBlockLength..<aesKey.count)
            aesKey = aesKey.subdata(in: 0..<aesGcmBlockLength)
        }
        
        var tmpBody: Data?
        // If there's already an auth tag, that means the payload
        // doesn't contain the auth tag.
        if authTag != nil { // omemo namespace
            tmpBody = payload
        } else { // 'siacs' namespace fallback
            
            tmpBody = payload.subdata(in: 0..<payload.count - aesGcmBlockLength)
            authTag = payload.subdata(in: payload.count - aesGcmBlockLength..<payload.count)
        }
        guard let tag = authTag, let encryptedBody = tmpBody else {
            return nil
        }
        
        do {
            if let decrypted = try OTRSignalEncryptionHelper.decryptData(encryptedBody, key: aesKey, iv: iv, authTag: tag) {
                decryptedPayload = String(data: decrypted, encoding: String.Encoding.utf8)
            }
        } catch let error {
            DDLogError("Message decryption error: \(error)")
            return nil
        }
        return decryptedPayload
    }
    
    private func sendOnStream(_ message:XMPPMessage) {
        if let oMod = self.omemoModule {
            oMod.performBlock(async: true, {
                oMod.xmppStream?.send(message)
            })
        }
    }
    
    /**
     Remove a device from the store and from the XMPP server.
     
     - parameter deviceId: The OMEMO device id
     - parameter localOnly: whether to avoid remote update if doing so elsewhere
    */
    //IOSM-338 added localonly to not update server
    open func removeDevice(_ devices:[ChatOmemoDevice], localOnly:Bool, completion:@escaping ((Bool) -> Void)) {
        
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            //Array with tuple of username and the device
            //Needed to avoid nesting transactions
            var usernameDeviceArray = [(String,ChatOmemoDevice)]()
            devices.forEach({ (device) in
                // Get the username if buddy or account.
                if device.parentCollection == ChatAccountModel.collection() {
                    if let acct = ChatAccountModel.getXMPPAccount(uniqueId: device.parentKey, transaction: transaction) {
                        usernameDeviceArray.append((acct.username,device))
                    }
                } else {
                    if let bud = ChatBuddyModel.getBuddy(uniqueId: device.parentKey, transaction: transaction) {
                        usernameDeviceArray.append((bud.username,device))
                    }
                }
                        
                device.grdbRemove(transaction: transaction)
            })
                    
            //For each username device pair remove the underlying signal session
            usernameDeviceArray.forEach({ (username,device) in
                let address = SignalAddress(name: username.lowercased(), deviceId: Int32(device.deviceId))
                _ = self.signalEncryptionManager.storage.deleteSessionRecord(for: address, transaction: transaction)
            })
                    
            let remoteDevicesToRemove = devices.filter({ (device) -> Bool in
                // Can only remove devices that belong to this account from the remote server.
                return device.parentKey == self.accountKey && device.parentCollection == ChatAccountModel.collection()
            })
                    
            if( remoteDevicesToRemove.count > 0 && !localOnly) {
                let elementId = UUID().uuidString
                let deviceIds = remoteDevicesToRemove.map({ (device) -> NSNumber in
                    return NSNumber(value: device.deviceId)
                })
                self.outstandingXMPPStanzaResponseBlocks[elementId] = { success in
                    completion(success)
                }
                self.omemoModule?.removeDeviceIds(deviceIds, elementId: elementId)
            } else {
                completion(true)
            }
        })
    }
    
    /// transforms incoming group message into JID matching a 1:1 Buddy
    private func extractAddressFromGroupMessage(_ message: XMPPMessage) -> XMPPJID? {
        if let fromJID = message.from {
            let roomJID = fromJID.bareJID
            let accountId = accountKey
            var _occupant: ChatRoomOccupantModel? = ChatRoomOccupantModel.occupant(jid: fromJID, realJID: nil, roomJID: roomJID, accountId: accountId, createIfNeeded: false)
            
            // we've found the existing 1:1 buddy!
            if let buddy = _occupant?.buddy() {
                return XMPPJID(string: buddy.username)
            } else {
                if let user = fromJID.resource {
                    if let userjid = handleNoBuddy(message, fromname: user) {
                        return userjid
                    }
                }
                
                if let occupant = _occupant,
                    let user = occupant.jid?.resource {
                    return XMPPJID(string: user)
                }
                
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
    
    open func processKeyData(_ keyData: [OMEMOKeyData], iv: Data, senderDeviceId: UInt32, forJID: XMPPJID, payload: Data?, delayed: Date?, forwarded: Bool, isIncoming: Bool, message: XMPPMessage, originalMessage: XMPPMessage) {
        var incoming = isIncoming
        guard let encryptedPayload = payload, encryptedPayload.count > 0, let myJID = self.myJID else {
            return
        }
        var _addressJID: XMPPJID? = nil
        // handle incoming group chat messages slightly differently
        if message.isGroupChatMessage {
            if let groupAddressJID = extractAddressFromGroupMessage(message) {
                _addressJID = groupAddressJID
                if groupAddressJID.isEqual(to: myJID, options: .bare) {
                    incoming = false
                } else {
                    incoming = true
                }
            } else {
                DDLogWarn("Found Incoming OMEMO group message, but corresponding Buddy could not be found!")
                return
            }
        } else {
            if !incoming {
                _addressJID = myJID.bareJID
                
            } else {
                _addressJID = forJID.bareJID
            }
            
        }
        guard let addressJID = _addressJID else {
            return
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
                DDLogError("processKeyData Error decrypting OMEMO message for \(addressJID): \(error) \(message)")
                let nsError = error as NSError
                if nsError.domain == SignalErrorDomain, nsError.code == SignalError.duplicateMessage.rawValue {
                    // duplicate messages are benign and can be ignored
                    DDLogInfo("Ignoring duplicate OMEMO message: \(message)")
                    return
                }
                let buddyAddress = SignalAddress(name: addressJID.bare, deviceId: Int32(senderDeviceId))
                
                var sessionVars: SessionVars?
                do {
                    try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                        //IOSM-338c added here and removed letEmKnow
                        if (incoming) {
                            //create session does the above if needed...
                        
                            if handleMissingKeys(message: message, forwarded: forwarded, delayed: delayed, transaction:transaction) {
                            
                                let deviceNumber = NSNumber(value: senderDeviceId as UInt32)
                                if let buddy = ChatBuddyModel.fetchBuddy(jid: addressJID, accountUniqueId: self.accountKey, transaction: transaction) {
                                    let key = ChatOmemoDevice.keyWith(deviceId: deviceNumber, parentKey: buddy.uniqueId, parentCollection: ChatBuddyModel.collection())
                                    let _ = self.signalEncryptionManager.storage.deleteSessionRecord(for: buddyAddress, transaction: transaction)
                                    
                                    sessionVars = self.prepSession(buddy.uniqueId, collection: ChatBuddyModel.collection(), transaction: transaction)
                                }
                            }
                        }
                        return
                    })
                } catch {
                    DDLogError("Error in processKeyData")
                }
                
                if let sVars = sessionVars {
                    self.prepareSession(sVars, completion: { (success:Bool) in })
                }
            }
        }
                
        guard unencryptedKeyData != nil else { //IOSM-338c
            if (incoming) {
                var sessionVars: SessionVars?
                do {
                    try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                        if handleMissingKeys(message: message, forwarded: forwarded, delayed: delayed, transaction:transaction) {
                            if let buddy = ChatBuddyModel.fetchBuddy(jid: addressJID, accountUniqueId: self.accountKey, transaction: transaction) {
                                sessionVars = self.prepSession(buddy.uniqueId, collection: ChatBuddyModel.collection(), transaction: transaction)
                            }
                        }
                    })
                } catch {
                    DDLogError("unencryptedKeyData nil error")
                }
                
                if let sVars = sessionVars {
                    self.prepareSession(sVars, completion: { (success:Bool) in })
                }
            }
            return
        }

        handleUnencryptedKeyData (unencryptedKeyData: unencryptedKeyData, iv: iv, senderDeviceId: senderDeviceId, forJID: forJID, encryptedPayload: encryptedPayload, delayed: delayed, forwarded: forwarded, isIncoming: incoming, message: message, originalMessage: originalMessage)
    }
    
    //IOSM-338
    func doGlacierbotGroupAlert(addressJID: XMPPJID, message: XMPPMessage) {
        let lekmessage = ChatRoomMessageModel()
        lekmessage.messageDate = Date()
        
        var lekName = ""
        if let jname  = self.myJID?.user {
            lekName = jname
        }
        
        var roommessage:MessageProtocol? = nil
        if let room = self.roomManager.room(for: addressJID) {
            guard let xroom = ChatRoomModel.fetch(xmppRoom: room) else {
                return
            }
                
            let messageText = "Glacierbot 🤖: We had a problem delivering your last message to " + lekName + ". We've attempted to reset the secure connection. Please try to send your message again and if the problem continues contact Glacier Support."
            roommessage = xroom.outgoingMessage(text: messageText)
            
            if let acctid = xroom.accountUniqueId, let acct = ChatAccountModel.getXMPPAccount(uniqueId: acctid) {
                roommessage?.senderId = acct.uniqueId
                roommessage?.senderDisplayName = acct.displayName
            }
        }
        
        if let xroommsg = roommessage {
            self.encryptAndSendMessage(xroommsg) { (success, nil) in
                if (success == false) {
                    //oh well, we tried
                }
            }
        }
    }
    
    //IOSM-338
    func doGlacierbotAlert(addressJID: XMPPJID) {
        let lekMessage = OutgoingChatMessage()
        var lekName = ""
        if let jname  = self.myJID?.user {
            lekName = jname
        }
        
        var foundbud = false
        if let buddy = ChatBuddyModel.fetchBuddy(jid: addressJID, accountUniqueId: self.accountKey) {
            lekMessage.grdbRecord?.buddyUniqueId = buddy.uniqueId
            lekMessage.grdbRecord?.chatBuddyId = buddy.id!
            
            if let acctid = buddy.accountUniqueId, let acct = ChatAccountModel.getXMPPAccount(uniqueId: acctid) {
                lekMessage.grdbRecord?.msgSenderId = acct.uniqueId
                lekMessage.grdbRecord?.msgSenderDisplayName = acct.displayName
            }
            
            foundbud = true
        }
        
        lekMessage.messageText = "Glacierbot 🤖: We had a problem delivering your last message to " + lekName + ". We've attempted to reset the secure connection. Please try to send your message again and if the problem continues contact Glacier Support."
        
        if (foundbud) {
            self.encryptAndSendMessage(lekMessage) { (success, nil) in
                if (success == false) {
                    OTRProtocolManager.sharedInstance().send(lekMessage)
                }
            }
        }
    }
    
    //IOSM-338 break up function
    func handleUnencryptedKeyData(unencryptedKeyData: Data?, iv: Data, senderDeviceId: UInt32, forJID: XMPPJID, encryptedPayload: Data, delayed: Date?, forwarded: Bool, isIncoming: Bool, message: XMPPMessage, originalMessage: XMPPMessage) {
        let aesGcmBlockLength = 16
        
        guard var aesKey = unencryptedKeyData else {
            return
        }
        var authTag: Data?
        
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
            return
        }
        
        do {
            guard let messageBody = try OTRSignalEncryptionHelper.decryptData(encryptedBody, key: aesKey, iv: iv, authTag: tag),
            var messageString = String(data: messageBody, encoding: String.Encoding.utf8),
            messageString.count > 0 else {
                return
            }
            
            // for sending location
            let messageCopy = String(data: messageBody, encoding: String.Encoding.utf8)
            
            //IOSM-486, IOSM-557 check for links
            let msgurls = messageString.urls
            if msgurls.count > 0, let msgurl = msgurls.first?.absoluteString, !msgurl.hasPrefix("aesgcm"), messageString.count == msgurl.count {
                try self.handleDecryptedMessageWithUrls(msgURLs: msgurls, messageString: messageString, messageCopy: messageCopy!, senderDeviceId: senderDeviceId, forJID: forJID, delayed: delayed, forwarded: forwarded, isIncoming: isIncoming, message: message, originalMessage: originalMessage)
                return
            }
            
            //IOSM-486, IOSM-557 moved handling code to separate method
            try self.handleDecryptedMessage(messageString: messageString, messageCopy: messageCopy!, senderDeviceId: senderDeviceId, forJID: forJID, delayed: delayed, forwarded: forwarded, isIncoming: isIncoming, split: false, message: message, originalMessage: originalMessage)
            
        } catch let error {
            DDLogError("Message decryption error: \(error)")
            return
        }
    }
    
    //IOSM-486, IOSM-557
    func handleDecryptedMessageWithUrls(msgURLs: [URL], messageString: String, messageCopy: String, senderDeviceId: UInt32, forJID: XMPPJID, delayed: Date?, forwarded: Bool, isIncoming: Bool, message: XMPPMessage, originalMessage: XMPPMessage) throws {
        
        //IOSM-579 and use of fixedString, msgurls below
        let fixedString = try self.convertBadLinksText(text: messageString)
        let msgurls = fixedString.urls
        
        if let msgurl = msgurls.first?.absoluteString {
            if (fixedString.hasPrefix(msgurl)) {
                try self.handleDecryptedMessage(messageString: msgurl, messageCopy: msgurl, senderDeviceId: senderDeviceId, forJID: forJID, delayed: delayed, forwarded: forwarded, isIncoming: isIncoming, split: false, message: message, originalMessage: originalMessage)
            
                if let text = fixedString.components(separatedBy: msgurl).last {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if (trimmed.count < 1) {
                        return;
                    }
                    self.workQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        do {
                            try self?.handleDecryptedMessage(messageString: trimmed, messageCopy: trimmed, senderDeviceId: senderDeviceId, forJID: forJID, delayed: delayed, forwarded: forwarded, isIncoming: isIncoming, split: true, message: message, originalMessage: originalMessage)
                        } catch let error {
                            DDLogError("Message decryption error: \(error)")
                        }
                    }
                }
            } else if msgurls.count < 2, let lasturl = msgurls.last?.absoluteString,  fixedString.hasSuffix(lasturl) {
                if let text = fixedString.components(separatedBy: lasturl).first {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if (trimmed.count > 0) {
                        try self.handleDecryptedMessage(messageString: trimmed, messageCopy: trimmed, senderDeviceId: senderDeviceId, forJID: forJID, delayed: delayed, forwarded: forwarded, isIncoming: isIncoming, split: false, message: message, originalMessage: originalMessage)
                    }
                    try self.handleDecryptedMessage(messageString: lasturl, messageCopy: lasturl, senderDeviceId: senderDeviceId, forJID: forJID, delayed: delayed, forwarded: forwarded, isIncoming: isIncoming, split: true, message: message, originalMessage: originalMessage)
                }
            } else {
                try self.handleDecryptedMessage(messageString: fixedString, messageCopy: messageCopy, senderDeviceId: senderDeviceId, forJID: forJID, delayed: delayed, forwarded: forwarded, isIncoming: isIncoming, split: false, message: message, originalMessage: originalMessage)
                for msgurl in msgurls {
                    let htmlurl = msgurl.absoluteString
                    try self.handleDecryptedMessage(messageString: htmlurl, messageCopy: htmlurl, senderDeviceId: senderDeviceId, forJID: forJID, delayed: delayed, forwarded: forwarded, isIncoming: isIncoming, split: true, message: message, originalMessage: originalMessage)
                }
            }
        }
    }
    
    func convertBadLinksText(text: String) throws -> String {
        let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        
        var newText = text
        var badurls = true
        while (badurls) {
            badurls = false
            detector.enumerateMatches(in: newText, options: [], range: NSRange(location: 0, length: newText.utf16.count)) { (result, _, stop) in
                
                if let match = result, match.resultType == .link, let urlstr = match.url?.absoluteString, let range = Range(match.range, in: newText) {
                    
                    //IOSM-596 modified
                    if urlstr.lowercased().hasPrefix("http:
                        badurls = true
                        let newurl = urlstr.replacingCharacters(in: schemerange, with: "https:")
                        newText = newText.replacingCharacters(in: range, with: newurl)
                        stop.pointee = true
                    }
                }
            }
        }
        
        return newText;
    }
    
    //IOSM-486, IOSM-557 moved handling code from above
    func handleDecryptedMessage(messageString: String, messageCopy: String, senderDeviceId: UInt32, forJID: XMPPJID, delayed: Date?, forwarded: Bool, isIncoming: Bool, split: Bool, message: XMPPMessage, originalMessage: XMPPMessage) throws {
        
        let preSave: MessageStorage.PreSave = { message, buddyId, transaction in
            guard let buddyId = buddyId else {
                return
            }

            let deviceNumber = NSNumber(value: senderDeviceId as UInt32)
            let deviceKey = ChatOmemoDevice.keyWith(deviceId: deviceNumber, parentKey: buddyId, parentCollection: ChatBuddyModel.collection())
            message.messageSecurity = .OMEMO
            message.omemoDeviceKey = deviceKey
            
            if let trans = transaction {
                if let cmodel = message as? ChatMessageModel {
                    cmodel.grdbRecord?.grdbSave(transaction: trans)
                } else if let crmodel = message as? ChatRoomMessageModel {
                    crmodel.grdbRecord?.grdbSave(transaction: trans)
                }
                
                do {
                    if var device = try ChatOmemoDevice.filter(Column("uniqueId") == deviceKey).fetchOne(trans.database) {
                        device.lastSeenDate = Date()
                        device.grdbSave(transaction: trans)
                    }
                } catch {
                    DDLogError("OTROMEMOSignalCoordinator.preSave device with error: \(error)")
                }
            } else {
                message.save()
                //Update device last received message
                guard var device = ChatOmemoDevice.omemoDevice(for: buddyId, parentCollection: ChatBuddyModel.collection(), deviceId: deviceNumber) else {
                    return
                }
                device.lastSeenDate = Date()
                device.save()
            }
            
            
            //Update device last received message
        }
        
        if message.isGroupChatMessage {
            //IOSM-371
            var isOutgoingFromOtherDevice = false
            if forwarded, let x = message.element(forName: "x", xmlns: XMPPMUCUserNamespace),
               let item = x.element(forName: "item"),
               let jidString = item.attribute(forName: "jid")?.stringValue,
               let jid = XMPPJID(string: jidString),
               let origto = originalMessage.to {
                    if (origto.bare == jid.bare && origto.resource != jid.resource) {
                    isOutgoingFromOtherDevice = true //and added below
                }
            } else if forwarded, let fromresource = message.from?.resource {
                if let account = ChatAccountModel.getXMPPAccount(uniqueId: self.accountKey), fromresource == account.displayName {
                    isOutgoingFromOtherDevice = true
                }
            }
            
            if let roomJID = message.from?.bareJID,
                let room = self.roomManager.room(for: roomJID) {
                self.roomManager.roomStorage.insertIncoming(message, body: messageString, original: messageCopy, delayed: delayed, into: room, split: split, isOutgoingFromOtherDevice: isOutgoingFromOtherDevice, transaction: nil, preSave: preSave)
            }
        } else {
            if forwarded {
                var isOutgoingFromOtherDevice = false
                let msgString = messageString
                if let origto = originalMessage.to, let forwardedfrom = message.from {
                    if (origto.bare == forwardedfrom.bare && origto.resource != forwardedfrom.resource) {
                        isOutgoingFromOtherDevice = true
                    }
                }
                
                self.messageStorage.handleForwardedMessage(message, forJID: forJID, body: msgString, original: messageCopy, accountId: self.accountKey, delayed: delayed, isIncoming: isIncoming, isOutgoingFromOtherDevice: isOutgoingFromOtherDevice, split: split, preSave: preSave)
            } else {
                self.messageStorage.handleDirectMessage(message, body: messageString, original: messageCopy, accountId: self.accountKey, split: split, preSave: preSave)
            }
        }
    }
    
    private var publishingMyDevice:Bool = false
    private var missingKeysSet = Set<String>()
    // added delayed
    func handleMissingKeys(message: XMPPMessage, forwarded: Bool, delayed: Date?, transaction:GRDBWriteTransaction) -> Bool {
        // 1 - store unencrypted notice of failed message
        // 2 - call for key exchange
        let messageTest = message.body
        if let messageString = message.body,
            messageString.count > 0,
           messageString.contains("encrypted message") || messageString.contains ("Message cannot be decrypted") {
            
            //this is a self-sent message, not sure why its getting here
            //    return
            
            if message.isGroupChatMessage {
                if let roomJID = message.from?.bareJID,
                    let room = self.roomManager.room(for: roomJID) {
                    
                    guard let myRoomJID = room.myRoomJID,
                        let messageJID = message.from else {
                            return false
                    }
                    if myRoomJID.isEqual(to: messageJID),
                        !message.wasDelayed {
                        return false
                    }
                    
                    // this can be delayed/stamped from me if it was a share.
                    //Will it cause big problems to ignore anything from my roomjid?
                    if myRoomJID.isEqual(to: messageJID) {
                        return false
                    }
                    
                    let missingFrom = roomJID.bare
                    if (!missingKeysSet.contains(missingFrom)) {
                        // check if appDelegate ready to handle undecryptable
                        if (self.isBeforeMyTime(message: message, delayed: delayed, transaction: transaction)) {
                            return false
                        }
                        
                        
                        //put this on a timer. if just published, don't immediately do it again
                        //in case we opened and logged in to multiple messages we cant decrypt
                        self.missingKeysSet.insert(missingFrom)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
                            self.missingKeysSet.removeAll()
                            self.publishingMyDevice = false
                        }
                        if self.roomManager.roomStorage.handleFailedIncomingMessage(message, room: room, transaction: transaction), let myid = self.myJID, !self.publishingMyDevice {
                            self.publishingMyDevice = true
                            let devices = self.fetchDeviceIds(for: myid)
                            self.omemoModule?.publishDeviceIds(devices, elementId: nil)
                            
                            return true
                        }
                        
                    }
                }
            } else {
                if forwarded {
                    if let from = message.from?.bareJID.bare, let test = self.myJID?.bare, from == test {
                        //this might be due to MAM...
                        return false
                    }
                 } 
                
                if let missingFrom = message.fromStr,
                    !missingKeysSet.contains(missingFrom) {
                    
                    // check if appDelegate ready to handle undecryptable
                    if (self.isBeforeMyTime(message: message, delayed: delayed, transaction: transaction)) {
                        return false
                    }
                    
                    
                    //put this on a timer. if just published, don't immediately do it again
                    //in case we opened and logged in to multiple messages we cant decrypt
                    self.missingKeysSet.insert(missingFrom)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
                        self.missingKeysSet.removeAll()
                        self.publishingMyDevice = false
                    }
                    if self.messageStorage.handleFailedIncomingMessage(message, body: "Message cannot be decrypted", original: nil, accountId: self.accountKey), let myid = self.myJID, !self.publishingMyDevice {
                        
                        self.publishingMyDevice = true
                        let devices = self.fetchDeviceIds(for: myid)
                        self.omemoModule?.publishDeviceIds(devices, elementId: nil)
                        
                        return true
                    }
                }
            }
        }
        return false
    }
    
    func isBeforeMyTime(message: XMPPMessage, delayed: Date?, transaction: GRDBWriteTransaction) -> Bool {
        
        var msgtime = Date.distantFuture
        if let delayedtime = delayed {
            msgtime = delayedtime
        } else if let delaydate = message.delayedDeliveryDate {
            msgtime = delaydate
        } else {
            return false
        }
        
        var acctTime = Date.distantPast
        
        if let account = ChatAccountModel.getXMPPAccount(uniqueId: self.accountKey, transaction:transaction) {
            if let loginDate = account.loginDate {
                acctTime = loginDate
            } else {
                let cur = Date()
                account.loginDate = cur
                acctTime = cur
                account.grdbRecord?.grdbSave(transaction: transaction)
            }
        }
        
        if (acctTime > msgtime) {
            return true
        }

        return false
    }
}

// MARK: - OMEMOModuleDelegate
extension OTROMEMOSignalCoordinator: OMEMOModuleDelegate {
    
    public func omemo(_ omemo: OMEMOModule, publishedDeviceIds deviceIds: [NSNumber], responseIq: XMPPIQ, outgoingIq: XMPPIQ) {

    }
    
    public func omemo(_ omemo: OMEMOModule, failedToPublishDeviceIds deviceIds: [NSNumber], errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        DDLogWarn("failedToPublishDeviceIds: \(String(describing: errorIq))")
    }
    
    public func omemo(_ omemo: OMEMOModule, deviceListUpdate deviceIds: [NSNumber], from fromJID: XMPPJID, incomingElement: XMPPElement) {
        self.workQueue.async { [weak self] in
            if let eid = incomingElement.elementID {
                self?.callAndRemoveOutstandingBundleBlock(eid, success: true)
            }
        }
    }
    
    public func omemo(_ omemo: OMEMOModule, failedToFetchDeviceIdsFor fromJID: XMPPJID, errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        DDLogWarn("failedToFetchDeviceIdsFor \(fromJID)")
        self.workQueue.async { [weak self] in
            self?.callAndRemoveOutstandingDeviceIdFetch(fromJID, success: false)
            if let eid = outgoingIq.elementID {
                self?.callAndRemoveOutstandingBundleBlock(eid, success: false)
            }
        }
    }
    
    public func omemo(_ omemo: OMEMOModule, publishedBundle bundle: OMEMOBundle, responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
    }
    
    public func omemo(_ omemo: OMEMOModule, failedToPublishBundle bundle: OMEMOBundle, errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        DDLogWarn("failedToPublishBundle: \(String(describing: errorIq)) \(outgoingIq)")
    }
    
    public func omemo(_ omemo: OMEMOModule, fetchedBundle bundle: OMEMOBundle, from fromJID: XMPPJID, responseIq: XMPPIQ, outgoingIq: XMPPIQ) {

        if (self.isOurJID(fromJID) && bundle.deviceId == self.signalEncryptionManager.registrationId) {

            //We fetched our own bundle
            if let ourDatabaseBundle = self.fetchMyBundle() {
                //This bundle doesn't have the correct identity key. Something has gone wrong and we should republish
                if ourDatabaseBundle.identityKey != bundle.identityKey {
                    omemo.publishBundle(ourDatabaseBundle, elementId: nil)
                }
            }
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
        
        self.workQueue.async { [weak self] in
            let elementId = outgoingIq.elementID
            self?.callAndRemoveOutstandingBundleBlock(elementId!, success: false)
        }
    }
    
    public func omemo(_ omemo: OMEMOModule, removedBundleId bundleId: UInt32, responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
        
    }
    
    public func omemo(_ omemo: OMEMOModule, failedToRemoveBundleId bundleId: UInt32, errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        DDLogWarn("Error removing bundle: \(String(describing: errorIq))")
    }
    
    public func omemo(_ omemo: OMEMOModule, failedToRemoveDeviceIds deviceIds: [NSNumber], errorIq: XMPPIQ?, elementId: String?) {
        self.workQueue.async { [weak self] in
            if let eid = elementId {
                self?.callAndRemoveOutstandingBundleBlock(eid, success: false)
            }
        }
    }
    
    public func omemo(_ omemo: OMEMOModule, receivedKeyData keyData: [OMEMOKeyData], iv: Data, senderDeviceId: UInt32, from fromJID: XMPPJID, payload: Data?, message: XMPPMessage) {
        self.processKeyData(keyData, iv: iv, senderDeviceId: senderDeviceId, forJID: fromJID, payload: payload, delayed: nil, forwarded: false, isIncoming: true, message: message, originalMessage: message)
    }
    
    public func omemo(_ omemo: OMEMOModule, receivedForwardedKeyData keyData: [OMEMOKeyData], iv: Data, senderDeviceId: UInt32, for forJID: XMPPJID, payload: Data?, isIncoming: Bool, delayed: Date?, forwardedMessage: XMPPMessage, originalMessage: XMPPMessage) {
        self.processKeyData(keyData, iv: iv, senderDeviceId: senderDeviceId, forJID: forJID, payload: payload, delayed: delayed, forwarded: true, isIncoming: isIncoming, message: forwardedMessage, originalMessage: originalMessage) 
    }
}

// MARK: - OMEMOStorageDelegate
extension OTROMEMOSignalCoordinator:OMEMOStorageDelegate {
    
    public func configure(withParent aParent: OMEMOModule, queue: DispatchQueue) -> Bool {
        self.omemoModule = aParent
        self.omemoModuleQueue = queue
        return true
    }
    
    public func storeDeviceIds(_ deviceIds: [NSNumber], for jid: XMPPJID) {
        
        let isOurDeviceList = self.isOurJID(jid)
        
        if (isOurDeviceList) {
            self.omemoStorageManager.storeOurDevices(deviceIds)
            self.workQueue.async { [weak self] in
                self?.requestBundlesForOurDevicesIfNeeded(deviceIds: deviceIds, jid: jid)
            }
        } else {
            self.omemoStorageManager.storeBuddyDevices(deviceIds, buddyUsername: jid.bare, completion: {() -> Void in

                //Devices updated for buddy
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: OTROMEMOSignalCoordinator.DeviceListUpdateNotificationName, object: self, userInfo: ["jid":jid])
                }
            })
        }
        callAndRemoveOutstandingDeviceIdFetch(jid, success: true)
    }
    
    public func fetchDeviceIds(for jid: XMPPJID) -> [NSNumber] {
        var devices:[ChatOmemoDevice]?
        if self.isOurJID(jid) {
            devices = self.omemoStorageManager.getDevicesForOurAccount(trustedOnly: false)
        } else {
            devices = self.omemoStorageManager.getDevicesForBuddy(jid.bare, trustedOnly:false)
        }
        
        return (devices?.map({ (device) -> NSNumber in
            return NSNumber(value:device.deviceId)
        })) ?? [NSNumber]()
        
    }
    
    public func fetchDeviceIds(for jid: XMPPJID, transaction: GRDBReadTransaction) -> [NSNumber] {
        var devices:[ChatOmemoDevice]?
        if self.isOurJID(jid) {
            devices = self.omemoStorageManager.getDevicesForOurAccount(trustedOnly: false, transaction: transaction)
        } else {
            devices = self.omemoStorageManager.getDevicesForBuddy(jid.bare, trustedOnly:false, transaction: transaction)
        }
        
        return (devices?.map({ (device) -> NSNumber in
            return NSNumber(value:device.deviceId)
        })) ?? [NSNumber]()
        
    }

    //Always returns most complete bundle with correct count of prekeys
    public func fetchMyBundle() -> OMEMOBundle? {
        var bundle: OMEMOBundle? = nil
        do {
            try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                bundle = self.fetchMyBundle(transaction)
            })
        } catch {
            DDLogError("fetchMyBundle error \(error)")
        }
        
        return bundle
    }
    
    //Always returns most complete bundle with correct count of prekeys
    public func fetchMyBundle(_ transaction:GRDBWriteTransaction) -> OMEMOBundle? {
        var _bundle: OMEMOBundle? = nil
        do {
            _bundle = try signalEncryptionManager.storage.fetchOurExistingBundle(transaction)
            
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
            DDLogError("Error fetching bundle! \(error)")
        }
        let maxTries = 50
        var tries = 0
        if _bundle == nil {
            ChatPreKey.resetPreKeys(for: self.accountKey, transaction: transaction)
            semaphore.wait()
            while _bundle == nil && tries < maxTries {
                tries = tries + 1
                do {
                    _bundle = try self.signalEncryptionManager.generateOutgoingBundle(self.preKeyCount, transaction: transaction)
                } catch let error {
                    DDLogError("Error generating bundle! Try #\(tries)/\(maxTries) \(error)")
                }
            }
            semaphore.signal()
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
            if let maxId = self.signalEncryptionManager.storage.currentMaxPreKeyId(transaction) {
                start = UInt(maxId) + 1
            }
            
            if let newPreKeys = self.signalEncryptionManager.generatePreKeys(start, count: UInt(keysToGenerate), transaction: transaction) {
                let omemoKeys = OMEMOPreKey.preKeysFromSignal(newPreKeys)
                preKeys.append(contentsOf: omemoKeys)
            }
        }
        
        let newBundle = bundle.copyBundle(newPreKeys: preKeys)
        return newBundle
    }

    public func isSessionValid(_ jid: XMPPJID, deviceId: UInt32) -> Bool {
        return self.signalEncryptionManager.sessionRecordExistsForUsername(jid.bare, deviceId: Int32(deviceId))
    }
}
