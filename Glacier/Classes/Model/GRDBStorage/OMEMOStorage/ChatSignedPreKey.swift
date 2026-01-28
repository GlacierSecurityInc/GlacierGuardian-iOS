//  Glacier
//  Created by andyfriedman on 12/13/23.
//  Copyright © 2023 Glacier. All rights reserved.

import Foundation
import GRDB

public struct ChatSignedPreKey: GRDBRecord, TableRecord {
    public var id: Int64?
    public var uniqueId: String
    var accountKey: String
    var keyId: UInt32
    var keyData: Data
    
    public init(accountKey:String, keyId:UInt32, keyData:Data) {
        self.uniqueId = UUID().uuidString
        self.accountKey = accountKey
        self.keyId = keyId
        self.keyData = keyData
    }
    
    public static var databaseTableName: String {
        "chatSignedPreKey"
    }
}

extension ChatSignedPreKey {
    public static func removeSignalSignedPreKey(for accountKey: String) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                try ChatSignedPreKey
                    .filter(Column("accountKey") == accountKey)
                    .deleteAll(transaction.database)
            } catch {
                DDLogError("ChatSignedPreKey.removeSignalSignedPreKey error: \(error)")
            }
        })
    }
    
    public static func removeSignalSignedPreKey(for accountKey: String, transaction: GRDBWriteTransaction) {
        do {
            try ChatSignedPreKey
                .filter(Column("accountKey") == accountKey)
                .deleteAll(transaction.database)
        } catch {
            DDLogError("ChatSignedPreKey.removeSignalSignedPreKey error: \(error)")
        }
    }
    
    public static func signalSignedPreKey(for accountId: String) -> ChatSignedPreKey? {
        var prekey:ChatSignedPreKey? = nil
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                prekey = try ChatSignedPreKey
                    .filter(Column("accountKey") == accountId)
                    .fetchOne(transaction.database)
            })
        } catch {
            DDLogError("ChatSignedPreKey.signalSignedPreKey error: \(error)")
        }
        
        return prekey
    }
    
    public static func signalSignedPreKey(for accountId: String, transaction: GRDBReadTransaction) -> ChatSignedPreKey? {
        var prekey:ChatSignedPreKey? = nil
        do {
            prekey = try ChatSignedPreKey
                .filter(Column("accountKey") == accountId)
                .fetchOne(transaction.database)
        } catch {
            DDLogError("ChatSignedPreKey.signalSignedPreKey error: \(error)")
        }
        
        return prekey
    }
}
