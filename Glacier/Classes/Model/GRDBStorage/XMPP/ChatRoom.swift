//
//  ChatRoom.swift
//  Glacier
//
//  Created by andyfriedman on 9/18/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import GRDB
import XMPPFramework

@objc open class ChatRoomModel: GRDBModel {
    
    var grdbRecord:ChatRoom?
    /// JID of the room itself
    //@objc private var jid:String?
    /** Your full JID for the room e.g. joe@conference.domain.com/joeboo */
    @objc private var ownJID:String?
    @objc open var avatarSeedNum = -1
    
    convenience init(room:ChatRoom) {
        self.init(uniqueId: room.uniqueId)
        self.grdbRecord = room
    }
    
    @objc convenience init(accountId:String, jid:String) {
        let uid = accountId + jid
        let grec = ChatRoom(uniqueId: uid, chatId: -1, lastHistoryFetch: nil, muteExpiration: nil, accountUniqueId: accountId, preferredSecurity: nil, roomJid: jid, ourJid: nil, messageText: nil, lastRoomMessageId: "", subject: nil, roomName: nil, roomPassword: nil, currentMessageText: nil, modified: Date())
        self.init(room: grec)
    }
    
    @objc convenience init(uniqueId: String, accountId:String, jid:String) {
        let grec = ChatRoom(uniqueId: uniqueId, chatId: -1, lastHistoryFetch: nil, muteExpiration: nil, accountUniqueId: accountId, preferredSecurity: nil, roomJid: jid, ourJid: nil, messageText: nil, lastRoomMessageId: "", subject: nil, roomName: nil, roomPassword: nil, currentMessageText: nil, modified: Date())
        self.init(room: grec)
    }
}

extension ChatRoomModel {
    static var seedNum:Int = -1
    @objc public func nextAvatarNum(with seed: Int) -> Int {
        if (ChatRoomModel.seedNum < 0) {
            if (seed >= 0) {
                ChatRoomModel.seedNum = seed+1
                return ChatRoomModel.seedNum
            }
#if !TARGET_IS_EXTENSION
            ChatRoomModel.seedNum = OTRGroupAvatarGenerator.randomSeedNum(withSeed: uniqueId)
            return ChatRoomModel.seedNum
#endif
        }
        ChatRoomModel.seedNum = ChatRoomModel.seedNum+1
        return ChatRoomModel.seedNum
    }
    
    public var uid: String {
        return self.uniqueId
    }
    
    public var muteExpiration: Date? {
        get {
            self.grdbRecord?.muteExpiration
        }
        set {
            self.grdbRecord?.muteExpiration = newValue
        }
    }
    
    public var isMuted: Bool {
        get {
            guard let expiration = muteExpiration else {
                return false
            }
            if expiration > Date() {
                return true
            }
            return false
        }
    }
    
    @objc public var threadName: String {
        guard let grec = self.grdbRecord else { return "" }
        return grec.roomName ?? grec.subject ?? grec.roomJid ?? ""
    }
    
    public var threadIdentifier: String {
        self.uniqueId
    }
    
    public var threadCollection: String {
        ChatRoomModel.collection()
    }
    
    @objc public var threadAccountIdentifier: String {
        self.grdbRecord?.accountUniqueId ?? ""
    }
    
    @objc public var accountUniqueId: String? {
        get {
            return self.grdbRecord?.accountUniqueId
        }
        set {
            self.grdbRecord?.accountUniqueId = newValue
        }
    }
    
    @objc public func setModified() {
        self.grdbRecord?.modified = Date()
    }
    
    @objc public var roomName: String? {
        get {
            return self.grdbRecord?.roomName
        }
        set {
            self.grdbRecord?.roomName = newValue
        }
    }
    
    @objc public var subject: String? {
        get {
            self.grdbRecord?.subject
        }
        set {
            self.grdbRecord?.subject = newValue
        }
    }
    
    @objc public var roomPassword: String? {
        get {
            self.grdbRecord?.roomPassword
        }
        set {
            self.grdbRecord?.roomPassword = newValue
        }
    }
    
    @objc public var isPublic: Bool {
        get {
            return self.grdbRecord?.isPublic ?? false
        }
        set {
            self.grdbRecord?.isPublic = newValue
        }
    }
    
    @objc public var currentMessageText: String? {
        get {
            return self.grdbRecord?.messageText
        }
        set(currentMessageText) {
            self.grdbRecord?.messageText = currentMessageText
        }
    }
    
    @objc public var chatThreadId: Int64 {
        get {
            return self.grdbRecord?.chatThreadId ?? -1
        }
        set {
            self.grdbRecord?.chatThreadId = newValue
        }
    }
    
#if !TARGET_IS_EXTENSION
    @objc public var avatarImage: UIImage {
        if let image = GlacierImageCache.shared().retrieveImageInMemoryCache(forKey: self.uniqueId) {
        //if let image = OTRImages.image(withIdentifier: self.uniqueId) {
            return image
        } else {
            if (self.avatarSeedNum < 0) {
                self.avatarSeedNum = self.nextAvatarNum(with:-1)
                //self.saveThread()
            }
            
            if (self.avatarSeedNum < 0) {
                let seed = self.avatarSeed
                if let image = OTRGroupAvatarGenerator.avatarImage(withSeed: seed, width: 100, height: 100) {
                    GlacierImageCache.shared().store(image, forKey: self.uniqueId, options:GlacierImageCache.parsedOptions, toDisk: false)
                    //OTRImages.setImage(image, forIdentifier: self.uniqueId)
                    return image
                }
            }
            let seedNum = self.avatarSeedNum
            
            if let image = OTRGroupAvatarGenerator.avatarImage(withSeedNum: seedNum, width: 100, height: 100) {
                GlacierImageCache.shared().store(image, forKey: self.uniqueId, options:GlacierImageCache.parsedOptions, toDisk: false)
                //OTRImages.setImage(image, forIdentifier: self.uniqueId)
                return image
            } else {
                return OTRImages.avatarImage(withUniqueIdentifier: self.uniqueId, avatarData: nil, displayName: nil, username: self.threadName)
            }
        }
    }
#endif
    
    public var currentStatus: ThreadStatus {
#if !TARGET_IS_EXTENSION
        switch self.joined {
        case true:
            return .available
        default:
            return .offline
        }
#else
        return .offline
#endif
    }
    
    public var expiresIn: String? {
        get {
            return nil
        }
        set(expiresIn) {
            //
        }
    }
    
    public var isGroupThread: Bool {
        true
    }
    
    @objc public func numberOfUnreadMessages() -> UInt {
        var count = 0
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                count = try ChatRoomMessage
                    .filter(Column("roomUniqueId") == self.uniqueId)
                    .filter(Column("read") == false)
                    .fetchCount(transaction.database)
            })
        } catch {
            DDLogDebug("error: \(error)")
        }
        
        return UInt(count)
    }
    
    @objc public func outgoingMessage(text: String) -> MessageProtocol {
        let message = ChatRoomMessageModel()
        var grec = ChatRoomMessage(uniqueId: message.uniqueId)
        grec.messageText = text
        grec.messageDate = Date()
        grec.roomJid = self.grdbRecord?.roomJid
        grec.roomUniqueId = self.uniqueId
        grec.senderJid = self.grdbRecord?.ourJid
        grec.state = ChatRoomMessageState.needsSending.rawValue
        grec.originId = message.grdbRecord?.xmppId ?? message.uniqueId
        grec.messageSecurity = Int(OTRMessageTransportSecurity.OMEMO.rawValue)
        if let roomid = self.grdbRecord?.id {
            grec.chatRoomId = roomid
        }
        message.grdbRecord = grec
        return message
    }
    
    public func omemoDevices() -> [ChatOmemoDevice] {
        let occupants = allOccupants()
        let buddyKeys = occupants.compactMap { $0.grdbRecord?.buddyUniqueId }
        var devices: [ChatOmemoDevice] = []
        buddyKeys.forEach { (buddyKey) in
            let buddyDevices = ChatOmemoDevice.allOMEMODevices(for: buddyKey)
            devices.append(contentsOf: buddyDevices)
        }
        return devices
    }
    
    @objc public func saveThread() {
        guard let record = self.grdbRecord else { return }
        guard record.hasBackingChatThread() else {
            DDLogWarn("Skipping ChatRoom.saveThread for \(self.uniqueId) because backing chat thread is missing")
            return
        }
        record.storeInGRDB()
    }
    
    @objc public func saveThread(completion: @escaping () -> Void) {
        guard let record = self.grdbRecord else {
            completion()
            return
        }
        guard record.hasBackingChatThread() else {
            DDLogWarn("Skipping ChatRoom.saveThread(completion:) for \(self.uniqueId) because backing chat thread is missing")
            completion()
            return
        }
        record.storeInGRDB(completion: completion)
    }
    
    func storeInGRDB(transaction: GRDBWriteTransaction) {
        guard let record = self.grdbRecord else { return }
        guard record.hasBackingChatThread() else {
            DDLogWarn("Skipping ChatRoom.storeInGRDB(transaction:) for \(self.uniqueId) because backing chat thread is missing")
            return
        }
        record.grdbSave(transaction: transaction)
    }
    
    @objc public func lastMessage() -> MessageProtocol? {
        var message:MessageProtocol? = nil
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try ChatRoomMessage
                    .filter(Column("roomUniqueId") == self.uniqueId)
                    .order(Column("messageDate").desc)
                    .fetchOne(transaction.database) {
                    message = ChatRoomMessageModel(message: record)
                }
            })
        } catch {
            DDLogError("error: lastMessage \(error)")
        }
        return message
    }
    
    /*public func copyAsSelf() -> Self? {
        return self.copy() as? Self
    }*/
}

extension ChatRoomModel {
    @objc open class func createUniqueId(_ accountId:String, jid:String) -> String {
        return accountId + jid
    }
    
    /// XMPPJID of the room itself
    @objc public var roomJID: XMPPJID? {
        get {
            if let jid = self.grdbRecord?.roomJid {
                return XMPPJID(string: jid)
            } else {
                return nil
            }
        }
        set {
            self.grdbRecord?.roomJid = newValue?.bare
        }
    }
    
    public var ourJID: XMPPJID? {
        get {
            guard let jid = self.grdbRecord?.ourJid else {
                return nil
            }
            return XMPPJID(string: jid)
        }
        set {
            self.grdbRecord?.ourJid = newValue?.full
        }
    }
    
    @objc open var joined:Bool {
        get {
            return BuddyCache.shared().runtimePropertiesFor(room: self)?.joined ?? false
        }
        set (value) {
            BuddyCache.shared().runtimePropertiesFor(room: self)?.joined = value
        }
    }
    
    @objc open var hasFetchedHistory:Bool {
        get {
            return BuddyCache.shared().runtimePropertiesFor(room: self)?.hasFetchedHistory ?? false
        }
        set (value) {
            BuddyCache.shared().runtimePropertiesFor(room: self)?.hasFetchedHistory = value
        }
    }
     
    @objc static func getXMPPRoom(uniqueId: String) -> ChatRoomModel? {
        var room:ChatRoomModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let codable = try ChatRoom
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database) {
                    room = ChatRoomModel(room: codable)
                }
            })
        } catch {
            DDLogDebug("ChatRoomModel.getXMPPRoom with uniqueId error: \(error)")
        }

        return room
    }
    
    @nonobjc static func getXMPPRoom(uniqueId: String, transaction: GRDBReadTransaction) throws -> ChatRoomModel? {
        if let codable = try ChatRoom
            .filter(Column("uniqueId") == uniqueId)
            .fetchOne(transaction.database) {
            return ChatRoomModel(room: codable)
        }
        return nil
    }
    
    @objc static func getXMPPRoom(roomJid: XMPPJID) -> ChatRoomModel? {
        var room:ChatRoomModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let codable = try ChatRoom
                    .filter(Column("roomJid") == roomJid.bare)
                    .fetchOne(transaction.database) {
                    room = ChatRoomModel(room: codable)
                    //jid.isEqual(to: ourJID, options: .bare)
                }
            })
        } catch {
            DDLogDebug("ChatRoomModel.getRoomWithJid with uniqueId error: \(error)")
        }

        return room
    }
    
    @objc open class func fetch(xmppRoom: XMPPRoom) -> ChatRoomModel? {
        guard let chatRoomKey = xmppRoom.chatRoomKey else {
            return nil
        }
        return ChatRoomModel.getXMPPRoom(uniqueId: chatRoomKey)
    }
    
    public class func fetch(xmppRoom: XMPPRoom, transaction: GRDBWriteTransaction) throws -> ChatRoomModel? {
        guard let chatRoomKey = xmppRoom.chatRoomKey else {
            return nil
        }
        return try ChatRoomModel.getXMPPRoom(uniqueId: chatRoomKey, transaction: transaction)
    }
    
    @objc public func allOccupants() -> [ChatRoomOccupantModel] {
        return ChatRoomOccupantModel.allXMPPRoomOccupants(for: self.uniqueId)
    }
    
    public func allOccupants(transaction: GRDBReadTransaction) -> [ChatRoomOccupantModel] {
        return ChatRoomOccupantModel.allXMPPRoomOccupants(for: self.uniqueId, transaction: transaction)
    }
    
    @objc public func allBuddies() -> [ChatBuddyModel] {
        guard let account = xmppAccount() else { return [] }
        let myJID = account.bareJID
        let buddies = allOccupants()
            .compactMap { $0.grdbRecord?.buddyUniqueId }
            .compactMap { ChatBuddyModel.getBuddy(uniqueId:$0) }
        let filtered = buddies
            .filter {
                if let uname = $0.grdbRecord?.username, let xjid = XMPPJID(string: uname) {
                    return xjid != myJID
                }
                return false
            }
            .sorted { ($0.grdbRecord?.username)! < ($1.grdbRecord?.username)! }
        return filtered
    }

    public func xmppAccount() -> ChatAccountModel? {
        return ChatAccountModel.getXMPPAccount(uniqueId: threadAccountIdentifier)
    }
    
    @objc public func removeRoom() {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                try ChatThread
                    .filter(Column("uniqueId") == self.uniqueId)
                    .deleteAll(transaction.database)
                try ChatMediaItem
                    .filter(Column("parentObjectKey") == self.uniqueId)
                    .filter(Column("parentObjectCollection") == ChatRoomModel.collection())
                    .deleteAll(transaction.database)
                self.grdbRecord?.grdbRemove(transaction: transaction)
            } catch {
                DDLogError("Tried removing record but failed")
            }
        })
    }
    
    @objc public func remove(completionBlock: @escaping ()->Void ) {
        ChatThread.deleteChatThread(uniqueId: self.uniqueId)
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            self.grdbRecord?.grdbRemove(transaction: transaction)
        }, completion: completionBlock)
    }
    
    //ALF23
    @objc static func updateLastHistory(accountId:String) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            let nowdate = Date()
            //NSLog("***** updateLastHistory date to \(nowdate)")
            do {
                try ChatRoom
                    .filter(Column("accountUniqueId") == accountId)
                    .updateAll(transaction.database, Column("lastHistoryFetch").set(to: nowdate))
            } catch {
                DDLogDebug("ChatRoom.updateLastHistory with error: \(error)")
            }
        })
    }
    
    @objc public static func allXMPPRooms(for account:String) -> [ChatRoomModel] {
        var rooms:[ChatRoomModel] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let codables = try ChatRoom
                    .filter(Column("accountUniqueId") == account)
                    .fetchAll(transaction.database)
                for codable in codables {
                    rooms.append(ChatRoomModel(room: codable))
                }
            })
        } catch {
            DDLogDebug("ChatRoom.allXMPPRooms with uniqueId error: \(error)")
        }
        return rooms
    }
    
    @objc public static func allXMPPRooms(for account:String, transaction: GRDBReadTransaction) -> [ChatRoomModel] {
        var rooms:[ChatRoomModel] = []
        do {
            let codables = try ChatRoom
                .filter(Column("accountUniqueId") == account)
                .fetchAll(transaction.database)
            for codable in codables {
                rooms.append(ChatRoomModel(room: codable))
            }
        } catch {
            DDLogDebug("ChatRoom.allXMPPRooms with uniqueId error: \(error)")
        }
        return rooms
    }
    
    @objc public static func allXMPPRooms() -> [ChatRoomModel] {
        var rooms:[ChatRoomModel] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let codables = try ChatRoom
                    .fetchAll(transaction.database)
                for codable in codables {
                    rooms.append(ChatRoomModel(room: codable))
                }
            })
        } catch {
            DDLogDebug("ChatRoom.allXMPPRooms error: \(error)")
        }
        return rooms
    }
    
    @objc static func roomFromThread(_ thread: ChatThreadModel) -> ChatRoomModel? {
        var room: ChatRoom?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                room = try ChatRoom
                    .filter(Column("chatThreadId") == thread.grdbRecord?.id)
                    .fetchOne(transaction.database)
                if room == nil {
                    room = try ChatRoom
                        .filter(Column("uniqueId") == thread.grdbRecord?.uniqueId)
                        .fetchOne(transaction.database)
                }
            })
        } catch {
            DDLogDebug("ChatRoom.roomFromThread with error: \(error)")
        }
        
        if let room = room {
            return ChatRoomModel(room:room)
        }
        return nil
    }
    
#if !TARGET_IS_EXTENSION
    @objc public static func removeAccountFromRooms(for accountId:String) {
        var rooms:[ChatRoom] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                rooms = try ChatRoom
                    .filter(Column("accountUniqueId") == accountId)
                    .fetchAll(transaction.database)
            })
        } catch {
            DDLogDebug("ChatRoomModel.removeAccountFromRooms: \(error)")
        }
        
        if let account = ChatAccountModel.getXMPPAccount(uniqueId: accountId), let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount:account) {
            let jid = XMPPJID(string: account.username)
            var bookmarks: [XMPPConferenceBookmark] = []
            let leftGroup = account.displayName + " left the group"
            for room in rooms {
                if let rjidstr = room.roomJid, let roomjid = XMPPJID(string: rjidstr) {
                    if let xroom = xmpp.roomManager.room(for: roomjid), let acctjid = jid {
                        xroom.unsubscribe(fromRoom: acctjid)
                    }
                    
                    var bookName = room.subject
                    if let name = room.roomName {
                        bookName = name
                    }
                    let bookmark = XMPPConferenceBookmark(jid: roomjid, bookmarkName: bookName, nick: nil, autoJoin: true)
                    bookmarks.append(bookmark)
                }
                
                //let xmpproom = ChatRoom(room: room)
                let roomModel = ChatRoomModel(room: room)
                let leftMsg = roomModel.outgoingMessage(text: leftGroup)
                
                if let acctid = roomModel.accountUniqueId {
                    leftMsg.senderId = account.uniqueId
                    leftMsg.senderDisplayName = account.displayName
                }
                
                xmpp.enqueueMessage(leftMsg)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let rjidstr = room.roomJid, let roomjid = XMPPJID(string: rjidstr) {
                        xmpp.roomManager.leaveRoom(roomjid)
                    }
                    DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                        do {
                            try room.delete(transaction.database)
                        } catch {
                            DDLogDebug("ChatRoom.removeRoom with error: \(error)")
                        }
                    })
                }
            }
            
            xmpp.roomManager.removeRooms(from: bookmarks)
        }
    }
#endif
}

extension ChatRoomModel {
    /// Generates seed value for OTRGroupAvatarGenerator
    var avatarSeed: String {
        var seed = self.uniqueId
        if let jid = self.roomJID,
            let user = jid.user {
            seed = user
        }
        return seed
    }
    
    @objc var bookmark: XMPPConferenceBookmark? {
        guard let jid = roomJID else { return nil }
        var bookName = self.grdbRecord?.subject
        if let name = self.grdbRecord?.roomName {
            bookName = name
        }
        let bookmark = XMPPConferenceBookmark(jid: jid, bookmarkName: bookName, nick: nil, autoJoin: true)
        return bookmark
    }
}

public struct ChatRoom: GRDBRecord {
    public var id: Int64?
    public var uniqueId: String
    
    var lastHistoryFetch: Date?
    var isArchived = false
    var muteExpiration: Date?
    var accountUniqueId: String?
    var isPublic = false
    var preferredSecurity: Int?
    var roomJid: String?
    var ourJid: String?
    var messageText: String?
    var lastRoomMessageId: String?
    var subject: String?
    var roomName: String?
    var roomPassword: String?
    var currentMessageText: String?
    var chatThreadId: Int64
    var modified: Date?

    public static var databaseTableName: String {
        "chatRoom"
    }
    
    public init(uniqueId:String, chatId:Int64, lastHistoryFetch:Date?, isArchived:Bool = false,  muteExpiration:Date?, accountUniqueId:String?, isPublic:Bool = false, preferredSecurity:Int?, roomJid:String?, ourJid:String?, messageText:String?, lastRoomMessageId:String?, subject:String?, roomName:String?, roomPassword: String?, currentMessageText: String?, modified: Date?) {
        self.uniqueId = uniqueId
        self.lastHistoryFetch = lastHistoryFetch
        self.isArchived = isArchived
        self.muteExpiration = muteExpiration
        self.accountUniqueId = accountUniqueId
        self.isPublic = isPublic
        self.preferredSecurity = preferredSecurity
        self.accountUniqueId = accountUniqueId
        self.roomJid = roomJid
        self.ourJid = ourJid
        self.messageText = messageText
        self.lastRoomMessageId = lastRoomMessageId
        self.subject = subject
        self.roomName = roomName
        self.roomPassword = roomPassword
        self.currentMessageText = currentMessageText
        self.chatThreadId = chatId
        self.modified = Date()
    }
    
    func touch() {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            let nowdate = Date()
            var room = self
            do {
                room.modified = nowdate
                try room.update(transaction.database, columns: [Column("modified")])
            } catch {
                DDLogDebug("ChatRoom.touch with error: \(error)")
            }
        })
    }
    
    func touch(_ transaction:GRDBWriteTransaction) {
        let nowdate = Date()
        var room = self
        do {
            room.modified = nowdate
            try room.update(transaction.database, columns: [Column("modified")])
        } catch {
            DDLogDebug("ChatRoom.touch with error: \(error)")
        }
    }
    
    static func roomFromThread(_ thread: ChatThread) -> ChatRoom? {
        var room: ChatRoom?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                room = try ChatRoom
                    .filter(Column("chatThreadId") == thread.id)
                    .fetchOne(transaction.database)
                if room == nil {
                    room = try ChatRoom
                        .filter(Column("uniqueId") == thread.uniqueId)
                        .fetchOne(transaction.database)
                }
            })
        } catch {
            DDLogDebug("ChatRoom.roomFromThread with error: \(error)")
        }
        
        return room
    }
    
    public static func getRoom(uniqueId: String) -> ChatRoom? {
        var room:ChatRoom?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                room = try ChatRoom
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database)
            })
        } catch {
            DDLogDebug("ChatRoom.getRoom with uniqueId error: \(error)")
        }

        return room
    }
    
    public func storeInGRDB(completion: @escaping () -> Void) {
        guard hasBackingChatThread() else {
            DDLogWarn("Skipping ChatRoom.storeInGRDB for \(self.uniqueId) because backing chat thread is missing")
            completion()
            return
        }
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            self.grdbSave(transaction: transaction)
        }, completion: completion)
    }
}

extension ChatRoom {
    static let messages = hasMany(ChatRoomMessage.self)
    var messages: QueryInterfaceRequest<ChatRoomMessage> {
        request(for: ChatRoom.messages)
    }
    
    //static let address = hasOne(Address.self)
    static let thread = belongsTo(ChatThread.self)//belongsTo(ChatThread.self)
    var thread: QueryInterfaceRequest<ChatThread> {
        request(for: ChatRoom.thread)
    }
}

public extension XMPPRoom {
    
    /// key for ChatRoom
    var chatRoomKey: String? {
        guard let accountId = self.accountId else {
            return nil
        }
        return accountId + roomJID.bare
    }
}

private extension ChatRoom {
    func hasBackingChatThread() -> Bool {
        if chatThreadId > 0,
           ChatThread.getChatThread(threadId: chatThreadId) != nil {
            return true
        }
        if ChatThread.getChatThread(uniqueId: uniqueId) != nil {
            return true
        }
        return false
    }
}
