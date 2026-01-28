//  Glacier
//  Created by andyfriedman on 9/4/23.
//  Copyright © 2023 Glacier. All rights reserved.

import Foundation
import GRDB

open class SMSChatAccountModel: GRDBModel {
    var grdbRecord:SMSChatAccount?
    
    private var acctColor: UIColor?
    public var color: UIColor? {
        get {
            if acctColor == nil, let colorStr = grdbRecord?.color {
                acctColor = UIColor.UIColorFromString(string: colorStr)
            }
            
            return acctColor
        }
        set {
            acctColor = newValue
            if let newval = newValue {
                grdbRecord?.color = UIColor.StringFromUIColor(color: newval)
            }
        }
    }
    
    @objc public convenience init(phoneNumber:String, smsacctid:String) {
        self.init()
        self.grdbRecord = SMSChatAccount(uniqueId: self.uniqueId, phoneNumber: phoneNumber, twilioId: smsacctid, displayName: phoneNumber, color: SMSChatAccountModel.getNextColor())
    }
    
    @objc public convenience init(phoneNumber:String, smsacctid:String, color:UIColor) {
        self.init()
        self.grdbRecord = SMSChatAccount(uniqueId: self.uniqueId, phoneNumber: phoneNumber, twilioId: smsacctid, displayName: phoneNumber, color: color)
    }
    
    @objc public convenience init(phoneNumber:String, smsacctid:String, displayName: String, color:UIColor) {
        self.init()
        self.grdbRecord = SMSChatAccount(uniqueId: self.uniqueId, phoneNumber: phoneNumber, twilioId: smsacctid, displayName: displayName, color: color)
    }
    
    convenience init(account: SMSChatAccount) {
        self.init(uniqueId: account.uniqueId)
        self.grdbRecord = account
    }
    
    @objc public func getSmsId() -> String? {
        return self.grdbRecord?.twilioId
    }
    
    public static func getNextColor() -> UIColor {
        return SMSChatAccountModel.getNextColor(0)
    }
    
    public static func getNextColor(_ idx:Int) -> UIColor {
        let accts = SMSChatAccountModel.allAccounts()
        let index = idx % UIColor.solids.count
        
        var newColor = UIColor.solids[index]
        for i in idx..<UIColor.solids.count {
            let solidcolor = UIColor.solids[i]
            var colorfound = false
            for smsAcct in accts {
                if smsAcct.color == solidcolor {
                    colorfound = true
                    break
                }
            }
            if colorfound == false {
                newColor = solidcolor
                break
            }
        }
        return newColor
    }
}

extension SMSChatAccountModel {
    
    public func save(completion: @escaping () -> Void) {
        self.grdbRecord?.storeInGRDB(completion: completion)
    }
    
    public func save() {
        self.grdbRecord?.storeInGRDB()
    }
    
    public func remove(completion: @escaping () -> Void) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            self.grdbRecord?.grdbRemove(transaction: transaction)
        }, completion: completion)
    }
    
    public static func existingAccount(with phoneNumber:String) -> SMSChatAccountModel? {
        var account:SMSChatAccountModel?
        let sql = "SELECT * FROM \(SMSChatAccount.databaseTableName) WHERE phoneNumber == ?"
        let sqlRequest = SQLRequest<Void>(sql: sql, arguments: [phoneNumber], cached: true)
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try SMSChatAccount.fetchOne(transaction.database, sqlRequest) {
                    account = SMSChatAccountModel(account: record)
                }
            })
        } catch {
            DDLogDebug("error: \(error)")
            return nil
        }
        
        return account
    }
    
    public static func allAccounts() -> [SMSChatAccountModel] {
        
        var accounts:[SMSChatAccountModel] = []
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let records = try SMSChatAccount
                    .fetchAll(transaction.database)
                for record in records {
                    accounts.append(SMSChatAccountModel(account: record))
                }
            })
        } catch {
            DDLogDebug("SMSChatAccountModel.allConversations error: \(error)")
        }

        return accounts
    }
}

struct SMSChatAccount: GRDBRecord, TableRecord {
    var id: Int64?
    var uniqueId: String
    
    var phoneNumber: String?
    var twilioId: String?
    var displayName: String?
    var color: String?
    var modified: Date?

    public static var databaseTableName: String {
        "smsAccount"
    }
    
    public init(uniqueId:String, phoneNumber:String?, twilioId:String?, displayName:String?, color:UIColor?) {
        self.uniqueId = uniqueId
        self.phoneNumber = phoneNumber
        self.twilioId = twilioId
        self.displayName = displayName
        if let color = color {
            self.color = UIColor.StringFromUIColor(color: color)
        }
        self.modified = Date()
    }
    
    public init(uniqueId:String) {
        self.uniqueId = uniqueId
        self.modified = Date()
    }
    
    public static func allSMSAccounts() -> [SMSChatAccount] {
        var accounts:[SMSChatAccount] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                accounts = try SMSChatAccount
                    .fetchAll(transaction.database)
            })
        } catch {
            DDLogError("error: allSMSAccounts \(error)")
        }
        
        return accounts
    }
}
