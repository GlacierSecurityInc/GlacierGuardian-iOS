//
//  ChatPreKey.swift
//  Glacier
//
//  Created by andyfriedman on 12/12/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import GRDB

public struct ChatPreKey: GRDBRecord, TableRecord {
    //public protocol ChatThread: AnyObject {
    public var id: Int64?
    public var uniqueId: String
    var accountKey: String
    var keyId: UInt32
    var keyData: Data?
    //var modified: Date?
    
    public init(accountKey:String, keyId:UInt32, keyData:Data) {
        self.uniqueId = ChatPreKey.uniqueKey(for: accountKey, keyId: keyId)
        self.accountKey = accountKey
        self.keyId = keyId
        self.keyData = keyData
    }
    
    public static var databaseTableName: String {
        "chatPreKey"
    }
    
    public static func uniqueKey(for accountKey:String, keyId:UInt32) -> String {
        return "\(accountKey)-\(keyId)"
    }
}

extension ChatPreKey {
    public static func allLiveSignalPreKeys(for accountKey: String, includeDeleted: Bool) -> [ChatPreKey] {
        
        var prekeys:[ChatPreKey] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if includeDeleted {
                    prekeys = try ChatPreKey
                        .filter(Column("accountKey") == accountKey)
                        .fetchAll(transaction.database)
                } else {
                    prekeys = try ChatPreKey
                        .filter(Column("accountKey") == accountKey)
                        .filter(Column("keyData") != nil)
                        .fetchAll(transaction.database)
                }
            })
        } catch {
            DDLogError("ChatPreKey.allLiveSignalPreKeys error: \(error)")
        }
        
        return prekeys
    }
    
    public static func allLiveSignalPreKeys(for accountKey: String, includeDeleted: Bool, transaction:GRDBReadTransaction) -> [ChatPreKey] {
        
        var prekeys:[ChatPreKey] = []
        do {
            if includeDeleted {
                prekeys = try ChatPreKey
                    .filter(Column("accountKey") == accountKey)
                    .fetchAll(transaction.database)
            } else {
                prekeys = try ChatPreKey
                    .filter(Column("accountKey") == accountKey)
                    .filter(Column("keyData") != nil)
                    .fetchAll(transaction.database)
            }
        } catch {
            DDLogError("ChatPreKey.allLiveSignalPreKeys error: \(error)")
        }
        
        return prekeys
    }
    
    public static func resetPreKeys(for accountKey: String) {
        do {
            try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                try ChatPreKey
                    .filter(Column("accountKey") == accountKey)
                    .deleteAll(transaction.database)
            })
        } catch {
            DDLogError("ChatPreKey.resetPreKeys error: \(error)")
        }
    }
    
    public static func resetPreKeys(for accountKey: String, transaction:GRDBWriteTransaction) {
        do {
            try ChatPreKey
                .filter(Column("accountKey") == accountKey)
                .deleteAll(transaction.database)
        } catch {
            DDLogError("ChatPreKey.resetPreKeys error: \(error)")
        }
    }
    
    public static func signalPreKey(for uniqueId: String) -> ChatPreKey? {
        var prekey:ChatPreKey? = nil
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                prekey = try ChatPreKey
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database)
            })
        } catch {
            DDLogError("ChatPreKey.signalPreKey error: \(error)")
        }
        
        return prekey
    }
    
    public static func maxPreKeyId(for account: String) -> UInt32? {
        var maxid:UInt32?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let request = ChatPreKey
                    .filter(Column("accountKey") == account)
                    .select(max(Column("keyId")))
                if let max = try Int.fetchOne(transaction.database, request) {
                    maxid = UInt32(max)
                }
            })
        } catch {
            DDLogError("ChatPreKey.maxPreKeyId error: \(error)")
        }
        
        return maxid
    }
    
    public static func maxPreKeyId(for account: String, transaction: GRDBReadTransaction) -> UInt32? {
        var maxid:UInt32?
        do {
            let request = ChatPreKey
                .filter(Column("accountKey") == account)
                .select(max(Column("keyId")))
            if let max = try Int.fetchOne(transaction.database, request) {
                maxid = UInt32(max)
            }
        } catch {
            DDLogError("ChatPreKey.maxPreKeyId error: \(error)")
        }
        
        return maxid
    }
}
