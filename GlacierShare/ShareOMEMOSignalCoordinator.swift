//  GlacierShare
//  Created by Andy Friedman on 12/21/20.
//  Copyright © 2020 Glacier. All rights reserved.

import UIKit
import XMPPFramework
import CocoaLumberjack
import SignalProtocolObjC

/**
 * This is the glue between XMPP/OMEMO and Signal
 */
@objc open class ShareOMEMOSignalCoordinator: NSObject {
    
    public let signalEncryptionManager:OTRAccountSignalEncryptionManager
    public let omemoStorageManager:OTROMEMOStorageManager
    @objc public let accountKey:String
    @objc open weak var omemoModule:OMEMOModule?
    @objc open weak var omemoModuleQueue:DispatchQueue?
    @objc open var callbackQueue:DispatchQueue
    @objc public let workQueue:DispatchQueue
    

    fileprivate var myJID:XMPPJID? {
        get {
            return omemoModule?.xmppStream?.myJID
        }
    }
    let preKeyCount:UInt = 100
    fileprivate var outstandingXMPPStanzaResponseBlocks:[String: (Bool) -> Void]
    /// callbacks for when fetching device Id list
    private var deviceIdFetchCallbacks:[XMPPJID: (Bool) -> Void] = [:]
    
    /**
     Create a NotificationOMEMOSignalCoordinator for an account.
     
     - parameter accountKey: The accounts unique yap key
 `  */
    @objc public required init(accountKey:String) throws {
        try self.signalEncryptionManager = OTRAccountSignalEncryptionManager(accountKey: accountKey)
        self.omemoStorageManager = OTROMEMOStorageManager(accountKey: accountKey, accountCollection: "OTRAccount")
        self.accountKey = accountKey
        self.outstandingXMPPStanzaResponseBlocks = [:]
        self.callbackQueue = DispatchQueue(label: "ShareOMEMOSignalCoordinator-callback", attributes: [])
        self.workQueue = DispatchQueue(label: "ShareOMEMOSignalCoordinator-work", attributes: [])

    }
    
    /**
     Gathers necessary information to encrypt a message to the buddy and all this accounts devices that are trusted. Then sends the payload via OMEMOModule
     
     - parameter messageBody: The boddy of the message
     - parameter buddyYapKey: The unique buddy yap key. Used for looking up the username and devices
     - parameter messageId: The preffered XMPP element Id to be used.
     - parameter completion: The completion block is called after all the necessary omemo preperation has completed and sendKeyData:iv:toJID:payload:elementId:expiration is invoked
     */
                let buddyKeyDataArray = buddyKeys.flatMap({ key in
                    self.omemoStorageManager.getDevicesForParentKey(key, collection: ChatBuddyModel.collection(), trustedOnly: true).map(encryptClosure).compactMap{ $0 }
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
                let ourDevicesKeyData = self.omemoStorageManager.getDevicesForOurAccount(trustedOnly: true).filter({ (device) -> Bool in
                    return device.deviceId.uint32Value != self.signalEncryptionManager.registrationId
                }).map(encryptClosure).compactMap{ $0 }
                
                // Combine teh two arrays for all key data
                let keyDataArray = ourDevicesKeyData + buddyKeyDataArray
                
                //Make sure we have encrypted the symetric key to someone
                if (keyDataArray.count > 0) {
                    // new OMEMO format puts auth tag inside omemo session
                    let finalPayload = gcmData.data
                    
                    if message is OTRXMPPRoomMessage,
                        let groupMessage = self.omemoModule?.message(forKeyData: keyDataArray, iv: ivData, to: destinationJID, payload: finalPayload, elementId: message.remoteMessageId)
                        {
                        groupMessage.addAttribute(withName: "type", stringValue: "groupchat")
                        groupMessage.addReceiptRequest()
                        groupMessage.addBody("Message cannot be decrypted.") //IOSM-605
                        self.omemoModule?.xmppStream?.send(groupMessage)
                    } else if message is OTROutgoingMessage {
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
            } catch let err {
                //This should only happen if we had an error encrypting the payload
                self.callbackQueue.async(execute: {
                    completion(false,err)
                })
                return
            }
            
        }
    }*/
    
    /**
     This must be called before sending every message. It ensures that for every device there is a session and if not the bundles are fetched.
     
     - parameter buddyYapKey: The yap key for the buddy to check
     - parameter completion: The completion closure called on callbackQueue. If it successfully was able to fetch all the bundles or if it wasn't necessary. If there were no devices for this buddy it will also return flase
     */
    open func prepareSessionForBuddy(_ buddyYapKey:String, completion:@escaping (Bool) -> Void) {
    }
    
    /**
     This must be called before sending every message. It ensures that for every device there is a session and if not the bundles are fetched.
     
     - parameter yapKey: The yap key for the buddy or account to check
     - parameter yapCollection: The yap key for the buddy or account to check
     - parameter completion: The completion closure called on callbackQueue. If it successfully was able to fetch all the bundles or if it wasn't necessary. If there were no devices for this buddy it will also return flase
     */
    open func prepareSession(_ yapKey:String, yapCollection:String, completion:@escaping (Bool) -> Void) {
        self.callbackQueue.async(execute: {
            completion(false)
        })
        return
        
    }
    
    fileprivate func fetchUsername(_ yapKey:String, yapCollection:String) -> String? {

        return nil
    }
    
    /**
     Check if we have valid sessions with our other devices and if not fetch their bundles and start sessions.
     */
    func prepareSessionWithOurDevices(_ completion:@escaping (_ success:Bool) -> Void) {
    }
    
    
            return message
        } else if let room = thread as? OTRXMPPRoom {
            if let message = room.outgoingOMEMOMessage(withText: "") as? OTRXMPPRoomMessage {
                message.messageText = nil
                message.messageSecurityInfo = OTRMessageEncryptionInfo(messageSecurity: .OMEMO)
                message.mediaItemId = mediaItem.uniqueId
                return message
            }
        }
        return nil
    }*/
    
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
    
    
    /// transforms incoming group message into JID matching a 1:1 Buddy
    private func extractAddressFromGroupMessage(_ message: XMPPMessage) -> XMPPJID? {
        return nil
    }
    
    func handleNoBuddy(_ message: XMPPMessage, fromname: String) -> XMPPJID? {
        var budjid: XMPPJID? = nil
        
        return budjid
    }
}

// MARK: - OMEMOModuleDelegate
extension ShareOMEMOSignalCoordinator: OMEMOModuleDelegate {
    
    public func omemo(_ omemo: OMEMOModule, publishedDeviceIds deviceIds: [NSNumber], responseIq: XMPPIQ, outgoingIq: XMPPIQ) {

    }
    
    public func omemo(_ omemo: OMEMOModule, failedToPublishDeviceIds deviceIds: [NSNumber], errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
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
    }
    
    public func omemo(_ omemo: OMEMOModule, failedToRemoveDeviceIds deviceIds: [NSNumber], errorIq: XMPPIQ?, elementId: String?) {
        self.workQueue.async { [weak self] in
            if let eid = elementId {
                self?.callAndRemoveOutstandingBundleBlock(eid, success: false)
            }
        }
    }
    
    public func omemo(_ omemo: OMEMOModule, receivedKeyData keyData: [OMEMOKeyData], iv: Data, senderDeviceId: UInt32, from fromJID: XMPPJID, payload: Data?, message: XMPPMessage) {
    }
    
    public func omemo(_ omemo: OMEMOModule, receivedForwardedKeyData keyData: [OMEMOKeyData], iv: Data, senderDeviceId: UInt32, for forJID: XMPPJID, payload: Data?, isIncoming: Bool, delayed: Date?, forwardedMessage: XMPPMessage, originalMessage: XMPPMessage) {
    }
}


// MARK: - OMEMOStorageDelegate
extension ShareOMEMOSignalCoordinator:OMEMOStorageDelegate {
    
    public func configure(withParent aParent: OMEMOModule, queue: DispatchQueue) -> Bool {
        self.omemoModule = aParent
        self.omemoModuleQueue = queue
        return true
    }
    
    public func storeDeviceIds(_ deviceIds: [NSNumber], for jid: XMPPJID) {
        callAndRemoveOutstandingDeviceIdFetch(jid, success: true)
    }
    
    public func fetchDeviceIds(for jid: XMPPJID) -> [NSNumber] {
        return [NSNumber]()
        
    }

    //Always returns most complete bundle with correct count of prekeys
    public func fetchMyBundle() -> OMEMOBundle? {
        var _bundle: OMEMOBundle? = nil
        
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
        return newBundle
    }

    public func isSessionValid(_ jid: XMPPJID, deviceId: UInt32) -> Bool {
        return self.signalEncryptionManager.sessionRecordExistsForUsername(jid.bare, deviceId: Int32(deviceId))
    }
}
