//
//  SMSChatConversation.swift
//  Glacier
//
//  Created by andyfriedman on 8/22/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import TwilioConversationsClient
import GRDB

@objc open class SMSChatConversationModel: GRDBModel {
    var grdbRecord:SMSChatConversation?
    
    private var contactAvatar: UIImage?
    public var avatar: UIImage? {
        get {
            if contactAvatar == nil, let avData = grdbRecord?.avatarData {
                contactAvatar = UIImage(data: avData)
            }
            
            return contactAvatar
        }
        set {
            contactAvatar = newValue
#if !TARGET_IS_EXTENSION
            grdbRecord?.avatarData = newValue?.jpegData(dataSize: .unlimited)
#endif
        }
    }
    
    @objc public convenience init(remoteNumber:String, localNumber:String, accountId:String) {
        self.init()
        var grec = SMSChatConversation(uniqueId: self.uniqueId)
        grec.remoteNumber = remoteNumber
        grec.localNumber = localNumber
        grec.smsAccountId = accountId
        grec.twilioId = self.uniqueId //?
        self.grdbRecord = grec
    }
    
    convenience init(conversation:SMSChatConversation) {
        self.init(uniqueId: conversation.uniqueId)
        self.grdbRecord = conversation
    }
    
    @objc public func getLatestMessageDate() -> Date?{
        return self.grdbRecord?.latestMessageDate
    }
    
    @objc public func getPreferredName() -> String?{
        return self.grdbRecord?.preferredName
    }
    
    @objc public func getLocalAcct() -> String? {
        let localNum = self.grdbRecord?.localNumber
        
        if let num = localNum, let smsacct = SMSChatAccountModel.existingAccount(with: num), let displayName = smsacct.grdbRecord?.displayName {
            return displayName
        }
        return localNum
    }
}

extension SMSChatConversationModel {
    
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
    
    public func refetch() -> SMSChatConversationModel? {
        var conversation:SMSChatConversationModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let uid = self.grdbRecord?.uniqueId, let record = try SMSChatConversation
                    .filter(Column("uniqueId") == uid)
                    .fetchOne(transaction.database) {
                    conversation = SMSChatConversationModel(conversation: record)
                }
            })
        } catch {
            DDLogError("error: refetch \(error)")
        }
        
        return conversation
    }

#if !TARGET_IS_EXTENSION
    func lastMessage(completion: @escaping (_ msg: SMSChatMessageModel?) -> ()) //-> SMSMessage?
    {
        //let sql = "SELECT * FROM \(CodableSMSMessage.databaseTableName) WHERE conversationId == ? ORDER BY messageDate DESC LIMIT 1"
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try SMSChatMessage
                    .filter(Column("conversationId") == self.uniqueId)
                    .order(Column("messageDate").desc)
                    .fetchOne(transaction.database) {
                    let message = SMSChatMessageModel(message: record)
                    completion(message)
                } else {
                    completion(nil)
                }
            })
        } catch {
            completion(nil)
            DDLogError("error: lastMessage \(error)")
        }
    }
#endif
    
    public static func countConversations(_ uniqueId: String) -> Int {
        var count = 0
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                count = try SMSChatConversation
                    .filter(Column("smsAccountId") == uniqueId)
                    .fetchCount(transaction.database)
            })
        } catch {
            DDLogDebug("error: \(error)")
        }
        
        return count
    }
    
    public static func countMessages(_ convUniqueId: String) -> Int {
        var count = 0
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                count = try SMSChatConversation
                    .filter(Column("conversationId") == convUniqueId)
                    .fetchCount(transaction.database)
            })
        } catch {
            DDLogDebug("error: \(error)")
        }
        
        return count
    }
    
    public static func conversationsFor(accountId: String) -> [SMSChatConversationModel] {
        var conversations:[SMSChatConversationModel] = []
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let records = try SMSChatConversation
                    .filter(Column("smsAccountId") == accountId)
                    .fetchAll(transaction.database)
                for record in records {
                    conversations.append(SMSChatConversationModel(conversation: record))
                }
            })
        } catch {
            DDLogDebug("error: \(error)")
        }
        
        return conversations
    }
    
    public static func allConversations() -> [SMSChatConversationModel] {
        
        var conversations:[SMSChatConversationModel] = []
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let records = try SMSChatConversation
                    .fetchAll(transaction.database)
                for record in records {
                    conversations.append(SMSChatConversationModel(conversation: record))
                }
            })
        } catch {
            DDLogDebug("SMSChatConversationModel.allConversations error: \(error)")
        }

        return conversations
    }
    
    @objc public static func existingConversation(localPhone:String, remotePhone:String) -> SMSChatConversationModel? {
        var conversation:SMSChatConversationModel?
        // can we do a like here?
        //Player.filter(emailColumn.like("%@example.com"))
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try SMSChatConversation
                    .filter(Column("localNumber") == localPhone && Column("remoteNumber").like("%\(remotePhone)"))// == remotePhone)
                    .fetchOne(transaction.database) {
                    conversation = SMSChatConversationModel(conversation: record)
                }
            })
        } catch {
            DDLogDebug("error: \(error)")
            return nil
        }
        
        return conversation
    }
    
    @objc public static func existingConversation(with twilioId:String) -> SMSChatConversationModel? {
        var conversation:SMSChatConversationModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try SMSChatConversation
                    .filter(Column("twilioId") == twilioId)
                    .fetchOne(transaction.database) {
                    conversation = SMSChatConversationModel(conversation: record)
                }
            })
        } catch {
            DDLogDebug("error: \(error)")
            return nil
        }
        
        return conversation
    }
    
    public static func getConversation(with uniqueId:String) -> SMSChatConversationModel? {
        var conversation:SMSChatConversationModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try SMSChatConversation
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database) {
                    conversation = SMSChatConversationModel(conversation: record)
                }
            })
        } catch {
            DDLogDebug("error: \(error)")
            return nil
        }
        
        return conversation
    }
}

struct SMSChatConversation: GRDBRecord, TableRecord {
    var id: Int64?
    var uniqueId: String
    
    var smsAccountId: String?
    var firstName: String?
    var lastName: String?
    var preferredName: String?
    var avatarData: Data?
    var remoteNumber: String?
    var localNumber: String?
    var latestMessage: String?
    var latestMessageId: String?
    var latestMessageDate = Date.distantPast
    var isRead = false
    var isNew = false
    var twilioId:String?
    var modified: Date?

    public static var databaseTableName: String {
        "SMSConversation"
    }
    
    public init(uniqueId:String, smsAccountId:String?, firstName:String?, lastName:String?, preferredName:String?, avatarData:Data?, remoteNumber:String?, localNumber:String?, latestMessage:String?, latestMessageId:String?, latestMessageDate:Date?, isRead:Bool?, isNew:Bool?, twilioId:String?) {
        //self.id = conversation.grdbId?.int64Value
        self.uniqueId = uniqueId
        self.smsAccountId = smsAccountId
        self.firstName = firstName
        self.lastName = lastName
        self.preferredName = preferredName
        self.avatarData = avatarData
        self.remoteNumber = remoteNumber
        self.localNumber = localNumber
        self.latestMessage = latestMessage
        self.latestMessageId = latestMessageId
        if let latestDate = latestMessageDate {
            self.latestMessageDate = latestDate
        }
        if let isread = isRead {
            self.isRead = isread
        }
        if let isnew = isNew {
            self.isNew = isnew
        }
        self.twilioId = twilioId
        self.modified = Date()
    }
    
    public init(uniqueId:String) {
        self.uniqueId = uniqueId
        self.modified = Date()
    }
}

extension SMSChatConversation: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(uniqueId)
    }

    public static func == (lhs: SMSChatConversation, rhs: SMSChatConversation) -> Bool {
        lhs.uniqueId == rhs.uniqueId
    }
}

public extension UIColor {
    convenience init(red: Int, green: Int, blue: Int) {
        assert(red >= 0 && red <= 255, "Invalid red component")
        assert(green >= 0 && green <= 255, "Invalid green component")
        assert(blue >= 0 && blue <= 255, "Invalid blue component")

        self.init(red: CGFloat(red) / 255.0, green: CGFloat(green) / 255.0, blue: CGFloat(blue) / 255.0, alpha: 1.0)
    }

    convenience init(rgb: Int) {
        self.init(
            red: (rgb >> 16) & 0xFF,
            green: (rgb >> 8) & 0xFF,
            blue: rgb & 0xFF
        )
    } //UIColor(rgb: 0xFFFFFF)
    
    /*
     #FE6550 red
     #FE8747 orange
     #34C986 green
     #3352C6 blue UIColor(rgb: 0x3352C6)
     #472CB6 violet (dark)
     #8228ED purple
     */
    
    static let solids = [UIColor(rgb: 0x34C986), UIColor(rgb: 0xFE8747), UIColor(rgb: 0x8228ED), UIColor(rgb: 0xFE6550), UIColor(rgb: 0x3352C6), UIColor(rgb: 0x472CB6)]
    
    static func randomColor () -> UIColor {
        return UIColor(
            red: CGFloat.random(in: 0...1),
            green: CGFloat.random(in: 0...1),
            blue: CGFloat.random(in: 0...1),
            alpha: 1.0)
    }
    
    static func randomPrimaryColor () -> UIColor {
        let randomInt = Int.random(in: 0..<7)
        return solids[randomInt]
    }
    
    static func StringFromUIColor(color: UIColor) -> String {
        var colorString = ""
        if let components = color.cgColor.components {
            colorString = "\(components[0]), \(components[1]), \(components[2]), \(components[3])"
        }
        return colorString
    }
        
    static func UIColorFromString(string: String) -> UIColor {
        let components = string.components(separatedBy:", ")
        return UIColor(red: CGFloat((components[0] as NSString).floatValue),
                    green: CGFloat((components[1] as NSString).floatValue),
                    blue: CGFloat((components[2] as NSString).floatValue),
                    alpha: CGFloat((components[3] as NSString).floatValue))
    }
}
