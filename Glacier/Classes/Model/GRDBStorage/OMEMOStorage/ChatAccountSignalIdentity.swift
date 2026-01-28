//  Glacier
//  Created by andyfriedman on 12/13/23.
//  Copyright © 2023 Glacier. All rights reserved.

import Foundation
import GRDB
import SignalProtocolObjC

public struct ChatAccountSignalIdentity: GRDBRecord, TableRecord {
    public var id: Int64?
    public var uniqueId: String
    var accountKey: String
    var publicKey:Data
    var privateKey:Data
    var registrationId: UInt32
    
    public init(accountKey:String, identityKeyPair:SignalIdentityKeyPair, registrationId:UInt32) {
        self.uniqueId = UUID().uuidString
        self.accountKey = accountKey
        self.publicKey = identityKeyPair.publicKey
        self.privateKey = identityKeyPair.privateKey
        self.registrationId = registrationId
    }
    
    public func getKeyPair() -> SignalIdentityKeyPair {
        var keyPair:SignalIdentityKeyPair?
        
        do {
            keyPair = try SignalIdentityKeyPair(publicKey: self.publicKey, privateKey: self.privateKey)
        } catch let error {
            DDLogError("Failed creating key pair: \(error)")
        }
        
        return keyPair!
    }
    
    public static var databaseTableName: String {
        "chatAccountSignalIdentity"
    }
}

extension ChatAccountSignalIdentity {
    public static func accountSignalIdKey(for accountId: String) -> ChatAccountSignalIdentity? {
        var sigID:ChatAccountSignalIdentity? = nil
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                sigID = try ChatAccountSignalIdentity
                    .filter(Column("accountKey") == accountId)
                    .fetchOne(transaction.database)
            })
        } catch {
            DDLogError("ChatAccountSignalIdentity.accountSignalIdKey error: \(error)")
        }
        
        return sigID
    }
    
    public static func accountSignalIdKey(for accountId: String, transaction: GRDBReadTransaction) -> ChatAccountSignalIdentity? {
        var sigID:ChatAccountSignalIdentity? = nil
        do {
            sigID = try ChatAccountSignalIdentity
                .filter(Column("accountKey") == accountId)
                .fetchOne(transaction.database)
        } catch {
            DDLogError("ChatAccountSignalIdentity.accountSignalIdKey error: \(error)")
        }
        
        return sigID
    }
    
    public static func removeAccountSignalIdKey(for accountId: String) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                try ChatAccountSignalIdentity
                    .filter(Column("accountKey") == accountId)
                    .deleteAll(transaction.database)
            } catch {
                DDLogError("ChatAccountSignalIdentity.removeAccountSignalIdKey error: \(error)")
            }
        })
    }
    
    public static func removeAccountSignalIdKey(for accountId: String, transaction: GRDBWriteTransaction) {
        do {
            try ChatAccountSignalIdentity
                .filter(Column("accountKey") == accountId)
                .deleteAll(transaction.database)
        } catch {
            DDLogError("ChatAccountSignalIdentity.removeAccountSignalIdKey error: \(error)")
        }
    }
}
