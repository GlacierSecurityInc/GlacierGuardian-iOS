//
//  ChatThread.swift
//  Glacier
//
//  Created by andyfriedman on 9/12/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import GRDB

@objc public enum ThreadStatus: Int {
    case unknown = 0
    case available = 1
    case away = 2
    case donotdisturb = 3
    case extendedaway = 4
    case offline = 5
}

@objc open class ChatThreadModel: GRDBModel {
    var grdbRecord:ChatThread?
    
    convenience init(thread:ChatThread) {
        self.init(uniqueId: thread.uniqueId)
        self.grdbRecord = thread
    }
    
    @objc convenience init(accountId:Int64, isGroup: Bool) {
        self.init()
        var thread = ChatThread(uniqueId: self.uniqueId)
        thread.modified = Date()
        thread.accountUniqueId = accountId
        thread.isGroupThread = isGroup
        self.grdbRecord = thread
    }
    
    @objc convenience init(accountId:Int64, uniqueId:String, isGroup: Bool) {
        self.init(uniqueId:uniqueId)
        var thread = ChatThread(uniqueId: self.uniqueId)
        thread.modified = Date()
        thread.accountUniqueId = accountId
        thread.isGroupThread = isGroup
        self.grdbRecord = thread
    }
    
    @objc public var lastMessageIdentifier: String? {
        get {
            return self.grdbRecord?.lastMessageId
        }
        set {
            self.grdbRecord?.lastMessageId = newValue
        }
    }
    
    @objc public var threadAccountIdentifier: Int64 {
        get {
            return self.grdbRecord!.accountUniqueId
        }
        set {
            self.grdbRecord?.accountUniqueId = newValue
        }
    }
    
    @objc public var threadIdentifier: Int64 {
        get {
            return self.grdbRecord!.id ?? 0
        }
    }
    
    @objc public var threadName: String {
        guard let trec = self.grdbRecord else { return "" }
        
        if isGroupThread() {
            if let room = ChatRoom.roomFromThread(trec) {
                let roomModel = ChatRoomModel(room: room)
                return roomModel.threadName
            }
        } else {
            if let bud = ChatBuddy.buddyFromThread(trec) {
                let budModel = ChatBuddyModel(buddy: bud)
                return budModel.threadName
            }
        }
        return ""
    }
    
    @objc public var threadDate: Date {
        get {
            return self.grdbRecord!.messageDate
        }
        set {
            self.grdbRecord?.messageDate = newValue
        }
    }
    
    @objc public func isGroupThread() -> Bool {
        return self.grdbRecord!.isGroupThread
    }
    
    @objc public func saveThread() {
        self.grdbRecord?.modified = Date()
        self.grdbRecord?.storeInGRDB()
    }
    
    @objc public func saveThread(completion: @escaping () -> Void) {
        self.grdbRecord?.modified = Date()
        self.grdbRecord?.storeInGRDB(completion: completion)
    }
    
    public func saveThread(transaction: GRDBWriteTransaction) throws {
        self.grdbRecord?.modified = Date()
        self.grdbRecord?.grdbSave(transaction: transaction)
    }
    
    func getChatAccount() -> ChatAccountModel? {
        return self.grdbRecord?.getChatAccount()
    }
    
    @objc public static func getChatThread(uniqueId: String) -> ChatThreadModel? {
        var xthread:ChatThreadModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let thread = try ChatThread
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database) {
                    xthread = ChatThreadModel(thread: thread)
                }
            })
        } catch {
            DDLogDebug("ChatThreadModel.getChatThread with uniqueId error: \(error)")
        }

        return xthread
    }
}


public struct ChatThread: GRDBRecord, TableRecord {
//public protocol ChatThread: AnyObject {
    public var id: Int64?
    public var uniqueId: String
    
    var accountUniqueId: Int64
    var lastMessageId: String?
    var messageDate = Date.distantPast
    var isGroupThread = false
    var modified: Date?
    var isReadReceiptsOn: Bool = true
    
    public init(uniqueId:String) {
        self.uniqueId = uniqueId
        self.accountUniqueId = -1
    }
    
    public static var databaseTableName: String {
        "chatThread"
    }
}

extension ChatThread {
    /**
     It checks read receipt settings for both user account level and chat thread level and makes a final decision for the
     read receipt display, while giving higher priority to the chat thread level read receipt setting. For example: if read receipt
     setting is `on` for the user account, but its `off` for the chat thread, the read receipt won't be displayed.
     */
    var shouldShowReadReceipts: Bool {
        
        var isReadReceiptOnForCurrentUser = true
        if let account = ChatAccountModel.getChatAccount(self.accountUniqueId) {
            isReadReceiptOnForCurrentUser = account.isReadReceiptsOn
        }
        let isReadReceiptOnForChatThread = self.isReadReceiptsOn
        
        switch (isReadReceiptOnForCurrentUser, isReadReceiptOnForChatThread) {
        case (true, true): return true
        case (true, false): return false
        case (false, true): return true
        case (false, false): return false
        }
    }
}

extension ChatThread: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(uniqueId)
    }

    public static func == (lhs: ChatThread, rhs: ChatThread) -> Bool {
        lhs.uniqueId == rhs.uniqueId
    }
}

//extension ChatThread {
    //static let buddy = hasOne(ChatBuddy.self)
//}

extension ChatThread {
    
    
    func getChatAccount() -> ChatAccountModel? {
        var acct:ChatAccountModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let account = try self.account.fetchOne(transaction.database) {
                    acct = ChatAccountModel(account: account)
                }
            })
        } catch {
            DDLogDebug("ChatThread.getChatAccount with error: \(error)")
        }
        //if let budId = self.grdbRecord?.buddyUniqueId {
        //    return ChatBuddyModel.getBuddy(uniqueId: budId)
        //}
        
        return acct
    }
    
    public static func update(with thread:ChatThread, message:MessageProtocol) {
        var cthread:ChatThread?
        DBManager.sharedDB().grdbStorage.asyncRead(block: { transaction in
            do {
                cthread = try ChatThread
                    .filter(Column("uniqueId") == thread.uniqueId)
                    .fetchOne(transaction.database)
            } catch {
                //DDLogDebug("ChatThread.update with error: \(error)")
            }
        }, completion: {
            if cthread != nil {
                //update with new date/lastMessage
                cthread?.messageDate = message.messageDate
                cthread?.lastMessageId = message.uid
                cthread?.modified = Date()
                cthread?.storeInGRDB()
            } else {
                //create and save async
                var newThread = ChatThread(uniqueId: thread.uniqueId)
                newThread.messageDate = message.messageDate
                newThread.isGroupThread = thread.isGroupThread
                newThread.lastMessageId = message.uid
                newThread.accountUniqueId = thread.accountUniqueId
                newThread.modified = Date()
                newThread.storeInGRDB(completion: {
                    //buddy/room needs this ID
                })
            }
        })
    }
    
    public static func countConversations() -> Int {
        var count = 0
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                count = try ChatThread
                    .fetchCount(transaction.database)
            })
        } catch {
            //DDLogDebug("error: \(error)")
        }
        return count
    }
    
    public static func touch(uniqueId: String) {
        let nowdate = Date()
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                if var thread = try ChatThread
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database) {
                    thread.modified = nowdate
                    try thread.update(transaction.database, columns: [Column("modified")])
                }
            } catch {
                DDLogDebug("ChatThread.touch with error: \(error)")
            }
        })
    }
    
    func touch() {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            let nowdate = Date()
            var threadie = self
            do {
                threadie.modified = nowdate
                try threadie.update(transaction.database, columns: [Column("modified")])
            } catch {
                DDLogDebug("ChatThread.touch with error: \(error)")
            }
        })
    }
    
    func touch(transaction:GRDBWriteTransaction) {
        let nowdate = Date()
        var threadie = self
        do {
            threadie.modified = nowdate
            try threadie.update(transaction.database, columns: [Column("modified")])
        } catch {
            DDLogDebug("ChatThread.touchWithTransaction with error: \(error)")
        }
    }
    
    public static func getAllChatThreads(transaction: GRDBWriteTransaction) -> [ChatThread] {
        var xthreads:[ChatThread] = []
        do {
            xthreads = try ChatThread.fetchAll(transaction.database)
        } catch {
            DDLogDebug("ChatThread.getAllChatThreads with uniqueId error: \(error)")
        }

        return xthreads
    }
    
    public static func getChatThread(threadId: Int64) -> ChatThread? {
        var xthread:ChatThread?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                xthread = try ChatThread
                    .filter(Column("id") == threadId)
                    .fetchOne(transaction.database)
            })
        } catch {
            DDLogDebug("ChatThread.getChatThread with uniqueId error: \(error)")
        }

        return xthread
    }
    
    public static func getChatThread(uniqueId: String) -> ChatThread? {
        var xthread:ChatThread?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                xthread = try ChatThread
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database)
            })
        } catch {
            DDLogDebug("ChatThread.getChatThread with uniqueId error: \(error)")
        }

        return xthread
    }
    
    public static func getChatThread(uniqueId: String, transaction:GRDBReadTransaction) throws -> ChatThread? {
        return try ChatThread
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database)
    }
    
    public static func deleteChatThread(uniqueId: String) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                try ChatThread
                    .filter(Column("uniqueId") == uniqueId)
                    .deleteAll(transaction.database)
            } catch {
                DDLogDebug("ChatThread.deleteChatThread: \(error)")
            }
        })
    }
}

extension ChatThread {
    //static let threads = hasMany(ChatThread.self)
    //var threads: QueryInterfaceRequest<ChatThread> {
    //    request(for: ChatThread.threads)
    //}
    
    static let account = belongsTo(ChatAccount.self)
    var account: QueryInterfaceRequest<ChatAccount> {
        request(for: ChatThread.account)
    }
}
