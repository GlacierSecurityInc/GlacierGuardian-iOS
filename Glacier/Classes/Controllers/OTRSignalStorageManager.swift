//
//  OTRSignalStorageManager.swift
//  ChatSecure
//
//  Created by David Chiles on 7/21/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

import UIKit
import SignalProtocolObjC
import XMPPFramework

extension OMEMOPreKey {
    static func preKeysFromSignal(_ preKeys: [SignalPreKey]) -> [OMEMOPreKey] {
        var omemoPreKeys: [OMEMOPreKey] = []
        preKeys.forEach { (signalPreKey) in
            guard let pk = signalPreKey.keyPair?.publicKey else { return }
            let omemoPreKey = OMEMOPreKey(preKeyId: signalPreKey.preKeyId, publicKey: pk)
            omemoPreKeys.append(omemoPreKey)
        }
        return omemoPreKeys
    }
}

extension OMEMOSignedPreKey {
    convenience init(signedPreKey: ChatSignedPreKey) throws {
        let signalSignedPreKey = try SignalSignedPreKey(serializedData: signedPreKey.keyData)
        guard let pk = signalSignedPreKey.keyPair?.publicKey else {
            throw OMEMOBundleError.invalid
        }
        self.init(preKeyId: signedPreKey.keyId, publicKey: pk, signature: signalSignedPreKey.signature)
        
    }
    convenience init(signedPreKey: SignalSignedPreKey) throws {
        guard let publicKey = signedPreKey.keyPair?.publicKey else {
            throw OMEMOBundleError.invalid
        }
        self.init(preKeyId: signedPreKey.preKeyId, publicKey: publicKey, signature: signedPreKey.signature)
    }
}

extension OMEMOBundle {
    
    /// Returns copy of bundle with new preKeys
    func copyBundle(newPreKeys: [OMEMOPreKey]) -> OMEMOBundle {
        let bundle = OMEMOBundle(deviceId: deviceId, identityKey: identityKey, signedPreKey: signedPreKey, preKeys: newPreKeys)
        return bundle
    }
    
    /// Returns Signal bundle from a random PreKey
    func signalBundle() throws -> SignalPreKeyBundle {
        let index = Int(arc4random_uniform(UInt32(preKeys.count)))
        let preKey = preKeys[index]
        let preKeyBundle = try SignalPreKeyBundle(registrationId: 0, deviceId: deviceId, preKeyId: preKey.preKeyId, preKeyPublic: preKey.publicKey, signedPreKeyId: signedPreKey.preKeyId, signedPreKeyPublic: signedPreKey.publicKey, signature: signedPreKey.signature, identityKey: identityKey)
        return preKeyBundle
    }
    
    convenience init(deviceId: UInt32, identity: SignalIdentityKeyPair, signedPreKey: SignalSignedPreKey, preKeys: [SignalPreKey]) throws {

        let omemoSignedPreKey = try OMEMOSignedPreKey(signedPreKey: signedPreKey)
        let omemoPreKeys = OMEMOPreKey.preKeysFromSignal(preKeys)
        
        // Double check that this bundle is valid
        if let preKey = preKeys.first,
            let preKeyPublic = preKey.keyPair?.publicKey {
            let _ = try SignalPreKeyBundle(registrationId: 0, deviceId: deviceId, preKeyId: preKey.preKeyId, preKeyPublic: preKeyPublic, signedPreKeyId: omemoSignedPreKey.preKeyId, signedPreKeyPublic: omemoSignedPreKey.publicKey, signature: omemoSignedPreKey.signature, identityKey: identity.publicKey)
        } else {
            throw OMEMOBundleError.invalid
        }
        
        self.init(deviceId: deviceId, identityKey: identity.publicKey, signedPreKey: omemoSignedPreKey, preKeys: omemoPreKeys)
    }
    
    convenience init(identity: ChatAccountSignalIdentity, signedPreKey: ChatSignedPreKey, preKeys: [ChatPreKey]) throws {
        let omemoSignedPreKey = try OMEMOSignedPreKey(signedPreKey: signedPreKey)
        
        var omemoPreKeys: [OMEMOPreKey] = []
        preKeys.forEach { (preKey) in
            guard let keyData = preKey.keyData, keyData.count > 0 else { return }
            do {
                let signalPreKey = try SignalPreKey(serializedData: keyData)
                guard let pk = signalPreKey.keyPair?.publicKey else { return }
                let omemoPreKey = OMEMOPreKey(preKeyId: preKey.keyId, publicKey: pk)
                omemoPreKeys.append(omemoPreKey)
            } catch let error {
                DDLogError("Found invalid prekey: \(error)")
            }
        }
        
        // Double check that this bundle is valid
        if let preKey = preKeys.first, let preKeyData = preKey.keyData,
            let signalPreKey = try? SignalPreKey(serializedData: preKeyData),
            let preKeyPublic = signalPreKey.keyPair?.publicKey {
            let _ = try SignalPreKeyBundle(registrationId: 0, deviceId: identity.registrationId, preKeyId: preKey.keyId, preKeyPublic: preKeyPublic, signedPreKeyId: omemoSignedPreKey.preKeyId, signedPreKeyPublic: omemoSignedPreKey.publicKey, signature: omemoSignedPreKey.signature, identityKey: identity.publicKey)
        } else {
            throw OMEMOBundleError.invalid
        }
        
        self.init(deviceId: identity.registrationId, identityKey: identity.publicKey, signedPreKey: omemoSignedPreKey, preKeys: omemoPreKeys)
    }
}

public protocol OTRSignalStorageManagerDelegate: AnyObject {
    /** Generate a new account key*/
    func generateNewIdenityKeyPairForAccountKey(_ accountKey:String) -> ChatAccountSignalIdentity
}

/**
 * This class implements the SignalStore protocol. One OTRSignalStorageManager should be created per account key/collection.
 */
open class OTRSignalStorageManager: NSObject {
    public let accountKey:String
    open weak var delegate:OTRSignalStorageManagerDelegate?
    
    /**
     Create a Signal Store Manager for each account.
     
     - parameter accountKey: The key for the parent account.
     - parameter delegate: An object that handles OTRSignalStorageManagerDelegate
     */
    public init(accountKey:String, delegate:OTRSignalStorageManagerDelegate?) {
        self.accountKey = accountKey
        self.delegate = delegate
    }
    
    /** 
     Convenience function to create a new ChatAccountSignalIdentity and save it
     
     - returns: an ChatAccountSignalIdentity that is already saved to the database
     */
    fileprivate func generateNewIdenityKeyPair() -> ChatAccountSignalIdentity {
        // Might be a better way to guarantee we have an ChatAccountSignalIdentity
        let identityKeyPair = (self.delegate?.generateNewIdenityKeyPairForAccountKey(self.accountKey))!
#if !TARGET_IS_EXTENSION
        //need a sync save
        do {
            try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                identityKeyPair.grdbSave(transaction: transaction)
            })
        } catch {
            identityKeyPair.save()
        }
#endif
        
        return identityKeyPair
    }
    
    /**
     Convenience function to create a new ChatAccountSignalIdentity and save it
     
     - returns: an ChatAccountSignalIdentity that is already saved to the database
     */
    fileprivate func generateNewIdenityKeyPair(_ transaction:GRDBWriteTransaction) -> ChatAccountSignalIdentity {
        // Might be a better way to guarantee we have an ChatAccountSignalIdentity
        let identityKeyPair = (self.delegate?.generateNewIdenityKeyPairForAccountKey(self.accountKey))!
#if !TARGET_IS_EXTENSION
        //need a sync save
        do {
            identityKeyPair.grdbSave(transaction: transaction)
        } catch {
            identityKeyPair.save()
        }
#endif
        
        return identityKeyPair
    }
    
    //MARK: Database Utilities
    
    /**
     Fetches the ChatAccountSignalIdentity for the account key from this class.
     
     returns: An ChatAccountSignalIdentity or nil if none was created and stored.
     */
    fileprivate func accountSignalIdentity() -> ChatAccountSignalIdentity? {
        return ChatAccountSignalIdentity.accountSignalIdKey(for: self.accountKey)
    }
    
    fileprivate func accountSignalIdentity(_ transaction:GRDBReadTransaction) -> ChatAccountSignalIdentity? {
        return ChatAccountSignalIdentity.accountSignalIdKey(for: self.accountKey, transaction: transaction)
    }
    
    fileprivate func storePreKeyPrivate(_ preKey: Data, preKeyId: UInt32) -> Bool {
        let preKeyDatabaseObject = ChatPreKey(accountKey: self.accountKey, keyId: preKeyId, keyData: preKey) //else { return false }
        preKeyDatabaseObject.save()  //(with: transaction)
        return true
    }
    
    fileprivate func storePreKeyPrivate(_ preKey: Data, preKeyId: UInt32, transaction:GRDBWriteTransaction) -> Bool {
        let preKeyDatabaseObject = ChatPreKey(accountKey: self.accountKey, keyId: preKeyId, keyData: preKey) //else { return false }
        preKeyDatabaseObject.grdbSave(transaction: transaction)
        return true
    }
    
    /** 
     Save a bunch of pre keys in one database transaction
     
     - parameters preKeys: The array of pre-keys to be stored
     
     - return: Whether the storage was successufl
     */
    open func storeSignalPreKeys(_ preKeys:[SignalPreKey]) -> Bool {
        
        if preKeys.count == 0 {
            return true
        }
        
        var success = false
#if !TARGET_IS_EXTENSION
        for pKey in preKeys {
            if let data = pKey.serializedData() {
                success = self.storePreKeyPrivate(data, preKeyId: pKey.preKeyId)
            } else {
                success = false
            }
                
            if !success {
                break
            }
        }
#endif
        return success
    }
    
    open func storeSignalPreKeys(_ preKeys:[SignalPreKey], transaction:GRDBWriteTransaction) -> Bool {
        
        if preKeys.count == 0 {
            return true
        }
        
        var success = false
#if !TARGET_IS_EXTENSION
        for pKey in preKeys {
            if let data = pKey.serializedData() {
                success = self.storePreKeyPrivate(data, preKeyId: pKey.preKeyId, transaction: transaction)
            } else {
                success = false
            }
                
            if !success {
                break
            }
        }
#endif
        return success
    }
    
    /**
     Returns the current max pre-key id for this account. This includes both deleted and existing pre-keys.
     
     returns: The current max in the database. If there are no pre-keys then returns none.
    */
    internal func currentMaxPreKeyId() ->  UInt32? {
        return ChatPreKey.maxPreKeyId(for: self.accountKey)
    }
    
    internal func currentMaxPreKeyId(_ transaction: GRDBReadTransaction) ->  UInt32? {
        return ChatPreKey.maxPreKeyId(for: self.accountKey, transaction: transaction)
    }
    
    /**
     Fetch all pre-keys for this class's account. This can include deleted pre-keys which are SignalPreKey witout any keyData.
     
     - parameter includeDeleted: If deleted pre-keys are included in the result
     
     - return: An array of SignalPreKey(s). If ther eare no pre-keys then the array will be empty.
     */
    internal func fetchAllPreKeys(_ includeDeleted:Bool) -> [ChatPreKey] {
        return ChatPreKey.allLiveSignalPreKeys(for: self.accountKey, includeDeleted: includeDeleted)
    }
    
    /**
     This fetches the associated account's bundle. If any piece of the bundle is missing it returns nil.
     
     - return: A complete outgoing bundle.
     */
    open func fetchOurExistingBundle() throws -> OMEMOBundle {
        var mybundle:OMEMOBundle?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let _signedPreKey: ChatSignedPreKey? = ChatSignedPreKey.signalSignedPreKey(for: self.accountKey, transaction: transaction)
                let _identity: ChatAccountSignalIdentity? = ChatAccountSignalIdentity.accountSignalIdKey(for: self.accountKey, transaction: transaction)
                
                guard let signedPreKey = _signedPreKey,
                      let identity = _identity else  {
                    throw OMEMOBundleError.notFound
                }
                
                //Gather pieces of outgoing bundle
                let preKeys = ChatPreKey.allLiveSignalPreKeys(for: self.accountKey, includeDeleted: false, transaction: transaction)
            
        
                /*var omemoKeys:[OMEMOPreKey] = []
                 for pkey in preKeys {
                 let okey = OMEMOPreKey(preKeyId: pkey.keyId, publicKey: pkey.keyData ?? Data())
                 omemoKeys.append(okey)
                 }*/
        
                mybundle = try OMEMOBundle(identity: identity, signedPreKey: signedPreKey, preKeys: preKeys)

                //return bundle
            })
        } catch {
            print("***** fetchOurExistingBundle - Error getting our existing bundle")
        }
        
        guard let bundle = mybundle else {
            throw OMEMOBundleError.notFound
        }
        
        return bundle
    }
    
    /**
     This fetches the associated account's bundle. If any piece of the bundle is missing it returns nil.
     
     - return: A complete outgoing bundle.
     */
    open func fetchOurExistingBundle(_ transaction:GRDBReadTransaction) throws -> OMEMOBundle {
        let _signedPreKey: ChatSignedPreKey? = ChatSignedPreKey.signalSignedPreKey(for: self.accountKey, transaction:transaction)
        let _identity: ChatAccountSignalIdentity? = ChatAccountSignalIdentity.accountSignalIdKey(for: self.accountKey, transaction:transaction)

        guard let signedPreKey = _signedPreKey,
            let identity = _identity else  {
            throw OMEMOBundleError.notFound
        }
        
        //Gather pieces of outgoing bundle
        let preKeys = ChatPreKey.allLiveSignalPreKeys(for: self.accountKey, includeDeleted: false, transaction: transaction)
        
        /*var omemoKeys:[OMEMOPreKey] = []
        for pkey in preKeys {
            let okey = OMEMOPreKey(preKeyId: pkey.keyId, publicKey: pkey.keyData ?? Data())
            omemoKeys.append(okey)
        }*/
        
        let bundle = try OMEMOBundle(identity: identity, signedPreKey: signedPreKey, preKeys: preKeys)

        return bundle
    }
    
    fileprivate func fetchDeviceForSignalAddress(_ signalAddress:SignalAddress) -> ChatOmemoDevice? {
        guard let parentEntry = self.parentKeyAndCollectionForSignalAddress(signalAddress) else {
            return nil
        }
        
        let deviceNumber = NSNumber(value: signalAddress.deviceId as Int32)
        guard let device = ChatOmemoDevice.omemoDevice(for: parentEntry.key, parentCollection: parentEntry.collection, deviceId: deviceNumber) else {
            return nil
        }
        
        return device
    }
    
    fileprivate func parentKeyAndCollectionForSignalAddress(_ signalAddress:SignalAddress) -> (key: String, collection: String)? {
        var parentKey:String? = nil
        var parentCollection:String? = nil
        let ourAccount = ChatAccountModel.getXMPPAccount(uniqueId: self.accountKey)
        if ourAccount?.username == signalAddress.name {
            
            parentKey = self.accountKey
            parentCollection = ChatAccountModel.collection()
            
        } else if let jid = XMPPJID(string: signalAddress.name), let buddy = ChatBuddyModel.fetchBuddy(jid: jid, accountUniqueId: self.accountKey) {
            parentKey = buddy.uniqueId
            parentCollection = ChatBuddyModel.collection()
        }
        
        guard let key = parentKey, let collection = parentCollection else {
            return nil
        }
        
        return (key: key, collection: collection)
    }
}
//MARK: SignalStore
extension OTRSignalStorageManager: SignalStore {
    
    public func sessionRecord(for address: SignalAddress) -> Data? {
        return sessionRecord(for: address, transaction: nil)
    }
    
    //MARK: SignalSessionStore
    public func sessionRecord(for address: SignalAddress, transaction:GRDBReadTransaction?) -> Data? {
        let key = ChatSignalSession.uniqueKey(for: self.accountKey, name: address.name, deviceId: address.deviceId)
        
        return ChatSignalSession.signalSession(for: key, transaction: transaction)?.sessionData
    }
    
    public func storeSessionRecord(_ recordData: Data, for address: SignalAddress) -> Bool {
        guard recordData.isEmpty == false else {
            return false
        }
        
        let session = ChatSignalSession(accountKey: self.accountKey, name: address.name, deviceId: address.deviceId, sessionData: recordData)
        
#if !TARGET_IS_NOTIFICATION //ALF IOSM-328 removed
        session.save()
#endif
        return true
    }
    
    public func sessionRecordExists(for address: SignalAddress) -> Bool {
        if let _ = self.sessionRecord(for: address) {
            return true
        } else {
            return false
        }
    }
    
    public func sessionRecordExists(for address: SignalAddress, transaction:GRDBReadTransaction) -> Bool {
        if let _ = self.sessionRecord(for: address, transaction:transaction) {
            return true
        } else {
            return false
        }
    }
    
    public func deleteSessionRecord(for address: SignalAddress) -> Bool {
#if !TARGET_IS_EXTENSION
        let uniqueKey = ChatSignalSession.uniqueKey(for: self.accountKey, name: address.name, deviceId: address.deviceId)
        ChatSignalSession.removeSession(for: uniqueKey)
#endif
        return true
    }
    
    public func deleteSessionRecord(for address: SignalAddress, transaction:GRDBWriteTransaction) -> Bool {
#if !TARGET_IS_EXTENSION
        let uniqueKey = ChatSignalSession.uniqueKey(for: self.accountKey, name: address.name, deviceId: address.deviceId)
        ChatSignalSession.removeSession(for: uniqueKey, transaction:transaction)
#endif
        return true
    }
    
    public func allDeviceIds(forAddressName addressName: String) -> [NSNumber] {
        return ChatSignalSession.allDeviceIds(for: self.accountKey, signalAddressName: addressName)
    }
    
    public func deleteAllSessions(forAddressName addressName: String) -> Int32 {
        var count:Int32 = 0
#if !TARGET_IS_EXTENSION
        let icnt = ChatSignalSession.removeSessions(for: self.accountKey, signalAddressName: addressName)
        count = Int32(icnt)
#endif
        return count
    }
    
    //MARK: SignalPreKeyStore
    public func loadPreKey(withId preKeyId: UInt32) -> Data? {
        var preKeyData:Data? = nil
        let pKey = ChatPreKey.uniqueKey(for: self.accountKey, keyId: preKeyId)
        if let signedPreKey = ChatPreKey.signalPreKey(for: pKey) {
            preKeyData = signedPreKey.keyData
        } else {
            let count = ChatPreKey.allLiveSignalPreKeys(for: self.accountKey, includeDeleted: true)
            //print("***** preKey not found but we have \(count) including deleted")
        }
        return preKeyData
    }
    
    public func storePreKey(_ preKey: Data, preKeyId: UInt32) -> Bool {
        var result = false
#if !TARGET_IS_EXTENSION
        result = self.storePreKeyPrivate(preKey, preKeyId: preKeyId)
#endif
        //print("***** Just stored preKey with result \(result)")
        return result
    }
    
    public func containsPreKey(withId preKeyId: UInt32) -> Bool {
        if let _ = self.loadPreKey(withId: preKeyId) {
            return true
        } else {
            return false
        }
    }
    
    /// Returns true if deleted, false if not found
    public func deletePreKey(withId preKeyId: UInt32) -> Bool {
        var result = false
#if !TARGET_IS_EXTENSION
        let pKey = ChatPreKey.uniqueKey(for: self.accountKey, keyId: preKeyId)
        //print("***** Trying to delete preKey")
        if var preKey = ChatPreKey.signalPreKey(for: pKey) {
            preKey.keyData = nil
            preKey.save()
            result = true
            //print("***** Just deleted preKey with result \(result)")
        }
#endif
        return result
    }
    
    //MARK: SignalSignedPreKeyStore
    public func loadSignedPreKey(withId signedPreKeyId: UInt32) -> Data? {
        var preKeyData:Data? = nil
        if let signedPreKey = ChatSignedPreKey.signalSignedPreKey(for: self.accountKey) {
            preKeyData = signedPreKey.keyData
        }
        
        return preKeyData
    }
    
    public func storeSignedPreKey(_ signedPreKey: Data, signedPreKeyId: UInt32) -> Bool {
        let signedPreKeyDatabaseObject = ChatSignedPreKey(accountKey: self.accountKey, keyId: signedPreKeyId, keyData: signedPreKey)// else {return false }
#if !TARGET_IS_EXTENSION
        do {
            try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                signedPreKeyDatabaseObject.grdbSave(transaction: transaction)
            })
        } catch {
            DDLogError("Tried to save record but failed")
            return false
        }
        
        //signedPreKeyDatabaseObject.save(completion:{
        //    return true
        //})
#endif
        return true
    }
    
    public func storeSignedPreKey(_ signedPreKey: Data, signedPreKeyId: UInt32, transaction:GRDBWriteTransaction) -> Bool {
        let signedPreKeyDatabaseObject = ChatSignedPreKey(accountKey: self.accountKey, keyId: signedPreKeyId, keyData: signedPreKey)// else {return false }
#if !TARGET_IS_EXTENSION
        do {
            signedPreKeyDatabaseObject.grdbSave(transaction: transaction)
        } catch {
            DDLogError("Tried to save record but failed")
            return false
        }
        
        //signedPreKeyDatabaseObject.save(completion:{
        //    return true
        //})
#endif
        return true
    }
    
    public func containsSignedPreKey(withId signedPreKeyId: UInt32) -> Bool {
        if let _ = self.loadSignedPreKey(withId: signedPreKeyId) {
            return true
        } else {
            return false
        }
    }
    
    public func removeSignedPreKey(withId signedPreKeyId: UInt32) -> Bool {
#if !TARGET_IS_EXTENSION
        ChatSignedPreKey.removeSignalSignedPreKey(for: self.accountKey)
#endif
        return true
    }
    
    //MARK: SignalIdentityKeyStore
    public func getIdentityKeyPair() -> SignalIdentityKeyPair {
        if let result = self.accountSignalIdentity() {
            return result.getKeyPair()
        }
        
        //Generate new identitiy key pair?
        let chatIdentity = self.generateNewIdenityKeyPair()
        return chatIdentity.getKeyPair()
    }
    
    public func getIdentityKeyPair(_ transaction:GRDBWriteTransaction) -> SignalIdentityKeyPair {
        if let result = self.accountSignalIdentity(transaction) {
            return result.getKeyPair()
        }
        
        //Generate new identitiy key pair?
        let chatIdentity = self.generateNewIdenityKeyPair(transaction)
        return chatIdentity.getKeyPair()
    }
    
    public func getLocalRegistrationId() -> UInt32 {
        
        if let result = self.accountSignalIdentity() {
            return result.registrationId;
        } else {
            //Generate new registration ID?
            return self.generateNewIdenityKeyPair().registrationId
        }
    }
    
    public func getLocalRegistrationId(_ transaction:GRDBWriteTransaction) -> UInt32 {
        
        if let result = self.accountSignalIdentity(transaction) {
            return result.registrationId;
        } else {
            //Generate new registration ID?
            return self.generateNewIdenityKeyPair(transaction).registrationId
        }
    }
    
    
    public func saveIdentity(_ address: SignalAddress, identityKey: Data?) -> Bool {
        var result = false
#if !TARGET_IS_EXTENSION
        if let device = self.fetchDeviceForSignalAddress(address) {
            let newDevice = ChatOmemoDevice(deviceIdInt: device.deviceId, trustLevelInt: device.trustLevel, parentKey: device.parentKey, parentCollection: device.parentCollection, publicIdentityKeyData: identityKey, lastSeenDate:device.lastSeenDate)
                newDevice.save()
            result = true
        } else if let parentEntry = self.parentKeyAndCollectionForSignalAddress(address) {
            //See if we have any devices
            //var hasDevices = ChatOmemoDevice.allOMEMODevices(for: parentEntry.key, collection: parentEntry.collection).count > 0
                
            var trustLevel = OMEMOTrustLevel.trustedTofu // since we are in a closed network
            /*if (!hasDevices) {
                //This is the first time we're seeing a device list for this account/buddy so it should be saved as TOFU
                trustLevel = .trustedTofu
            }*/
            let deviceIdNumber = NSNumber(value: address.deviceId as Int32)
            let newDevice = ChatOmemoDevice(deviceId: deviceIdNumber, trustLevel: trustLevel, parentKey: parentEntry.key, parentCollection: parentEntry.collection, publicIdentityKeyData: identityKey, lastSeenDate:Date())
            newDevice.save()
            result = true
        }
#endif
        return result
    }
    
    
    // We always return true here because we want Signal to always encrypt and decrypt messages. We deal with trust elsewhere.
    public func isTrustedIdentity(_ address: SignalAddress, identityKey: Data) -> Bool {
        return true
    }
    
    //MARK: SignalSenderKeyStore
    
    public func storeSenderKey(_ senderKey: Data, address: SignalAddress, groupId: String) -> Bool {
#if !TARGET_IS_EXTENSION
        guard senderKey.count > 0, address.deviceId != nil else { return false }
            
        let senderKey = ChatSenderKey(accountKey: self.accountKey, name: address.name, deviceId: address.deviceId, groupId: groupId, senderKey: senderKey)
        senderKey.save()
#endif
        return true
    }
    
    public func loadSenderKey(for address: SignalAddress, groupId: String) -> Data? {
        var senderKeyData:Data? = nil
        let key = ChatSenderKey.uniqueKey(from: self.accountKey, name: address.name, deviceId: address.deviceId, groupId: groupId)
        if let senderKey = ChatSenderKey.getSignalSenderKey(for: key) {
            senderKeyData = senderKey.senderKey
        }
        return senderKeyData
    }
}
