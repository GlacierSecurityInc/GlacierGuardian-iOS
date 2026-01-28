//  Glacier
//  Created by andyfriedman on 12/13/23.
//  Copyright © 2023 Glacier. All rights reserved.

import Foundation
import GRDB

public struct ChatSignalSession: GRDBRecord, TableRecord {
    public var id: Int64?
    public var uniqueId: String
    var accountKey: String
    var name: String
    var deviceId: Int32
    var sessionData: Data
    
    public init(accountKey:String, name:String, deviceId:Int32, sessionData: Data) {
        self.uniqueId = Self.uniqueKey(for: accountKey, name: name, deviceId: deviceId)
        self.accountKey = accountKey
        self.name = name
        self.deviceId = deviceId
        self.sessionData = sessionData
    }
    
    public static var databaseTableName: String {
        "chatSignalSession"
    }
    
    public static func uniqueKey(for accountKey:String, name:String, deviceId:Int32) -> String {
        return "\(accountKey)-\(name)-\(deviceId)"
    }
}

extension ChatSignalSession {
    public static func signalSession(for uniqueId: String, transaction:GRDBReadTransaction?) -> ChatSignalSession? {
        var session:ChatSignalSession? = nil
        do {
            if let transaction = transaction {
                session = try ChatSignalSession
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database)
            } else {
                try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                    session = try ChatSignalSession
                        .filter(Column("uniqueId") == uniqueId)
                        .fetchOne(transaction.database)
                })
            }
        } catch {
            DDLogError("ChatSignalSession.signalSession error: \(error)")
        }
        
        return session
    }
    
    public static func allDeviceIds(for accountKey: String, signalAddressName: String) -> [NSNumber] {
        var addresses = [NSNumber]()
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let records = try ChatSignalSession
                    .filter(Column("accountKey") == accountKey)
                    .filter(Column("name") == signalAddressName)
                    .fetchAll(transaction.database)
                for record in records {
                    addresses.append(NSNumber(value: Int32(record.deviceId)))
                }
            })
        } catch {
            DDLogError("ChatSignalSession.signalSession error: \(error)")
        }
        
        return addresses
    }
    
    public static func removeSession(for uniqueId: String) {
        do {
            try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                try ChatSignalSession
                    .filter(Column("uniqueId") == uniqueId)
                    .deleteAll(transaction.database)
            })
        } catch {
            DDLogDebug("ChatSignalSession.removeSession: \(error)")
        }
    }
    
    public static func removeSession(for uniqueId: String, transaction:GRDBWriteTransaction) {
        do {
            try ChatSignalSession
                .filter(Column("uniqueId") == uniqueId)
                .deleteAll(transaction.database)
        } catch {
            DDLogDebug("ChatSignalSession.removeSession: \(error)")
        }
    }
    
    public static func removeSessions(for accountKey: String, signalAddressName: String) -> Int {
        var count = 0
        do {
            try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                count = try ChatSignalSession
                    .filter(Column("accountKey") == accountKey)
                    .filter(Column("name") == signalAddressName)
                    .deleteAll(transaction.database)
            })
        } catch {
            DDLogDebug("ChatSignalSession.removeSessions: \(error)")
        }
        
        return count
    }
}
