//
//  ChatOMEMODevice.swift
//  Glacier
//
//  Created by andyfriedman on 12/14/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import GRDB

public enum OMEMOTrustLevel:Int {
    case untrustedNew = 0 // incoming messages only
    case untrusted = 1
    case trustedTofu = 2
    case trustedUser = 3
    case removed = 4 // counts as delivered if >1 receipts
}

public struct ChatOmemoDevice: GRDBRecord, TableRecord {
    public var id: Int64?
    public var uniqueId: String
    
    var parentKey: String
    var parentCollection: String
    var deviceId: Int
    var publicIdentityKeyData: Data?
    var trustLevel: Int
    var lastSeenDate: Date
    //var modified: Date?
    
    public init(deviceId:NSNumber, trustLevel:OMEMOTrustLevel?, parentKey:String, parentCollection:String, publicIdentityKeyData:Data?, lastSeenDate:Date?) {
        self.uniqueId = Self.keyWith(deviceId: deviceId, parentKey: parentKey, parentCollection: parentCollection)
        self.deviceId = deviceId.intValue
        self.parentKey = parentKey
        self.parentCollection = parentCollection
        if let trust = trustLevel {
            self.trustLevel = trust.rawValue
        } else {
            self.trustLevel = OMEMOTrustLevel.trustedTofu.rawValue
        }
        self.publicIdentityKeyData = publicIdentityKeyData
        self.lastSeenDate = lastSeenDate ?? Date()
    }
    
    public init(deviceIdInt:Int, trustLevelInt:Int?, parentKey:String, parentCollection:String, publicIdentityKeyData:Data?, lastSeenDate:Date?) {
        self.uniqueId = Self.keyWith(deviceId: NSNumber(value: deviceIdInt), parentKey: parentKey, parentCollection: parentCollection)
        self.deviceId = deviceIdInt
        self.parentKey = parentKey
        self.parentCollection = parentCollection
        if let trust = trustLevelInt {
            self.trustLevel = trust
        } else {
            self.trustLevel = OMEMOTrustLevel.trustedTofu.rawValue
        }
        self.publicIdentityKeyData = publicIdentityKeyData
        self.lastSeenDate = lastSeenDate ?? Date()
    }
    
    public static var databaseTableName: String {
        "chatOmemoDevice"
    }
}

extension ChatOmemoDevice {
    
    static func keyWith(deviceId:NSNumber, parentKey:String, parentCollection:String) -> String {
        return "\(deviceId)-\(parentKey)-\(parentCollection)"
    }

#if !TARGET_IS_EXTENSION
    public var humanReadableFingerprint: String {
        guard let pubKeyData = self.publicIdentityKeyData else {
            return ""
        }
        
        var fingerprintData = Data.init()
        if pubKeyData.count == 32 {
            fingerprintData = pubKeyData
        } else if pubKeyData.count >= 33 {
            // why is there an extra 0x05 at the front?
            // maybe blame libsignal-protocol-c library
            fingerprintData = pubKeyData.subdata(in: Range(1...32))
        }
        let fingerprint = (fingerprintData as NSData).humanReadableFingerprint()
        return fingerprint
    }
#endif

    /// Checks if any of the devices are untrusted/new
    static func filterNewDevices(_ devices: [ChatOmemoDevice]) -> [ChatOmemoDevice] {
        let untrusted = devices.filter {
            return ($0.trustLevel == OMEMOTrustLevel.untrustedNew.rawValue)
        }
        return untrusted
    }
    
    //defaults to Buddy collection
    public static func allOMEMODevices(for buddyId: String) -> [ChatOmemoDevice] {
        var devices:[ChatOmemoDevice] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let records = try ChatOmemoDevice
                    .filter(Column("parentKey") == buddyId)
                    .filter(Column("parentCollection") == ChatBuddyModel.collection())
                    .fetchAll(transaction.database)
                for device in records {
                    devices.append(device)
                }
            })
        } catch {
            DDLogError("ChatOmemoDevice.allOMEMODevices error: \(error)")
        }
        
        return devices
    }
    
    public static func countOMEMODevices(for buddyId: String) -> Int {
        var count = 0
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                count = try ChatOmemoDevice
                    .filter(Column("parentKey") == buddyId)
                    .filter(Column("parentCollection") == ChatBuddyModel.collection())
                    .fetchCount(transaction.database)
            })
        } catch {
            DDLogError("ChatOmemoDevice.countOMEMODevices error: \(error)")
        }
        
        return count
    }
    
    public static func allOMEMODevices(for key: String, collection: String) -> [ChatOmemoDevice] {
        return ChatOmemoDevice.allOMEMODevices(for: key, collection: collection, trusted:false)
    }
    
    public static func allOMEMODevices(for key: String, collection: String, transaction: GRDBReadTransaction) -> [ChatOmemoDevice] {
        return ChatOmemoDevice.allOMEMODevices(for: key, collection: collection, transaction: transaction, trusted:false)
    }
    
    public static func allOMEMODevices(for key: String, collection: String, transaction: GRDBReadTransaction, trusted:Bool) -> [ChatOmemoDevice] {
        var devices:[ChatOmemoDevice] = []
        do {
            let records = try ChatOmemoDevice
                .filter(Column("parentKey") == key)
                .filter(Column("parentCollection") == collection)
                .fetchAll(transaction.database)
            for device in records {
                if trusted {
                    if device.isTrusted() {
                        devices.append(device)
                    }
                } else {
                    devices.append(device)
                }
            }
        } catch {
            DDLogError("ChatOmemoDevice.allOMEMODevices error: \(error)")
        }
        
        return devices
    }
    
    public static func allOMEMODevices(for key: String, collection: String, trusted:Bool) -> [ChatOmemoDevice] {
        var devices:[ChatOmemoDevice] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let records = try ChatOmemoDevice
                    .filter(Column("parentKey") == key)
                    .filter(Column("parentCollection") == collection)
                    .fetchAll(transaction.database)
                for device in records {
                    if trusted {
                        if device.isTrusted() {
                            devices.append(device)
                        }
                    } else {
                        devices.append(device)
                    }
                }
            })
        } catch {
            DDLogError("ChatOmemoDevice.allOMEMODevices error: \(error)")
        }
        
        return devices
    }
    
    public static func omemoDevice(for parentKey: String, parentCollection: String, deviceId: NSNumber) -> ChatOmemoDevice? {
        let key = Self.keyWith(deviceId: deviceId, parentKey: parentKey, parentCollection: parentCollection)
        return Self.omemoDevice(for: key)
    }
    
    public static func omemoDevice(for key: String) -> ChatOmemoDevice? {
        var device:ChatOmemoDevice?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                device = try ChatOmemoDevice
                    .filter(Column("uniqueId") == key)
                    .fetchOne(transaction.database)
            })
        } catch {
            DDLogError("ChatOmemoDevice.omemoDevice error: \(error)")
        }
        
        return device
    }
    
    public static func omemoDevice(for key: String, transaction: GRDBReadTransaction) -> ChatOmemoDevice? {
        var device:ChatOmemoDevice?
        do {
            device = try ChatOmemoDevice
                .filter(Column("uniqueId") == key)
                .fetchOne(transaction.database)
        } catch {
            DDLogError("ChatOmemoDevice.omemoDevice error: \(error)")
        }
        
        return device
    }
    
    /** (OMEMOTrustLevelTrustedTofu || OMEMOTrustLevelTrustedUser) && !isExpired */
    func isTrusted() -> Bool {
        let trust = self.trustLevel
        return (trust == OMEMOTrustLevel.trustedTofu.rawValue || trust == OMEMOTrustLevel.trustedUser.rawValue) && self.isExpired() == false
        // return YES; // because we are in closed network //
    }

    /** if lastSeenDate is > 30 days */
    func isExpired() -> Bool {
        let span:TimeInterval = Date().timeIntervalSince(self.lastSeenDate)
        let fortyFiveDays:TimeInterval = 86400 * 45
        if span > fortyFiveDays {
            return true
        }
        return false
    }
}
