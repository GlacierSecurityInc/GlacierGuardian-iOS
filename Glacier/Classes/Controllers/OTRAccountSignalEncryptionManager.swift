//
//  OTRSignalEncryptionManager.swift
//  ChatSecure
//
//  Created by David Chiles on 7/27/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

import UIKit
import SignalProtocolObjC
import XMPPFramework

public enum SignalEncryptionError:Error {
    case unableToCreateSignalContext
}

/* Performs any Signal operations: creating bundle, decryption, encryption. Use one OTRAccountSignalEncryptionManager per account **/
open class OTRAccountSignalEncryptionManager {
    
    let storage:OTRSignalStorageManager
    var signalContext:SignalContext
    
    //In OMEMO world the registration ID is used as the device id and all devices have registration ID of 0.
    open var registrationId:UInt32 {
        get {
            return self.storage.getLocalRegistrationId()
        }
    }
    
    open var identityKeyPair:SignalIdentityKeyPair {
        get {
            return self.storage.getIdentityKeyPair()
        }
    }
    
    init(accountKey:String) throws {
        self.storage = OTRSignalStorageManager(accountKey: accountKey, delegate: nil)
        let signalStorage = SignalStorage(signalStore: self.storage)
        guard let context = SignalContext(storage: signalStorage) else {
            throw SignalEncryptionError.unableToCreateSignalContext
        }
        self.signalContext = context
        self.storage.delegate = self
    }
}

extension OTRAccountSignalEncryptionManager {
    internal func keyHelper() -> SignalKeyHelper? {
        return SignalKeyHelper(context: self.signalContext)
    }
    
    public func generateRandomSignedPreKey() -> SignalSignedPreKey? {
        guard let preKeyId = self.keyHelper()?.generateRegistrationId() else {
            return nil
        }
        guard let signedPreKey = self.keyHelper()?.generateSignedPreKey(withIdentity: self.identityKeyPair, signedPreKeyId:preKeyId),
            let data = signedPreKey.serializedData() else {
            return nil
        }
        if self.storage.storeSignedPreKey(data, signedPreKeyId: signedPreKey.preKeyId) {
            return signedPreKey
        }
        return nil
    }
    
    public func generateRandomSignedPreKey(_ transaction:GRDBWriteTransaction) -> SignalSignedPreKey? {
        guard let preKeyId = self.keyHelper()?.generateRegistrationId() else {
            return nil
        }
        guard let signedPreKey = self.keyHelper()?.generateSignedPreKey(withIdentity: self.storage.getIdentityKeyPair(transaction), signedPreKeyId:preKeyId),
            let data = signedPreKey.serializedData() else {
            return nil
        }
        if self.storage.storeSignedPreKey(data, signedPreKeyId: signedPreKey.preKeyId, transaction: transaction) {
            return signedPreKey
        }
        return nil
    }
    
    /** 
     * This creates all the information necessary to publish a 'bundle' to your XMPP server via PEP. It generates prekeys 0 to 99.
     */
    public func generateOutgoingBundle(_ preKeyCount:UInt) throws -> OMEMOBundle {
        let identityKeyPair = self.storage.getIdentityKeyPair()
        let deviceId = self.registrationId
        
        // Fetch existing signed pre-key to prevent regeneration
        // The existing storage code only allows for storage of 
        // a single signedprekey per account, so regeneration
        // will break things.
        var signalSignedPreKey: SignalSignedPreKey? = nil
        if let signedPreKeyDataObject = ChatSignedPreKey.signalSignedPreKey(for: self.storage.accountKey) {
            do {
                signalSignedPreKey = try SignalSignedPreKey(serializedData: signedPreKeyDataObject.keyData)
            } catch {
                DDLogError("Error parsing SignalSignedPreKey")
            }
        } 

        // If there is no existing one, generate a new one
        var newkey = false
        if signalSignedPreKey == nil {
            signalSignedPreKey = self.generateRandomSignedPreKey()
            newkey = true
        }
        //else { throw OMEMOBundleError.notFound }
        guard let signedPreKey = signalSignedPreKey, let data = signedPreKey.serializedData() else {
            throw OMEMOBundleError.keyGeneration
        }
        guard let preKeys = self.generatePreKeys(1, count: preKeyCount) else {
            throw OMEMOBundleError.keyGeneration
        }
        let bundle = try OMEMOBundle(deviceId: deviceId, identity: identityKeyPair, signedPreKey: signedPreKey, preKeys: preKeys)
        if newkey == true {//false {
            _ = self.storage.storeSignedPreKey(data, signedPreKeyId: signedPreKey.preKeyId)
        }
        return bundle
    }
    
    /**
     * This creates all the information necessary to publish a 'bundle' to your XMPP server via PEP. It generates prekeys 0 to 99.
     */
    public func generateOutgoingBundle(_ preKeyCount:UInt, transaction:GRDBWriteTransaction) throws -> OMEMOBundle {
        let identityKeyPair = self.storage.getIdentityKeyPair(transaction)
        let deviceId = self.storage.getLocalRegistrationId(transaction)
        
        // Fetch existing signed pre-key to prevent regeneration
        // The existing storage code only allows for storage of
        // a single signedprekey per account, so regeneration
        // will break things.
        var signalSignedPreKey: SignalSignedPreKey? = nil
        if let signedPreKeyDataObject = ChatSignedPreKey.signalSignedPreKey(for: self.storage.accountKey, transaction: transaction) {
            do {
                signalSignedPreKey = try SignalSignedPreKey(serializedData: signedPreKeyDataObject.keyData)
            } catch {
                DDLogError("Error parsing SignalSignedPreKey")
            }
        }

        // If there is no existing one, generate a new one
        var newkey = false
        if signalSignedPreKey == nil {
            signalSignedPreKey = self.generateRandomSignedPreKey(transaction)
            newkey = true
        }
        //else { throw OMEMOBundleError.notFound }
        guard let signedPreKey = signalSignedPreKey, let data = signedPreKey.serializedData() else {
            throw OMEMOBundleError.keyGeneration
        }
        guard let preKeys = self.generatePreKeys(1, count: preKeyCount, transaction: transaction) else {
            throw OMEMOBundleError.keyGeneration
        }
        let bundle = try OMEMOBundle(deviceId: deviceId, identity: identityKeyPair, signedPreKey: signedPreKey, preKeys: preKeys)
        if newkey == true {//false {
            _ = self.storage.storeSignedPreKey(data, signedPreKeyId: signedPreKey.preKeyId, transaction: transaction)
        }
        return bundle
    }
    
    /**
     * This processes fetched OMEMO bundles. After you consume a bundle you can then create preKeyMessages to send to the contact.
     */
    public func consumeIncomingBundle(_ name:String, bundle:OMEMOBundle) throws {
        let deviceId = Int32(bundle.deviceId)
        let incomingAddress = SignalAddress(name: name.lowercased(), deviceId: deviceId)
        let sessionBuilder = SignalSessionBuilder(address: incomingAddress, context: self.signalContext)
        let preKeyBundle = try bundle.signalBundle()
        
        return try sessionBuilder.processPreKeyBundle(preKeyBundle)
    }
    
    public func encryptToAddress(_ data:Data, name:String, deviceId:UInt32) throws -> SignalCiphertext {
        let address = SignalAddress(name: name.lowercased(), deviceId: Int32(deviceId))
        let sessionCipher = SignalSessionCipher(address: address, context: self.signalContext)
        return try sessionCipher.encryptData(data)
    }
    
    public func decryptFromAddress(_ data:Data, name:String, deviceId:UInt32) throws -> Data {
        let address = SignalAddress(name: name.lowercased(), deviceId: Int32(deviceId))
        let sessionCipher = SignalSessionCipher(address: address, context: self.signalContext)
        let cipherText = SignalCiphertext(data: data, type: .unknown)
        return try sessionCipher.decryptCiphertext(cipherText)
    }
    
    
    public func generatePreKeys(_ start:UInt, count:UInt) -> [SignalPreKey]? {
        guard let preKeys = self.keyHelper()?.generatePreKeys(withStartingPreKeyId: start, count: count) else {
            return nil
        }
        if self.storage.storeSignalPreKeys(preKeys) {
            return preKeys
        }
        return nil
    }
    
    public func generatePreKeys(_ start:UInt, count:UInt, transaction:GRDBWriteTransaction) -> [SignalPreKey]? {
        guard let preKeys = self.keyHelper()?.generatePreKeys(withStartingPreKeyId: start, count: count) else {
            return nil
        }
        if self.storage.storeSignalPreKeys(preKeys, transaction: transaction) {
            return preKeys
        }
        return nil
    }
    
    public func sessionRecordExistsForUsername(_ username:String, deviceId:Int32) -> Bool {
        let address = SignalAddress(name: username.lowercased(), deviceId: deviceId)
        return self.storage.sessionRecordExists(for: address)
    }
    
    public func sessionRecordExistsForUsername(_ username:String, deviceId:Int32, transaction:GRDBReadTransaction) -> Bool {
        let address = SignalAddress(name: username.lowercased(), deviceId: deviceId)
        return self.storage.sessionRecordExists(for: address, transaction:transaction)
    }
    
    public func removeSessionRecordForUsername(_ username:String, deviceId:Int32) -> Bool {
        let address = SignalAddress(name: username.lowercased(), deviceId: deviceId)
        return self.storage.deleteSessionRecord(for: address)
    }
}

extension OTRAccountSignalEncryptionManager: OTRSignalStorageManagerDelegate {
    
    public func generateNewIdenityKeyPairForAccountKey(_ accountKey:String) -> ChatAccountSignalIdentity {
        let keyHelper = self.keyHelper()!
        let keyPair = keyHelper.generateIdentityKeyPair()!
        let registrationId = keyHelper.generateRegistrationId()
        return ChatAccountSignalIdentity(accountKey: accountKey, identityKeyPair: keyPair, registrationId: registrationId)
    }
}
