//  Glacier
//  Created by andyfriedman on 12/13/23.
//  Copyright © 2023 Glacier. All rights reserved.

import Foundation
import GRDB

public struct ChatSenderKey: GRDBRecord, TableRecord {
    public var id: Int64?
    public var uniqueId: String
    var accountKey: String
    var name: String
    var deviceId: Int32
    var groupId: String
    var senderKey: Data
    
    public init(accountKey:String, name:String, deviceId:Int32, groupId:String, senderKey:Data) {
        self.uniqueId = Self.uniqueKey(from: accountKey, name: name, deviceId: deviceId, groupId: groupId)
        self.name = name
        self.deviceId = deviceId
        self.groupId = groupId
        self.senderKey = senderKey
        self.accountKey = accountKey
    }
    
    public static func uniqueKey(from accountKey:String, name:String, deviceId:Int32, groupId:String) -> String {
        return "\(accountKey)-\(name)-\(deviceId)-\(groupId)"
    }
    
    public static var databaseTableName: String {
        "chatSenderKey"
    }
}

extension ChatSenderKey {
    public static func getSignalSenderKey(for uniqueId: String) -> ChatSenderKey? {
        var csKey:ChatSenderKey? = nil
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                csKey = try ChatSenderKey
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database)
            })
        } catch {
            DDLogError("ChatSenderKey.getSignalSenderKey error: \(error)")
        }
        
        return csKey
    }
}
