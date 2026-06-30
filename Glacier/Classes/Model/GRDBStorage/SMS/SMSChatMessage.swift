//
//  SMSChatMessage.swift
//  Glacier
//
//  Created by andyfriedman on 8/22/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import GRDB
import DifferenceKit
import MessageKit

open class SMSChatMessageModel: GRDBModel {
    var grdbRecord:SMSChatMessage?
    var mediaItem: MediaItem?
    @objc public convenience init(conversationId:String, senderId:String, senderDisplayName:String, text:String?, date:Date?) {
        self.init()
        self.grdbRecord = SMSChatMessage(uniqueId: self.uniqueId, conversationId: conversationId, twilioSid: nil, messageDate: date, isRead: false, isIncoming: false, mediaItemUniqueId: nil, msgText: text, msgSenderId: senderId, msgSenderDisplayName: senderDisplayName, modified: nil)
    }
    
    @objc public convenience init(conversationId:String, senderId:String, senderDisplayName:String, text:String?, twilioSid: String?, date:Date?) {
        self.init()
        self.grdbRecord = SMSChatMessage(uniqueId: self.uniqueId, conversationId: conversationId, twilioSid: twilioSid, messageDate: date, isRead: false, isIncoming: false, mediaItemUniqueId: nil, msgText: text, msgSenderId: senderId, msgSenderDisplayName: senderDisplayName, modified: nil)
    }
    
    convenience init(message: SMSChatMessage) {
        self.init(uniqueId: message.uniqueId)
        self.grdbRecord = message
    }
}

/*extension SMSChatMessage: MessageType {
    /// The sender of the message.
    public var sender: SenderType {
        get {
            return SMSChatUser(senderId: self.grdbRecord!.msgSenderId!, displayName: self.grdbRecord!.msgSenderDisplayName!)
        }
    }

    /// The unique identifier for the message.
    public var messageId: String {
        get {return uniqueId}
    }

    /// The date the message was sent.
    public var sentDate: Date {
        get {return self.grdbRecord!.messageDate}
    }

    /// The kind of message and its underlying kind.
    public var kind: MessageKind {
        get {
            if let item = self.mediaItem {
                return MessageKind.photo(item)
            } else if self.grdbRecord?.mediaItemUniqueId != nil, let item = SMSChatMediaItem.mediaItem(for: self) {
                self.mediaItem = item
                return MessageKind.photo(item)
            }
            return MessageKind.text(self.grdbRecord!.msgText!)
        }
    }
}*/

extension SMSChatMessageModel {
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
    
    @objc public func isMediaMessage() -> Bool {
        if self.grdbRecord?.mediaItemUniqueId != nil {
            return true
        }
        return false
    }
    
    @objc public func isIncoming() -> Bool {
        if self.grdbRecord?.isIncoming == true {
            return true
        }
        return false
    }
    
    public func conversationOwner() -> SMSChatConversationModel? {
        var conversation:SMSChatConversationModel?
        if let cid = grdbRecord?.conversationId {
            do {
                try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                    if let record = try SMSChatConversation
                        .filter(Column("uniqueId") == cid)
                        .fetchOne(transaction.database) {
                        conversation = SMSChatConversationModel(conversation: record)
                    }
                })
            } catch {
                DDLogDebug("error: \(error)")
                return nil
            }
        }
        
        return conversation
    }
    
    @objc public func touch() {
        if let rec = self.grdbRecord {
            rec.touch()
        }
    }
    
    public static func allMessages() -> [SMSChatMessageModel] {
        var messages:[SMSChatMessageModel] = []
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let recs = try SMSChatMessage
                    .fetchAll(transaction.database)
                for rec in recs {
                    messages.append(SMSChatMessageModel(message: rec))
                }
            })
        } catch {
            DDLogDebug("SMSChatMessageModel.allMessages error: \(error)")
        }

        return messages
    }
    
    public func refetch() -> SMSChatMessageModel? {
        var message:SMSChatMessageModel?
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try SMSChatMessage
                    .filter(Column("uniqueId") == self.uniqueId)
                    .fetchOne(transaction.database) {
                    message = SMSChatMessageModel(message: record)
                }
            })
        } catch {
            DDLogDebug("error: \(error)")
            return nil
        }
        
        return message
    }
}

struct SMSChatMessage: GRDBRecord, TableRecord {
    var id: Int64?
    var uniqueId: String
    //var value: SMSMessage
    
    var conversationId: String?
    var twilioSid: String?
    var messageDate = Date()
    var isRead = false
    var isIncoming = false
    var mediaItemUniqueId: String?
    var msgText: String?
    var msgSenderId: String?
    var msgSenderDisplayName: String?
    var transferProgress: Double?
    var modified: Date?
    
    public static var databaseTableName: String {
        return "SMSMessage"
    }
    
    public init(uniqueId:String, conversationId:String?, twilioSid:String?, messageDate:Date?, isRead:Bool?, isIncoming:Bool?, mediaItemUniqueId:String?, msgText:String?, msgSenderId:String?, msgSenderDisplayName:String?, modified:Date?) {
        self.uniqueId = uniqueId
        self.conversationId = conversationId
        self.twilioSid = twilioSid
        if let mdate = messageDate {
            self.messageDate = mdate
        }
        if let isread = isRead {
            self.isRead = isread
        }
        if let isincoming = isIncoming {
            self.isIncoming = isincoming
        }
        self.mediaItemUniqueId = mediaItemUniqueId
        self.msgText = msgText
        self.msgSenderId = msgSenderId
        self.msgSenderDisplayName = msgSenderDisplayName
        self.modified = modified
    }
    
    public init(uniqueId:String) {
        self.uniqueId = uniqueId
        self.modified = Date()
    }

    func touch() {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            let nowdate = Date()
            var smsmsg = self
            do {
                smsmsg.modified = nowdate
                try smsmsg.update(transaction.database, columns: [Column("modified")])
            } catch {
                DDLogDebug("SMSChatMessage.touch with error: \(error)")
            }
        })
    }
    
    static func touch(_ smsUniqueId:String) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            let nowdate = Date()
            do {
                if var smsmsg = try SMSChatMessage
                    .filter(Column("uniqueId") == smsUniqueId)
                    .fetchOne(transaction.database) {
                    smsmsg.modified = nowdate
                    try smsmsg.update(transaction.database, columns: [Column("modified")])
                }
            } catch {
                DDLogDebug("SMSChatMessage.touch with error: \(error)")
            }
        })
    }
}

extension SMSChatMessage: MessageType {
    /// The sender of the message.
    public var sender: SenderType {
        get {
            return SMSChatUser(senderId: self.msgSenderId!, displayName: self.msgSenderDisplayName!)
        }
    }

    /// The unique identifier for the message.
    public var messageId: String {
        get {return uniqueId}
    }

    /// The date the message was sent.
    public var sentDate: Date {
        get {return self.messageDate}
    }

    /// The kind of message and its underlying kind.
    public var kind: MessageKind {
        get {
            if let mediaId = self.mediaItemUniqueId, let item = SMSChatMediaItemModel.mediaItem(for: mediaId) {
                return MessageKind.photo(item)
            }
            return MessageKind.text(self.msgText!)
        }
    }
}

extension SMSChatMessage: Differentiable {
    func isContentEqual(to source: SMSChatMessage) -> Bool {
        return uniqueId == source.uniqueId && modified == source.modified
    }
}

struct SMSChatUser: SenderType, Equatable {
  var senderId: String
  var displayName: String
}

