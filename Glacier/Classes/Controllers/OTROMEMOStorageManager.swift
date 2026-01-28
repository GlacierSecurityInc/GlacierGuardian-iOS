//  ChatSecure
//  Created by David Chiles on 9/15/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.

import Foundation
import XMPPFramework
import GRDB

/**
 * Storage for XMPP-OMEMO 
 * This class handles storage of devies as it relates to our and our buddies device(s).
 * Create one per XMPP account.
 */
open class OTROMEMOStorageManager {
    let accountKey:String
    let accountCollection:String
    
    /**
     Create an OTROMEMOStorageManager.
     
     - parameter accountKey: The account key
     - parameter accountCollection: They account collection
     */
    init(accountKey:String, accountCollection:String) {
        self.accountKey = accountKey
        self.accountCollection = accountCollection
    }
    
    /**
     Convenience method that uses the class database connection.
     Retrievs all the devices for a given key and collection. Could be either for a buddy or an account.
     
     - parameter Key: The key for the account or buddy
     - parameter Collection: The collection for the account or buddy
     
     - returns: An Array of OTROMEMODevices. If there are no devices the array will be empty.
     **/
    open func getDevicesForParentKey(_ key:String, collection:String, trustedOnly:Bool) -> [ChatOmemoDevice] {
        return ChatOmemoDevice.allOMEMODevices(for: key, collection: collection)
    }
    
    open func getDevicesForParentKey(_ key:String, collection:String, trustedOnly:Bool, transaction: GRDBReadTransaction) -> [ChatOmemoDevice] {
        return ChatOmemoDevice.allOMEMODevices(for: key, collection: collection, transaction: transaction)
    }
    
    /**
     Uses the class account key and collection to get all devices.
     
     - returns: An Array of ChatOMEMODevices. If there are no devices the array will be empty.
     */
    open func getDevicesForOurAccount(trustedOnly:Bool) -> [ChatOmemoDevice] {
        return self.getDevicesForParentKey(self.accountKey, collection: self.accountCollection, trustedOnly: trustedOnly)
    }
    
    open func getDevicesForOurAccount(trustedOnly:Bool, transaction: GRDBReadTransaction) -> [ChatOmemoDevice] {
        return self.getDevicesForParentKey(self.accountKey, collection: self.accountCollection, trustedOnly: trustedOnly, transaction: transaction)
    }
    
    /**
     Uses the class account key and collection to get all devices for a given bare JID. Uses the class database connection.
     
     - parameter username: The bare JID for the buddy.
     
     - returns: An Array of ChatOMEMODevices. If there are no devices the array will be empty.
     */
    open func getDevicesForBuddy(_ username:String, trustedOnly:Bool) -> [ChatOmemoDevice] {
        var result: [ChatOmemoDevice] = []
        guard let jid = XMPPJID(string: username) else { return [] }
        
        if let buddy = ChatBuddyModel.fetchBuddy(jid: jid, accountUniqueId: self.accountKey) {
            result = self.getDevicesForParentKey(buddy.uniqueId, collection: ChatBuddyModel.collection(), trustedOnly: trustedOnly)
        }
        return result
    }
    
    open func getDevicesForBuddy(_ username:String, trustedOnly:Bool, transaction: GRDBReadTransaction) -> [ChatOmemoDevice] {
        var result: [ChatOmemoDevice] = []
        guard let jid = XMPPJID(string: username) else { return [] }
        
        if let buddy = ChatBuddyModel.fetchBuddy(jid: jid, accountUniqueId: self.accountKey, transaction: transaction) {
            result = self.getDevicesForParentKey(buddy.uniqueId, collection: ChatBuddyModel.collection(), trustedOnly: trustedOnly, transaction: transaction)
        }
        return result
    }
    
    /**
     Store devices for a key/collection
     
     - parameter devices: An array of the device numbers. Should be UInt32.
     - parameter parentKey: The key to attach the device to
     - parameter parentCollection: the collection to attach the device to
     */
    fileprivate func storeDevices(_ devices:[NSNumber], parentKey:String, parentCollection:String) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            var previouslyStoredDevices:[ChatOmemoDevice] = []
            do {
                previouslyStoredDevices = try ChatOmemoDevice
                    .filter(Column("parentKey") == parentKey)
                    .filter(Column("parentCollection") == parentCollection)
                    .fetchAll(transaction.database)
            } catch {
                DDLogError("storeDevices.previouslyStoredDevices error: \(error)")
            }
            
            let previouslyStoredDevicesIds = previouslyStoredDevices.map({ (device) -> NSNumber in
                return NSNumber(value:device.deviceId)
            })
            
            // if newDeviceSet contains a device that exists but is in remoevd state
            // re-save as trusted
            let newDeviceSet = Set(devices)
            newDeviceSet.forEach({ (deviceId) in
                var nDevice:ChatOmemoDevice?
                do {
                    let key = ChatOmemoDevice.keyWith(deviceId: deviceId, parentKey: parentKey, parentCollection: parentCollection)
                    nDevice = try ChatOmemoDevice
                            .filter(Column("uniqueId") == key)
                            .fetchOne(transaction.database)
                } catch {
                    DDLogError("storeDevices.newDeviceSet error: \(error)")
                }
                
                
                guard var device = nDevice else {
                    return
                }
                
                if device.trustLevel == OMEMOTrustLevel.removed.rawValue {
                    device.trustLevel = OMEMOTrustLevel.trustedTofu.rawValue
                    device.grdbSave(transaction: transaction)
                }
            })
            
            let previouslyStoredDevicesIdSet = Set(previouslyStoredDevicesIds)
            
            if (devices.count == 0) {
                // Remove all devices
                previouslyStoredDevices.forEach({ (device) in
                    device.grdbRemove(transaction: transaction)
                })
            } else if (previouslyStoredDevicesIdSet != newDeviceSet) {
                //previously trusted keys which were deleted from the server are not reenabled when they are re-added on the server
                //devicesToAdd is built by substracting the "previouslyStoredDevicesIdSet" set from newDeviceSet. The issue is that the removed devices are present in the "previouslyStoredDevicesIdSet" set so they are not in the "devicesToAdd" set.
                //There should be another device set containing "already known removed" devices which are now back on the server, and then reenable each of them.
                
                let devicesToRemove:Set<NSNumber> = previouslyStoredDevicesIdSet.subtracting(newDeviceSet)
                let devicesToAdd:Set<NSNumber> = newDeviceSet.subtracting(previouslyStoredDevicesIdSet)
                
                var mostRecentDevice:String?
                var mostRecentDate:Date?
                previouslyStoredDevicesIdSet.forEach({ (deviceId) in
                    let deviceKey = ChatOmemoDevice.keyWith(deviceId: deviceId, parentKey: parentKey, parentCollection: parentCollection)
                    guard let device = ChatOmemoDevice.omemoDevice(for: deviceKey, transaction: transaction) else {
                        return
                    }
                    
                    if let recentDate = mostRecentDate {
                        if (device.lastSeenDate > recentDate) {
                            mostRecentDate = device.lastSeenDate
                            mostRecentDevice = deviceKey
                        }
                    } else {
                        mostRecentDate = device.lastSeenDate
                        mostRecentDevice = deviceKey
                    }
                })
                
                // Instead of fulling removing devices, mark them as removed for historical purposes
                devicesToRemove.forEach({ (deviceId) in
                    let deviceKey = ChatOmemoDevice.keyWith(deviceId: deviceId, parentKey: parentKey, parentCollection: parentCollection)
                    
                    var rDevice:ChatOmemoDevice?
                    do {
                        rDevice = try ChatOmemoDevice
                                .filter(Column("uniqueId") == deviceKey)
                                .fetchOne(transaction.database)
                    } catch {
                        DDLogError("storeDevices.devicesToRemove error: \(error)")
                    }
                    
                    guard var device = rDevice else {
                        return
                    }
                    
                    // if device last seen 45+ days ago AND removed from list
                    // AND not most recent
                    if (device.isExpired() && deviceKey != mostRecentDevice) {
                        device.trustLevel = OMEMOTrustLevel.removed.rawValue
                        device.grdbSave(transaction: transaction)
                    }
                })
                
                devicesToAdd.forEach({ (deviceId) in
                    
                    var trustLevel = OMEMOTrustLevel.trustedTofu // since we are in a closed network
                    if (previouslyStoredDevices.count == 0) {
                        //This is the first time we're seeing a device list for this account/buddy so it should be saved as TOFU
                        trustLevel = .trustedTofu
                    }
                    
                    let newDevice = ChatOmemoDevice(deviceId: deviceId, trustLevel:trustLevel, parentKey: parentKey, parentCollection: parentCollection, publicIdentityKeyData: nil, lastSeenDate:Date())
                    newDevice.grdbSave(transaction: transaction)
                })
                
            }
        })
    }
    
    /**
     Store devices for this account. These should come from the OMEMO device-list
     
     - parameter devices: An array of the device numbers. Should be UInt32.
     */
    open func storeOurDevices(_ devices:[NSNumber]) {
#if !TARGET_IS_EXTENSION
        self.storeDevices(devices, parentKey: self.accountKey, parentCollection: self.accountCollection)
#endif
    }
    
    /**
     Store devices for a buddy connected to this account. These should come from the OMEMO device-list
     
     - parameter devices: An array of the device numbers. Should be UInt32.
     - parameter buddyUsername: The bare JID for the buddy.
     */
    open func storeBuddyDevices(_ devices:[NSNumber], buddyUsername:String, completion:(()->Void)?) {
#if !TARGET_IS_EXTENSION
        // Fetch the buddy from the database.
        guard let jid = XMPPJID(string: buddyUsername), let buddy = ChatBuddyModel.fetchBuddy(jid: jid, accountUniqueId: self.accountKey) else {
            // If this is teh first launch the buddy will not be in the buddy list becuase the roster comes in after device list from PEP.
            DDLogWarn("Could not find buddy to store devices \(buddyUsername)")
            return
        }
        self.storeDevices(devices, parentKey: buddy.uniqueId, parentCollection: ChatBuddyModel.collection())
        completion?()
#endif
    }
}
