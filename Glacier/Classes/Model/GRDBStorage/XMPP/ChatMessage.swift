//
//  ChatMessage.swift
//  Glacier
//
//  Created by andyfriedman on 9/11/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import GRDB
import DifferenceKit
import MessageKit
import CocoaLumberjack
import XMPPFramework

enum ChatMessageType: Int {
    case download = 800
    case incoming = 801
    case outgoing = 802
}

@objc open class ChatMessageModel: GRDBModel {
    
    var grdbRecord:ChatMessage?
    static var disableHTMLDownload = false
    
    convenience init(message:ChatMessage) {
        self.init(uniqueId: message.uniqueId)
        self.grdbRecord = message
    }
    
    public convenience override init() {
        let chatMsg = ChatMessage()
        self.init(message:chatMsg)
    }
}

extension ChatMessageModel: DownloadMessageProtocol {
    public func downloads() -> [DownloadMessage] {
        var downloads: [DownloadMessage] = []
#if !TARGET_IS_EXTENSION
        for url in self.downloadableURLs {
            let download = ChatDownloadMessage.download(parentMessage: self, url: url, uniqueId: nil)
            downloads.append(download)
        }
#endif
        return downloads
    }
    
    public func hasExistingDownloads() -> Bool {
        guard self.isMessageIncomingOrDifferentDevice else {
            return false
        }
        
        return self.grdbRecord?.url != nil
    }
}

extension ChatMessageModel:MessageProtocol {
    
    public func copyMessage() -> MessageProtocol? {
        guard let grec = self.grdbRecord else { return nil }
        if self is OutgoingChatMessage {
            let outtie = OutgoingChatMessage(message: grec)
            return outtie
        } else if self is IncomingChatMessage {
            let innie = IncomingChatMessage(message: grec)
            return innie
        }
        
        return ChatMessageModel(message: grec)
    }
    
    public var dbId: NSNumber? {
        get {
            return NSNumber(value: (self.grdbRecord?.id)!)
        }
        set {
            self.grdbRecord?.id = newValue?.int64Value
        }
    }
    
    public var uid: String {
        return self.uniqueId
    }
    
    public var messageKey: String {
        return self.uniqueId
    }
    
    public var messageCollection: String {
        return ChatMessageModel.collection()
    }
    
    public var threadId: String {
        return self.grdbRecord!.buddyUniqueId
    }
    
    public var threadCollection: String {
        return ChatBuddyModel.collection()
    }
    
    public var senderId: String? {
        get {
            return self.grdbRecord?.msgSenderId
        }
        set {
            self.grdbRecord?.msgSenderId = newValue ?? ""
        }
    }
    
    public var senderDisplayName: String? {
        get {
            return self.grdbRecord?.msgSenderDisplayName
        }
        set {
            self.grdbRecord?.msgSenderDisplayName = newValue ?? ""
        }
    }
    
    public var isMessageIncoming: Bool {
        return self.grdbRecord?.type == ChatMessageType.incoming.rawValue
    }
    
    public var isMessageIncomingOrDifferentDevice: Bool {
        if (self.isMessageIncoming) {
            return true
        } else if let outter = self.grdbRecord?.outgoingFromDifferentDevice, outter == true {
            return true
        }
        
        return false
    }
    
    public var isSystemUpdate: Bool {
        return self.grdbRecord?.systemUpdate ?? false
    }
    
    public var isMarkable: Bool {
        return self.grdbRecord?.markable ?? false
    }
    
    public var messageMediaItemKey: String? {
        get {
            return self.grdbRecord?.mediaItemUniqueId
        }
        set(messageMediaItemKey) {
            self.grdbRecord?.mediaItemUniqueId = messageMediaItemKey
        }
    }
    
    public var transferProgress: NSNumber? {
        get {
            return NSNumber(value: self.grdbRecord!.transferProgress ?? 0)
        }
        set {
            self.grdbRecord?.transferProgress = newValue?.doubleValue
        }
    }
    
    public var mediaType: NSNumber? {
        get {
            return NSNumber(value: self.grdbRecord!.mediaType)
        }
        set {
            self.grdbRecord?.mediaType = newValue?.intValue ?? -1
        }
    }
    
    public var url: String? {
        get {
            return self.grdbRecord?.url
        }
        set {
            self.grdbRecord?.url = newValue
        }
    }
    
    public var messageError: NSError? {
        get {
            if let err = self.grdbRecord?.error {
                return NSError(domain: err.errDomain, code: err.errCode, userInfo: [NSLocalizedDescriptionKey : err.errDescription ?? ""])
            }
            return nil
        }
        set(messageError) {
            if let err = messageError  {
                let nsError = err as NSError
                let gerr = GlacierError.init(domain: nsError.domain, code: nsError.code, description: nsError.description)
                self.grdbRecord?.error = gerr
            } else {
                self.grdbRecord?.error = nil
            }
        }
    }
    
    public var messageSecurity: OTRMessageTransportSecurity {
        get {
            if let msgsec = self.grdbRecord?.messageSecurity, let transsec = OTRMessageTransportSecurity(rawValue: UInt(msgsec)) {
                return transsec
            }
            return .plaintext
        }
        set {
            self.grdbRecord?.messageSecurity = Int(newValue.rawValue)
        }
    }
    
    public var omemoDeviceKey: String? {
        get {
            return self.grdbRecord?.omemoDeviceKey
        }
        set {
            self.grdbRecord?.omemoDeviceKey = newValue
        }
    }
    
    public var messageSecurityInfo: OTRMessageEncryptionInfo {
        return OTRMessageEncryptionInfo(messageSecurity: self.messageSecurity)
    }
    
    public var remoteMessageId: String? {
        return self.grdbRecord?.xmppId
    }
    
    public var isMessageRead: Bool {
        return self.grdbRecord?.read ?? false
    }
    
    public var messageModified: Date {
        get {
            return self.grdbRecord?.modified ?? Date.distantPast
        }
        set {
            self.grdbRecord?.modified = newValue
        }
    }
    
    public var messageDate: Date {
        get {
            return self.grdbRecord?.date ?? Date.distantPast
        }
        set {
            self.grdbRecord?.date = newValue
        }
    }
    
    public var messageReadDate: Date? {
        return self.grdbRecord?.readDate
    }
    
    public var messageText: String? {
        get {
            return self.grdbRecord?.text
        }
        set {
            self.grdbRecord?.text = newValue
        }
    }
    
    public var messageOriginalText: String? {
        get {
            return self.grdbRecord?.originalText
        }
        set {
            self.grdbRecord?.originalText = newValue
        }
    }
    
    public var messageExpires: String? {
        get {
            return self.grdbRecord?.expires
        }
        set {
            self.grdbRecord?.expires = newValue
        }
    }
    
    public var isMessageSent: Bool {
        return self.grdbRecord?.dateSent != nil
    }
    
    public var isMessageDelivered: Bool {
        if let delivered = self.grdbRecord?.delivered {
            return delivered
        }
        return false
    }
    
    public var isMessageDisplayed: Bool {
        if let displayed = self.grdbRecord?.displayed {
            return displayed
        }
        return false
    }
    
    public var originId: String? {
        return self.grdbRecord?.originId
    }
    
    public var stanzaId: String? {
        return self.grdbRecord?.stanzaId
    }
    
    public func buddy() -> ChatBuddyModel? {
        guard let uid = self.grdbRecord?.buddyUniqueId else {
            return nil
        }
        return ChatBuddyModel.getBuddy(uniqueId: uid)
    }
    
    public func touch() {
        self.touchBaseMessage()
    }
    
    public func finishProgress(with mediaItem:ChatMediaItemModel, completion: @escaping () -> Void) {
        if var grdbmsg = self.grdbRecord {
            mediaItem.removeFromCache()
            DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                let nowdate = Date()
                do {
                    grdbmsg.modified = nowdate
                    grdbmsg.transferProgress = 1.0
                    grdbmsg.error = nil
                    try grdbmsg.update(transaction.database, columns: [Column("modified"), Column("transferProgress"), Column("error")])
                } catch {
                    DDLogDebug("ChatMessage.finishProgress with error: \(error)")
                }
                
                if var mediaRec = mediaItem.grdbRecord {
                    do {
                        if mediaRec.id == nil {
                            if let mrec = try ChatMediaItem
                                .filter(Column("uniqueId") == mediaRec.uniqueId)
                                .fetchOne(transaction.database) {
                                mediaRec = mrec
                            }
                        }
                        mediaRec.transferProgress = 1.0
                        try mediaRec.update(transaction.database, columns: [Column("transferProgress")])
                    } catch {
                        DDLogDebug("ChatMessage.finishProgress for mediaRec with error: \(error)")
                    }
                }
                
                var threadRec:ChatThread?
                do {
                    if let buddy = try grdbmsg.buddy.fetchOne(transaction.database) {
                        let threadId = buddy.chatThreadId
                        threadRec = try ChatThread
                            .filter(Column("id") == threadId)
                            .fetchOne(transaction.database)
                        if threadRec == nil {
                            threadRec = try ChatThread
                                .filter(Column("uniqueId") == buddy.uniqueId)
                                .fetchOne(transaction.database)
                        }
                        if var thread = threadRec {
                            thread.modified = nowdate
                            thread.save()
                        }
                    }
                } catch {
                    DDLogDebug("ChatMessageModel.finishProgress threadOwner with error: \(error)")
                }

            }, completion: completion)
        }
    }
    
    public func refetch() -> MessageProtocol? {
        self.refetchChatMessage()
    }
    
    public func duplicateMessage() -> MessageProtocol {
        let newMessage = ChatMessageModel()
        newMessage.grdbRecord?.text = self.grdbRecord?.text
        newMessage.grdbRecord?.originalText = self.grdbRecord?.originalText
        newMessage.grdbRecord?.expires = self.grdbRecord?.expires
        newMessage.grdbRecord?.error = self.grdbRecord?.error
        newMessage.grdbRecord?.mediaItemUniqueId = self.grdbRecord?.mediaItemUniqueId
        newMessage.grdbRecord?.messageSecurity = self.grdbRecord?.messageSecurity
        newMessage.grdbRecord?.chatBuddyId = self.grdbRecord?.chatBuddyId ?? -1
        return newMessage
    }
    
    public func xmppBuddy() -> ChatBuddyModel? {
        if let budId = self.grdbRecord?.buddyUniqueId {
            return ChatBuddyModel.getBuddy(uniqueId: budId)
        }
        
        return nil
    }
    
    public func xmppBuddy(_ transaction: GRDBReadTransaction) -> ChatBuddyModel? {
        if let budId = self.grdbRecord?.buddyUniqueId {
            return ChatBuddyModel.getBuddy(uniqueId: budId, transaction: transaction)
        }
        
        return nil
    }
    
    public func threadOwner() -> ChatThreadModel? {
        var threadModel:ChatThreadModel?
        do {
            
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                //get chat buddy and throiugh that chat thread. If chat buddy has messages, should also have thread
                
                if let buddy = try self.grdbRecord!.buddy.fetchOne(transaction.database) {
                    let threadId = buddy.chatThreadId
                    if let record = try ChatThread
                        .filter(Column("id") == threadId)
                        .fetchOne(transaction.database) {
                            threadModel = ChatThreadModel(thread: record)
                    } else if let record = try ChatThread
                        .filter(Column("uniqueId") == buddy.uniqueId)
                        .fetchOne(transaction.database) {
                            threadModel = ChatThreadModel(thread: record)
                    }
                }
            })
        } catch {
            DDLogDebug("ChatMessageModel.threadOwner with error: \(error)")
        }
        
        return threadModel
    }
    
    public func threadOwner(_ transaction:GRDBWriteTransaction) -> ChatThread? {
        var thread:ChatThread?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                //get chat buddy and throiugh that chat thread. If chat buddy has messages, should also have thread

                if let buddy = try self.grdbRecord!.buddy.fetchOne(transaction.database) {
                    let threadId = buddy.chatThreadId
                    if let record = try ChatThread
                        .filter(Column("id") == threadId)
                        .fetchOne(transaction.database) {
                            thread = record
                    } else if let record = try ChatThread
                        .filter(Column("uniqueId") == buddy.uniqueId)
                        .fetchOne(transaction.database) {
                            thread = record
                    }
                }
            })
        } catch {
            DDLogDebug("ChatMessageModel.threadOwner with error: \(error)")
        }

        return thread
    }
    
    @objc public func save() {
        self.grdbRecord?.storeInGRDB()
    }
    
    @objc public func save(completion: @escaping ()->Void ) {
        self.grdbRecord?.storeInGRDB(completion: completion)
    }
}

extension ChatMessageModel {
    var glacierError: GlacierError? {
        if let err = self.messageError  {
            let nsError = err as NSError
            let gerr = GlacierError.init(domain: nsError.domain, code: nsError.code, description: nsError.description)
            return gerr
        }
        return nil
    }
    
    public func save(withThread thread:ChatThreadModel?) {
        self.save(completion: {
            if self is IncomingChatMessage || self is OutgoingChatMessage {
                if let cthread = thread?.grdbRecord {
                    ChatThread.update(with: cthread, message: self)
                }
            }
        })
    }
}

extension ChatMessageModel {
    
    @objc public static func setHTMLDownload(_ allowed:Bool) {
        disableHTMLDownload = !allowed
    }
    
    @objc public static func getParentMessage(with parentObjectKey:String) -> ChatMessageModel? {
        var message:ChatMessageModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try ChatMessage
                    .filter(Column("uniqueId") == parentObjectKey)
                    .fetchOne(transaction.database) {
                    message = ChatMessageModel(message: record)
                }
            })
        } catch {
            DDLogDebug("error: \(error)")
            return nil
        }
        
        return message
    }
    
    @objc public static func markAllUnreadMessages(for threadId:String, completion: @escaping (_ updatedMessages: [ChatMessageModel]) -> ()) {
        //var markable:[ChatMessageModel] = []
        var messages:[ChatMessage] = []
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                let now = Date()
                
                let req = ChatMessage
                    .filter(Column("buddyUniqueId") == threadId)
                    .filter(Column("read") == false)
                //.filter(Column("type") == MessageType.incoming.rawValue)
                messages = try req.fetchAll(transaction.database)
                try req.updateAll(transaction.database, [Column("read").set(to: true), Column("readDate").set(to: now), Column("modified").set(to: now)])
                
                if var brecord = try ChatBuddy
                    .filter(Column("uniqueId") == threadId)
                    .fetchOne(transaction.database) {
                    brecord.modified = now
                    try brecord.update(transaction.database, columns: [Column("modified")])
                }
                
                if var xrecord = try ChatThread
                    .filter(Column("uniqueId") == threadId)
                    .fetchOne(transaction.database) {
                    xrecord.modified = now
                    try xrecord.update(transaction.database, columns: [Column("modified")])
                }
                
            } catch {
                DDLogDebug("error: \(error)")
                let sqliteVersion = String(cString: sqlite3_libversion()!)
                print("SQLite Version:", sqliteVersion)
            }
        }, completionQueue: DispatchQueue.global(), completion: {
            var markable:[ChatMessageModel] = []
            for msg in messages {
                if msg.markable {
                    markable.append(ChatMessageModel(message: msg))
                }
            }
            completion(markable)
        })
    }
    
    @objc public static func getUnreadMessages() -> [ChatMessageModel]{
        var msgs:[ChatMessageModel] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let records = try ChatMessage
                    .filter(Column("read") == false)
                    //.filter(Column("type") != ChatMessageType.outgoing.rawValue)
                    .fetchAll(transaction.database)
                for rec in records {
                    let msg = ChatMessageModel(message: rec) //} as? IncomingChatMessage {
                        msgs.append(msg)
                    //}
                }
            })
        } catch {
            DDLogDebug("error: \(error)")
        }
        
        return msgs
    }
    
    @objc public static func countAllUnreadMessages() -> UInt {
        var count = 0
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                count = try ChatMessage
                    .filter(Column("read") == false)
                    .filter(Column("type") != ChatMessageType.outgoing.rawValue)
                    .fetchCount(transaction.database)
            })
        } catch {
            DDLogDebug("error: \(error)")
        }
        
        return UInt(count)
    }
    
    @objc public func touchBaseMessage() {
        if var grdbmsg = self.grdbRecord {
            DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                let nowdate = Date()
                do {
                    grdbmsg.modified = nowdate
                    try grdbmsg.update(transaction.database, columns: [Column("modified")])
                } catch {
                    DDLogDebug("ChatMessage.touch with error: \(error)")
                }
            })
        }
    }
    
    public func refetchChatMessage() -> MessageProtocol? {
        var message:ChatMessageModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try ChatMessage
                    .filter(Column("uniqueId") == self.uniqueId)
                    .fetchOne(transaction.database) {
                    message = ChatMessageModel(message: record)
                }
            })
        } catch {
            DDLogError("error: lastMessage \(error)")
        }
        
        return message
    }
    
    @objc public static func deleteAllMessages(for accountId:String) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                let buddies = try ChatBuddy
                    .filter(Column("accountUniqueId") == accountId)
                    .fetchAll(transaction.database)
                
                for buddy in buddies {
                    try ChatMessage
                        .filter(Column("buddyUniqueId") == buddy.uniqueId)
                        .deleteAll(transaction.database)
                    
                    do {
                        var bud = buddy
                        bud.lastMessageId = nil
                        bud.modified = Date()
                        try bud.update(transaction.database, columns: [Column("lastMessageId"), Column("modified")])
                        
                        let chatThread = try ChatThread
                            .filter(Column("id") == buddy.chatThreadId)
                            .fetchOne(transaction.database)
                        if var thread = chatThread {
                            thread.lastMessageId = nil
                            thread.modified = Date()
                            try thread.update(transaction.database, columns: [Column("lastMessageId"), Column("modified")])
                        }
                    } catch {
                        DDLogDebug("ChatMessage.deleteAllMessages with error: \(error)")
                    }
                    
                    try ChatMediaItem
                        .filter(Column("parentObjectKey") == buddy.uniqueId)
                        .filter(Column("parentObjectCollection") == ChatBuddyModel.collection())
                        .deleteAll(transaction.database)
                }
            } catch {
                DDLogDebug("ChatMessage.deleteAllMessages: \(error)")
            }
        })
    }
    
    @objc public static func deleteAllMessagesForBuddy(_ buddyId:String, chatThreadId: Int64) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                try ChatThread
                    .filter(Column("id") == chatThreadId)
                    .deleteAll(transaction.database)
                
                try ChatMessage
                    .filter(Column("buddyUniqueId") == buddyId)
                    .deleteAll(transaction.database)
                
                do {
                    if var buddy = try ChatBuddy
                        .filter(Column("uniqueId") == buddyId)
                        .fetchOne(transaction.database) {
                        buddy.lastMessageId = nil
                        buddy.modified = Date()
                        try buddy.update(transaction.database, columns: [Column("lastMessageId"), Column("modified")])
                    }
                } catch {
                    DDLogDebug("ChatMessage.deleteAllMessagesForBuddy with error: \(error)")
                }
                try ChatMediaItem
                    .filter(Column("parentObjectKey") == buddyId)
                    .filter(Column("parentObjectCollection") == ChatBuddyModel.collection())
                    .deleteAll(transaction.database)
            } catch {
                DDLogDebug("ChatMessage.deleteAllMessagesForBuddy: \(error)")
            }
        })
    }
    
    @objc public static func getLastMessage(for threadId:String) -> ChatMessageModel? {
        //room lastMessageId and then get from here?
        //or juts order by date?
        var message:ChatMessageModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try ChatMessage
                    .filter(Column("buddyUniqueId") == threadId)
                    //.filter(Column("type") != MessageType.download.rawValue)
                    .order(Column("date").desc)
                    .fetchOne(transaction.database) {
                    message = ChatMessageModel(message: record)
                }
            })
        } catch {
            DDLogError("error: lastMessage \(error)")
        }
        
        return message
    }
    
    @objc public static func getMessage(with key:String) -> ChatMessageModel? {
        var message:ChatMessageModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try ChatMessage
                    .filter(Column("uniqueId") == key)
                    .fetchOne(transaction.database) {
                    message = ChatMessageModel(message: record)
                }
            })
        } catch {
            DDLogError("error: lastMessage \(error)")
        }
        
        return message
    }
    
    @objc public static func getMessage(elementId:String?, originId: String?, stanzaId:String?) -> ChatMessageModel? {
        guard let sqlargs = self.getSqlArgs(elementId: elementId, originId: originId, stanzaId: stanzaId) else { return nil }
        var message:ChatMessageModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let rec = try ChatMessage
                    .fetchOne(transaction.database, sql: sqlargs.sql, arguments: sqlargs.args) {
                    if rec.type == ChatMessageType.outgoing.rawValue {
                        message = OutgoingChatMessage(message: rec)
                    } else {
                        message = IncomingChatMessage(message: rec)
                    }
                }
            })
        } catch {
            DDLogError("error: getMessage \(error)")
        }
        
        return message
    }
    
    static func getSqlArgs(elementId:String?, originId: String?, stanzaId:String?) -> (sql:String, args:StatementArguments)? {
        var parameters: [String] = []
        var queryString = ""
        let addQuery: ((_ column: String, _ value: String?) -> Void) = { (column, value) in
            guard let value = value else { return }
            var stringStart = "WHERE"
            if parameters.count > 0 {
                stringStart = " OR"
            }
            queryString += "\(stringStart) \(column) = ?"
            parameters.append(value)
        }
        addQuery("xmppId", elementId)
        addQuery("originId", originId)
        addQuery("stanzaId", stanzaId)
        guard parameters.count > 0, queryString.count > 0 else {
            return nil
        }
        
        let sql = "SELECT * FROM ChatMessage " + queryString
        let args = StatementArguments(parameters)
        
        return (sql, args)
    }
    
    @objc public static func setDelivered(elementId:String?, originId: String?, stanzaId:String?) {
        
        guard let sqlargs = self.getSqlArgs(elementId: elementId, originId: originId, stanzaId: stanzaId) else {
            return
        }
        
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                if var chatMessage = try ChatMessage
                    .fetchOne(transaction.database, sql: sqlargs.sql, arguments: sqlargs.args) {
                    
                    guard chatMessage.type == ChatMessageType.outgoing.rawValue, chatMessage.delivered == false,
                        chatMessage.dateDelivered == nil else {
                        return
                    }
                    
                    do {
                        chatMessage.delivered = true
                        chatMessage.dateDelivered = Date()
                        chatMessage.modified = Date()
                        try chatMessage.update(transaction.database, columns: [Column("delivered"), Column("dateDelivered"), Column("modified")])
                    } catch {
                        DDLogDebug("ChatMessageModel.setDelivered with error: \(error)")
                    }
                }
            
            } catch {
                DDLogError("error: setDelivered \(error)")
            }
        })
    }
    
    @objc public static func setDisplayed(elementId:String?, originId: String?, stanzaId:String?) {
        
        guard let sqlargs = self.getSqlArgs(elementId: elementId, originId: originId, stanzaId: stanzaId) else {
            return
        }
        
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                if var chatMessage = try ChatMessage
                    .fetchOne(transaction.database, sql: sqlargs.sql, arguments: sqlargs.args) {
                    
                    guard chatMessage.type == ChatMessageType.outgoing.rawValue, chatMessage.displayed == false else {
                        return
                    }
                    
                    do {
                        chatMessage.displayed = true
                        chatMessage.dateDisplayed = Date()
                        chatMessage.modified = Date()
                        try chatMessage.update(transaction.database, columns: [Column("displayed"), Column("dateDisplayed"), Column("modified")])
                    } catch {
                        DDLogDebug("ChatMessageModel.setDisplayed with error: \(error)")
                    }
                }
            } catch {
                DDLogError("error: setDisplayed \(error)")
            }
        })
    }
    
    @objc public static func deleteMessage(with messageId:String, completion: @escaping ()->Void ) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                let msg = try ChatMessage
                    .filter(Column("uniqueId") == messageId)
                    .fetchOne(transaction.database)
                try ChatMessage
                    .filter(Column("uniqueId") == messageId)
                    .deleteAll(transaction.database)
                if var buddy = try ChatBuddy
                    .filter(Column("uniqueId") == msg?.buddyUniqueId)
                    .fetchOne(transaction.database) {
                    do {
                        if buddy.lastMessageId == msg?.uniqueId {
                            buddy.lastMessageId = nil
                            try buddy.update(transaction.database, columns: [Column("lastMessageId")])
                        }
                    } catch {
                        DDLogDebug("ChatMessage.deleteMessage with error: \(error)")
                    }
                }
            } catch {
                DDLogDebug("ChatMessage.deleteMessage: \(error)")
            }
        }, completion: {
            completion()
        })
    }
    
    @objc public static func deleteMessage(with messageId:String) {
        Self.deleteMessage(with: messageId, completion: {})
    }
    
    @objc public static func countParentMessages(_ threadId: String) -> Int {
        var count = 0
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                count = try ChatMessage
                    .filter(Column("buddyUniqueId") == threadId)
                    //.filter(Column("type") != MessageType.download.rawValue)
                    .fetchCount(transaction.database)
            })
        } catch {
            DDLogDebug("error: \(error)")
        }
        
        return count
    }
    
    @objc public static func countAllMessages() -> Int {
        var count = 0
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                count = try ChatMessage
                    .fetchCount(transaction.database)
            })
        } catch {
            DDLogDebug("error: \(error)")
        }
        
        return count
    }
}

struct ChatMessage: GRDBRecord, TableRecord {
    
    var id: Int64?
    var uniqueId: String
    var date: Date
    var readDate: Date?
    var text: String?
    var originalText: String?
    var expires: String?
    var xmppId: String
    var error: GlacierError?
    var systemUpdate = false
    var markable = false
    var mediaItemUniqueId: String?
    var messageMediaItemKey: String?
    var transferProgress: Double?
    var buddyUniqueId: String
    var originId: String?
    var stanzaId: String?
    var chatBuddyId: Int64
    var reactions: [ChatMessageReaction]?
    
    var reactionsCount: Int {
        guard let reactions = reactions else {
            return 0
        }
        let count = reactions.reduce(0) { $0 + $1.reactions.count }
        return count
    }
    
    var msgSenderId: String
    var msgSenderDisplayName: String
    
    //var messageSecurityInfo: Data?
    var messageSecurity: Int?
    var omemoDeviceKey: String?
    var modified: Date?
    
    var parentObjectKey: String?
    var parentObjectCollection: String?
    var url: String?
    var read = false //incoming
    var dateSent: Date?
    var dateAcked: Date?
    var dateDelivered: Date?
    var outgoingFromDifferentDevice = false
    var delivered = false
    var displayed = false //outgoing
    var dateDisplayed: Date?
    var type = ChatMessageType.incoming.rawValue
    var mediaType = -1

    public static var databaseTableName: String {
        "chatMessage"
    }
    
    public init() {
        self.uniqueId = UUID().uuidString
        self.chatBuddyId = -1
        self.buddyUniqueId = ""
        self.xmppId = UUID().uuidString
        self.date = Date()
        self.msgSenderId = ""
        self.msgSenderDisplayName = ""
    }
    
    public static func allChatMessages(for buddyId:String, limit:Int) -> [ChatMessage] {
        var messages:[ChatMessage] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                messages = try ChatMessage
                    .filter(Column("buddyUniqueId") == buddyId)
                    .order(Column("date").desc)
                    .limit(limit)
                    //.order(Column("date").asc)
                    .fetchAll(transaction.database)
                //return messages
            })
        } catch {
            DDLogError("error: allChatMessages \(error)")
        }
        
        //let messages:[ChatMessage] = []
        return messages
    }
    
    public static func getPlaceholder() -> ChatMessage {
        var newmsg = ChatMessage()
        newmsg.text = ""
        return newmsg
    }
    
    func save() {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            var msg = self
            do {
                try msg.save(transaction.database)
            } catch {
                DDLogDebug("ChatMessage.save with error: \(error)")
            }
        })
    }
    
    static func touch(_ uniqueId:String) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            let nowdate = Date()
            do {
                if var msg = try ChatMessage
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database) {
                    msg.modified = nowdate
                    try msg.update(transaction.database, columns: [Column("modified")])
                }
            } catch {
                DDLogDebug("ChatMessage.touch with error: \(error)")
            }
        })
    }
}

extension ChatMessage: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(uniqueId)
    }

    public static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.uniqueId == rhs.uniqueId
    }
}

extension ChatMessage {
    static let buddy = belongsTo(ChatBuddy.self)
    var buddy: QueryInterfaceRequest<ChatBuddy> {
        request(for: ChatMessage.buddy)
    }
    
    //static let chatThread = hasOne(ChatThread.self, through: buddy, using: ChatBuddy.thread)
    //var chatThread: QueryInterfaceRequest<ChatThread> {
    //    request(for: ChatMessage.chatThread)
    //}
}

extension ChatMessage: MessageType {
    /// The sender of the message.
    /// public var sender: SenderType {
    public var sender: SenderType {
        get {
            return ChatUser(senderId: self.msgSenderId, displayName: self.msgSenderDisplayName)
        }
    }

    /// The unique identifier for the message.
    public var messageId: String {
        get {return uniqueId}
    }

    /// The date the message was sent.
    public var sentDate: Date {
        get {return self.date}
    }

    /// The kind of message and its underlying kind.
    public var kind: MessageKind {
        get {
#if !TARGET_IS_EXTENSION
            if let mediaId = self.mediaItemUniqueId {
                if let item = ChatMediaItemModel.getMediaItem(with: mediaId), let mediaRec = item.grdbRecord, mediaRec.mediaType >= 0 {
                    if mediaRec.mediaType == ChatMediaType.imageItem.rawValue, let imageRec = item as? ChatImageItem {
                        return MessageKind.photo(imageRec)
                    } else if mediaRec.mediaType == ChatMediaType.videoItem.rawValue, let videoRec = item as? ChatVideoItem {
                        return MessageKind.video(videoRec)
                    } else if mediaRec.mediaType == ChatMediaType.audioItem.rawValue, let audioRec = item as? ChatAudioItem {
                        return MessageKind.audio(audioRec)
                    } else if mediaRec.mediaType == ChatMediaType.htmlItem.rawValue, let htmlRec = item as? ChatHTMLItem, ChatMessageModel.disableHTMLDownload == false {
                        //return MessageKind.linkPreview(htmlRec)
                        return MessageKind.photo(htmlRec)
                    } else if mediaRec.mediaType == ChatMediaType.fileItem.rawValue, let fileRec = item as? ChatFileItem {
                        return MessageKind.photo(fileRec)
                    }
                }
            }
#endif
            //print("***** printing url \(String(describing: self.url)) and text \(String(describing: self.text))")
            let txt = self.text ?? " "
            if txt.starts(with: "geo:") {
                let geoless = txt.replacingOccurrences(of: "geo:", with: "", options: .regularExpression)
                if geoless.contains(",") {
                    let latlon = geoless.components(separatedBy: ",")
                    let latd = (latlon.first! as NSString).doubleValue
                    let lond = (latlon.last! as NSString).doubleValue
                    let clloc = CLLocation(latitude: latd, longitude: lond)
                    let locItem = ChatLocationItem(location: clloc)
                    return MessageKind.location(locItem)
                }
            } else if txt.starts(with: "aesgcm:") {
#if !TARGET_IS_EXTENSION
                if let item = ChatMediaItemModel.incomingItemWith(filename: txt, mimeType: nil), let mediaRec = item.grdbRecord, mediaRec.mediaType >= 0 {
                    if mediaRec.mediaType == ChatMediaType.imageItem.rawValue, let imageRec = item as? ChatImageItem {
                        return MessageKind.photo(imageRec)
                    } else if mediaRec.mediaType == ChatMediaType.videoItem.rawValue, let videoRec = item as? ChatVideoItem {
                        return MessageKind.video(videoRec)
                    } else if mediaRec.mediaType == ChatMediaType.audioItem.rawValue, let audioRec = item as? ChatAudioItem {
                        return MessageKind.audio(audioRec)
                    } else if mediaRec.mediaType == ChatMediaType.htmlItem.rawValue, let htmlRec = item as? ChatHTMLItem, ChatRoomMessageModel.disableHTMLDownload == false {
                        //return MessageKind.linkPreview(htmlRec)
                        return MessageKind.photo(htmlRec)
                    } else if mediaRec.mediaType == ChatMediaType.fileItem.rawValue, let fileRec = item as? ChatFileItem {
                        return MessageKind.photo(fileRec)
                    }
                }
#endif
            } else if txt.lowercased().starts(with: "https:"), ChatRoomMessageModel.disableHTMLDownload == false, let url = URL(string: txt) {
#if !TARGET_IS_EXTENSION
                Task {
                    let isLinkReachable = await LinkReachabilityChecker.shared.isReachable(url.absoluteString)
                    return await MainActor.run {
                        guard isLinkReachable else {
                            return MessageKind.text(txt)
                        }
                        let htmlRec = ChatHTMLItem.init(filename: txt, mimetype: nil, isIncoming: true)
                        return MessageKind.photo(htmlRec)
                    }
                }
#endif
            }
            
            return MessageKind.text(txt)
        }
    }
}

/*extension ChatMessage: Differentiable {
    var differenceIdentifier: Int64 {
        return self.id!
    }
    
    func isContentEqual(to source: ChatMessage) -> Bool {
        return uniqueId == source.uniqueId && modified == source.modified
    }
}*/

struct ChatUser: SenderType, Equatable {
  var senderId: String
  var displayName: String
}

struct ChatLocationItem: LocationItem {
    public var location: CLLocation
    public var size: CGSize

    init(location: CLLocation) {
        self.location = location
        size = CGSize(width: 200, height: 200)
    }
}

public extension ChatMessageModel {
    @objc var downloadableNSURLs: [NSURL] {
        return self.downloadableURLs as [NSURL]
    }
}
