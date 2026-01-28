//
//  ChatBuddy.swift
//  Glacier
//
//  Created by andyfriedman on 9/12/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import GRDB
import CryptoKit
import CocoaLumberjack
import XMPPFramework

@objc public enum TrustLevel: Int {
    case untrusted = 0
    case roster = 1
}

@objc public enum SubscriptionAttribute: Int {
    case none = 0
    case to = 1
    case from = 2
    case both = 3
}

extension SubscriptionAttribute {
    
    public init(stringValue: String) {
        switch stringValue {
        case "from": self = .from
        case "to": self = .to
        case "both": self = .both
        default: self = .none
        }
    }
    
    public var stringValue: String {
        switch self {
        case .from: return "from"
        case .to: return "to"
        case .both: return "both"
        default: return "none"
        }
    }
    
    public func isSubscribedTo() -> Bool {
        switch self {
        case .to, .both: return true
        default: return false
        }
    }
    
    public func isSubscribedFrom() -> Bool {
        switch self {
        case .from, .both: return true
        default: return false
        }
    }
}

@objc public enum SubscriptionPendingAttribute: Int {
    case pendingnone = 0
    case pendingin = 1
    case pendingout = 2
    case pendingoutin = 3
}

extension SubscriptionPendingAttribute {
    public func isPendingIn() -> Bool {
        switch self {
        case .pendingin, .pendingoutin: return true
        default: return false
        }
    }
    
    public mutating func setPendingIn(pending:Bool) {
        if (pending) {
            switch self {
            case .pendingnone: self = .pendingin
            case .pendingout: self = .pendingoutin
            default: break
            }
        } else {
            switch self {
            case .pendingin: self = .pendingnone
            case .pendingoutin: self = .pendingout
            default: break
            }
        }
    }
    
    public func isPendingOut() -> Bool {
        switch self {
        case .pendingout, .pendingoutin: return true
        default: return false
        }
    }
    
    public mutating func setPendingOut(pending:Bool) {
        if (pending) {
            switch self {
            case .pendingnone: self = .pendingout
            case .pendingin: self = .pendingoutin
            default: break
            }
        } else {
            switch self {
            case .pendingout: self = .pendingnone
            case .pendingoutin: self = .pendingin
            default: break
            }
        }
    }
}

@objc public enum ChatState: Int {
    case unknown = 0
    case active = 1
    case composing = 2
    case paused = 3
    case inactive = 4
    case gone = 5
}

@objc public enum SessionSecurity: Int {
    case bestAvailable = 0
    case plaintext = 1
    case omemo = 2
}

@objc open class ChatBuddyModel: GRDBModel {
    lazy var defaultImage = UIImage.init(named: "person", in: GlacierInfo.resourcesBundle, with: nil)?.withRenderingMode(.alwaysTemplate)
    
    var grdbRecord:ChatBuddy?
    
    convenience init(buddy:ChatBuddy) {
        self.init(uniqueId: buddy.uniqueId)
        self.grdbRecord = buddy
    }
}

#if !TARGET_IS_EXTENSION
extension ChatBuddyModel: ChatvCard {
    @objc public var vCardTemp: XMPPvCardTemp? {
        get {
            var vtemp = XMPPvCardTemp.v()
            if let av = self.grdbRecord?.avatarData {
                vtemp.photo = av
            }
            if let dname = self.grdbRecord?.displayName {
                vtemp.nickname = dname
            }
            
            return vtemp
        }
        set {
            if let photo = newValue?.photo {
                self.grdbRecord?.avatarData = photo
            }
            if let nick = newValue?.nickname {
                self.grdbRecord?.displayName = nick
            } else if let fname = newValue?.formattedName {
                self.displayName = fname
            }
        }
    }
    
    @objc public func isMissingVCardData() -> Bool {
        if self.displayName.count == 0 || self.avatarData == nil {
            return true
        }
        return false
    }
    
    @objc public func updateVCard(_ vcard:XMPPvCardTemp) {
        self.vCardTemp = vcard
        if var buddy = self.grdbRecord {
            DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                let nowdate = Date()
                do {
                    buddy.modified = nowdate
                    try buddy.update(transaction.database, columns: [Column("displayName"), Column("avatarData"), Column("modified")])
                } catch {
                    DDLogDebug("ChatBuddy.touch with error: \(error)")
                }
            }, completion: {
                ChatThread.touch(uniqueId: buddy.uniqueId)
            })
        }
    }
    
    @objc public var lastUpdatedvCardTemp: Date? {
        get {
            return self.grdbRecord?.lastUpdatedvCardTemp
        }
        set {
            self.grdbRecord?.lastUpdatedvCardTemp = newValue
        }
    }
    
    @objc public var waitingForvCardTempFetch: Bool {
        get {
            return BuddyCache.shared().waitingForChatvCardTempFetch(self.uniqueId)
        }
        set {
            BuddyCache.shared().setWaitingForChatvCardTempFetch(waiting: newValue, vCardId: self.uniqueId, collection: ChatBuddyModel.collection())
        }
    }
    
    @objc public var photoHash: String? {
        get {
            return self.grdbRecord?.photoHash
        }
        set {
            self.grdbRecord?.photoHash = newValue
        }
    }
    
    @objc public var avatarData: Data? {
        get {
            return self.grdbRecord?.avatarData
        }
        set {
            if let avatarData = self.grdbRecord?.avatarData, avatarData != newValue {
                //GlacierImageCache.shared().removeImage(self.uniqueId)
                OTRImages.removeImage(withIdentifier: self.uniqueId)
            }
            self.grdbRecord?.avatarData = newValue
            
            if let count = self.grdbRecord?.avatarData?.count, count > 0, let data = self.grdbRecord?.avatarData as? NSData, let sha1 = Insecure.SHA1.hash(data: data) as? NSData {
                self.grdbRecord?.photoHash = sha1.xmpp_hexStringValue
            } else {
                self.grdbRecord?.photoHash = nil
            }
        }
    }
    
    /*@objc public func copyAsSelf() -> Self? {
        return self.copy() as? Self
    }*/
}
#endif

extension ChatBuddyModel {
    
    public var uid: String {
        return self.uniqueId
    }
    
    /*public var isMuted: Bool {
        get {
            guard let expiration = muteExpiration else {
                return false
            }
            if expiration > Date() {
                return true
            }
            return false
        }
    }*/
    
    public var muteExpiration: Date? {
        get {
            self.grdbRecord?.muteExpiration
        }
        set {
            self.grdbRecord?.muteExpiration = newValue
        }
    }
    
    @objc public var threadName: String {
        return self.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    @objc public var threadIdentifier: String {
        return self.uniqueId
    }
    
    public var threadCollection: String {
        return ChatBuddyModel.collection()
    }
    
    public var chatThread: ChatThreadModel? {
        guard let threadId = self.grdbRecord?.chatThreadId  else {return nil}
        if threadId < 0 {
            return nil
        }
            
        var threadModel:ChatThreadModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try ChatThread
                    .filter(Column("id") == threadId)
                    .fetchOne(transaction.database) {
                    threadModel = ChatThreadModel(thread: record)
                }
            })
        } catch {
            DDLogDebug("ChatBuddyModel.threadOwner with error: \(error)")
        }
                
        return threadModel
    }
    
    @objc public var threadAccountIdentifier: String {
        self.grdbRecord?.accountUniqueId ?? ""
    }
    
    @objc public var trustLevel: TrustLevel {
        .roster
    }
    
    @objc public var currentMessageText: String? {
        get {
            self.grdbRecord!.currentMessageText
        }
        set {
            self.grdbRecord!.currentMessageText = newValue
        }
    }
    
    public func chatState() -> ChatState {
        return BuddyCache.shared().chatState(buddy: self.grdbRecord!)
    }

    public func lastSentChatState() -> ChatState {
        return BuddyCache.shared().lastSentChatState(buddy: self)
    }
    
    public var status: ThreadStatus {
        BuddyCache.shared().threadStatus(buddyId: self.uniqueId)
    }

    /*public func status() -> ThreadStatus {
        return BuddyCache.shared().threadStatus(buddyId: self.uniqueId)
    }*/
    
    public func statusMessage() -> String? {
        BuddyCache.shared().statusMessage(buddy: self.grdbRecord!)
    }
    
    @objc public var currentStatus: ThreadStatus {
        BuddyCache.shared().threadStatus(buddyId: self.uniqueId)
    }
    
    public var expiresIn: String? {
        get {
            return self.grdbRecord!.expiresIn
        }
        set {
            self.grdbRecord!.expiresIn = newValue
        }
    }
    
    @objc public var accountUniqueId: String? {
        get {
            return self.grdbRecord?.accountUniqueId
        }
        set {
            self.grdbRecord?.accountUniqueId = newValue
        }
    }
    
    @objc var askingForApproval: Bool {
        get {
            return self.grdbRecord?.pending == SubscriptionPendingAttribute.pendingin.rawValue
        }
        set {
            if newValue == true {
                self.grdbRecord?.pending = SubscriptionPendingAttribute.pendingin.rawValue
            }
        }
    }
    
    @objc var pendingApproval: Bool {
        get {
            return self.grdbRecord?.pending == SubscriptionPendingAttribute.pendingout.rawValue
        }
        set {
            if newValue == true {
                self.grdbRecord?.pending = SubscriptionPendingAttribute.pendingout.rawValue
            }
        }
    }
    
    public var isGroupThread: Bool {
        false
    }
    
    /*@objc public func setVCardTemp(_ vCardTemp:XMPPvCardTemp) {
        //_vCardTemp = vCardTemp;
        if let photo = vCardTemp.photo {
            self.grdbRecord?.avatarData = photo
        }
        if let nick = vCardTemp.nickname {
            self.grdbRecord?.displayName = nick
        } else if let fname = vCardTemp.formattedName {
            self.displayName = fname
        }
    }*/
    
    //Always default to OMEMO, change after creation if needed
    public func outgoingMessage(text: String) -> MessageProtocol {
        let message = OutgoingChatMessage()
        message.grdbRecord?.text = text
        message.grdbRecord?.buddyUniqueId = self.uniqueId
        if let buddyid = self.grdbRecord?.id {
            message.grdbRecord?.chatBuddyId = buddyid
        }
        
        //let preferredSecurity:OTRMessageTransportSecurity = .OMEMO
        message.messageSecurity = .OMEMO
        //message.messageSecurityInfo = OTRMessageEncryptionInfo(messageSecurity: preferredSecurity)
        
        return message
    }
    
    public func omemoDevices() -> [ChatOmemoDevice] {
        return ChatOmemoDevice.allOMEMODevices(for: self.uniqueId)
    }
    
    @objc public func lastMessage() -> MessageProtocol?
    {
        var message:MessageProtocol? = nil
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try ChatMessage
                    .filter(Column("buddyUniqueId") == self.uniqueId)
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
    
    @objc public func numberOfUnreadMessages() -> UInt {
        var count = 0
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                count = try ChatMessage
                    .filter(Column("buddyUniqueId") == self.uniqueId)
                    .filter(Column("read") == false)
                    .filter(Column("type") != ChatMessageType.outgoing.rawValue)
                    .fetchCount(transaction.database)
            })
        } catch {
            DDLogDebug("error: \(error)")
        }
        
        return UInt(count)
    }
}

extension ChatBuddyModel: UserInfoProfile {
    public var displayName: String {
        get {
            guard let grec = grdbRecord else { return "" }
            if let displayName = grec.displayName, displayName.count > 0, !(displayName == grec.username) {
                return displayName
            }
            if let user = grec.username.otr_displayName() {
                return user
            }
            return grec.displayName ?? ""
        }
        set {
            self.grdbRecord?.displayName = newValue
        }
    }
    
    public var username: String {
        get {
            return grdbRecord?.username ?? ""
        }
        set {
            self.grdbRecord?.username = newValue
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
    
    @objc public var bareJID: XMPPJID? {
        return XMPPJID(string: self.username)
    }
    
#if !TARGET_IS_EXTENSION
    public var avatarImage: UIImage {
        get {
            //self.getAvatarImage()
            if let grec = self.grdbRecord, let img = OTRImages.avatarImage(withUniqueIdentifier: self.uniqueId, avatarData: grec.avatarData, displayName: grec.displayName, username: grec.username) {
                return img
            }
            return defaultImage ?? UIImage()
        }
    }
    
    public var avatarBorderColor: UIColor? {
        get {
            let threadStatus = self.currentStatus
            if threadStatus == ThreadStatus.offline {
                return nil
            }
            return Colors.color(with:threadStatus)
        }
    }
#endif
}

extension ChatBuddyModel {

    @objc public convenience init(username:String, accountId:String, uniqueId:String) {
        self.init(uniqueId: uniqueId)
        self.grdbRecord = ChatBuddy(uniqueId: uniqueId, chatId: nil, username: username, displayName: nil, composingString: nil, muteExpiration: nil, currentMessageText: nil, expiresIn: nil, lastMessageId: nil, accountUniqueId: accountId, avatarData: nil, subscription: nil, pending: nil, vCardTemp: nil, lastUpdatedvCardTemp: nil, photoHash: nil, modified: nil)
    }
    
    @objc public convenience init(jid:XMPPJID, accountId:String) {
        self.init()
        let username = jid.bare
        self.grdbRecord = ChatBuddy(uniqueId: self.uniqueId, chatId: nil, username: username, displayName: username, composingString: nil, muteExpiration: nil, currentMessageText: nil, expiresIn: nil, lastMessageId: nil, accountUniqueId: accountId, avatarData: nil, subscription: nil, pending: nil, vCardTemp: nil, lastUpdatedvCardTemp: nil, photoHash: nil, modified: nil)
    }
    
    @objc public func saveThread(completion: @escaping () -> Void) {
        self.grdbRecord?.storeInGRDB(completion: completion)
    }
    
    @objc public func saveThread() {
        self.grdbRecord?.storeInGRDB()
    }
    
    //This is error prone if multiple contacts have same display name!
    public static func fetchBuddyFrom(displayName: String, accountUniqueId: String) -> ChatBuddy? {
        var buddy:ChatBuddy?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                buddy = try ChatBuddy
                    .filter(Column("accountUniqueId") == accountUniqueId)
                    .filter(Column("displayName") == displayName)
                    .fetchOne(transaction.database)
                return buddy
            })
        } catch {
            DDLogDebug("ChatBuddyModel.fetchBuddyFrom with uniqueId error: \(error)")
        }

        return buddy
    }
    
    //This is error prone if multiple contacts have same display name!
    public static func fetchBuddyFrom(displayName: String, accountUniqueId: String, transaction: GRDBReadTransaction) -> ChatBuddy? {
        var buddy:ChatBuddy?
        do {
            buddy = try ChatBuddy
                .filter(Column("accountUniqueId") == accountUniqueId)
                .filter(Column("displayName") == displayName)
                .fetchOne(transaction.database)
        } catch {
            DDLogDebug("ChatBuddyModel.fetchBuddyFrom with uniqueId error: \(error)")
        }

        return buddy
    }
    
    public static func fetchBuddy(jid: XMPPJID, accountUniqueId: String) -> ChatBuddy? {
        var buddy:ChatBuddy?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                buddy = try ChatBuddy
                    .filter(Column("accountUniqueId") == accountUniqueId)
                    .filter(Column("username") == jid.bare)
                    .fetchOne(transaction.database)
                return buddy
            })
        } catch {
            DDLogDebug("ChatBuddyModel.fetchBuddy with uniqueId error: \(error)")
        }

        return buddy
    }
    
    public static func fetchBuddy(jid: XMPPJID, accountUniqueId: String, transaction: GRDBReadTransaction) -> ChatBuddy? {
        var buddy:ChatBuddy?
        do {
            buddy = try ChatBuddy
                .filter(Column("accountUniqueId") == accountUniqueId)
                .filter(Column("username") == jid.bare)
                .fetchOne(transaction.database)
            return buddy
        } catch {
            DDLogDebug("ChatBuddyModel.fetchBuddy with uniqueId error: \(error)")
        }

        return buddy
    }
    
    @objc public static func fetchBuddyModel(jid: XMPPJID, accountUniqueId: String) -> ChatBuddyModel? {
        if let buddy = Self.fetchBuddy(jid: jid, accountUniqueId: accountUniqueId) {
            return ChatBuddyModel(buddy: buddy)
        }

        return nil
    }
    
    @objc public static func fetchBuddyModel(jid: XMPPJID, accountUniqueId: String, transaction:GRDBReadTransaction) -> ChatBuddyModel? {
        if let buddy = Self.fetchBuddy(jid: jid, accountUniqueId: accountUniqueId, transaction: transaction) {
            return ChatBuddyModel(buddy: buddy)
        }

        return nil
    }
    
    @objc public static func fetchBuddyAsync(jid: XMPPJID, accountUniqueId: String, queue: DispatchQueue, completion: @escaping (ChatBuddyModel?) -> Void) {
        var buddy:ChatBuddyModel?
        DBManager.sharedDB().grdbStorage.asyncRead(block: { transaction in
            do {
                if let codable = try ChatBuddy
                    .filter(Column("accountUniqueId") == accountUniqueId)
                    .filter(Column("username") == jid.bare)
                    .fetchOne(transaction.database) {
                    buddy = ChatBuddyModel(buddy: codable)
                }
            } catch {
                DDLogDebug("ChatBuddy.fetchBuddyAsync with error: \(error)")
            }
        }, completionQueue: queue, completion: {
            completion(buddy)
        })
    }
    
    @objc public func refetch(completion: @escaping (ChatBuddyModel?) -> Void){
        var buddy:ChatBuddyModel?
        DBManager.sharedDB().grdbStorage.asyncRead(block: { transaction in
            do {
                if let codable = try ChatBuddy
                    .filter(Column("uniqueId") == self.uniqueId)
                    .fetchOne(transaction.database) {
                    buddy = ChatBuddyModel(buddy: codable)
                }
            } catch {
                DDLogDebug("ChatBuddy.refetch with error: \(error)")
            }
        }, completion: {
            completion(buddy)
        })
    }
    
    @objc public static func getBuddyAndAccount(uniqueId: String, queue: DispatchQueue, completion: @escaping (ChatBuddyModel?, ChatAccountModel?) -> Void) {
        var buddy:ChatBuddyModel?
        var account:ChatAccountModel?
        DBManager.sharedDB().grdbStorage.asyncRead(block: { transaction in
            do {
                if let codBuddy = try ChatBuddy
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database) {
                    buddy = ChatBuddyModel(buddy: codBuddy)
                    account = try ChatAccountModel.getXMPPAccount(uniqueId: buddy!.threadAccountIdentifier, transaction: transaction)
                }
            } catch {
                DDLogDebug("ChatBuddy.fetchBuddyAsync with error: \(error)")
            }
        }, completionQueue: queue, completion: {
            completion(buddy, account)
        })
    }
    
    @objc public static func getBuddyAndAccount(jid: XMPPJID, accountUniqueId: String, queue: DispatchQueue, completion: @escaping (ChatBuddyModel?, ChatAccountModel?) -> Void) {
        var buddy:ChatBuddyModel?
        var account:ChatAccountModel?
        DBManager.sharedDB().grdbStorage.asyncRead(block: { transaction in
            do {
                if let codBuddy = try ChatBuddy
                    .filter(Column("accountUniqueId") == accountUniqueId)
                    .filter(Column("username") == jid.bare)
                    .fetchOne(transaction.database) {
                    buddy = ChatBuddyModel(buddy: codBuddy)
                    account = try ChatAccountModel.getXMPPAccount(uniqueId: buddy!.threadAccountIdentifier, transaction: transaction)
                }
            } catch {
                DDLogDebug("ChatBuddy.getBuddyAndAccount with error: \(error)")
            }
        }, completionQueue: queue, completion: {
            completion(buddy, account)
        })
    }
    
    @objc public static func getBuddy(uniqueId: String) -> ChatBuddyModel? {
        var buddy:ChatBuddyModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let codable = try ChatBuddy
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database) {
                    buddy = ChatBuddyModel(buddy: codable)
                }
                return buddy
            })
        } catch {
            DDLogDebug("ChatBuddy.getBuddy with uniqueId error: \(error)")
        }

        return buddy
    }
    
    @objc public static func getBuddy(uniqueId: String, transaction:GRDBReadTransaction) -> ChatBuddyModel? {
        var buddy:ChatBuddyModel?
        do {
            if let codable = try ChatBuddy
                .filter(Column("uniqueId") == uniqueId)
                .fetchOne(transaction.database) {
                buddy = ChatBuddyModel(buddy: codable)
            }
            return buddy
        } catch {
            DDLogDebug("ChatBuddy.getBuddy with uniqueId error: \(error)")
        }

        return buddy
    }
    
    /*@objc public static func getThread(uniqueId: String) -> ChatThread? {
        var buddy:ChatBuddyModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let codable = try ChatBuddy
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database) {
                    buddy = ChatBuddyModel(buddy: codable)
                }
                return buddy
            })
        } catch {
            DDLogDebug("ChatBuddy.getBuddy with uniqueId error: \(error)")
        }

        return buddy
    }*/
    
    @objc static func getAllBuddies(for accountId:String) -> [ChatBuddyModel] {
        var buddies: [ChatBuddyModel] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let codabuddies = try ChatBuddy
                    .filter(Column("accountUniqueId") == accountId)
                    .fetchAll(transaction.database)
                for codabuddy in codabuddies {
                    buddies.append(ChatBuddyModel(buddy: codabuddy))
                }
            })
        } catch {
            DDLogDebug("ChatBuddy.getAllBuddies with error: \(error)")
        }
        
        return buddies
    }
    
    @objc static func getAllBuddies(for accountId:String, transaction: GRDBReadTransaction) -> [ChatBuddyModel] {
        var buddies: [ChatBuddyModel] = []
        do {
            let codabuddies = try ChatBuddy
                .filter(Column("accountUniqueId") == accountId)
                .fetchAll(transaction.database)
            for codabuddy in codabuddies {
                buddies.append(ChatBuddyModel(buddy: codabuddy))
            }
        } catch {
            DDLogDebug("ChatBuddy.getAllBuddies with error: \(error)")
        }
        
        return buddies
    }
    
    @objc static func getAllBuddies(completion: @escaping ([ChatBuddyModel]) -> Void) {
        var buddies:[ChatBuddyModel] = []
        DBManager.sharedDB().grdbStorage.asyncRead(block: { transaction in
            do {
                let codabuddies = try ChatBuddy
                    .fetchAll(transaction.database)
                for codabuddy in codabuddies {
                    buddies.append(ChatBuddyModel(buddy: codabuddy))
                }
            } catch {
                DDLogDebug("ChatBuddy.getAllBuddies with error: \(error)")
            }
        }, completion: {
            completion(buddies)
        })
    }
    
    @objc static func disconnectAllBuddies(accountId:String, queue: DispatchQueue) {
        var buddies: [ChatBuddy] = []
        DBManager.sharedDB().grdbStorage.asyncRead(block: { transaction in
            do {
                buddies = try ChatBuddy
                    .filter(Column("accountUniqueId") == accountId)
                    .fetchAll(transaction.database)
            } catch {
                DDLogDebug("ChatBuddy.disconnectAllBuddies with error: \(error)")
            }
        }, completionQueue: queue, completion: {
            let newStatus = ThreadStatus.offline
            for buddy in buddies {
                BuddyCache.shared().setStatusMessage(OFFLINE_STRING(), buddyId: buddy.uniqueId)
                BuddyCache.shared().setChatState(ChatState.gone, buddyId: buddy.uniqueId)
                BuddyCache.shared().setThreadStatus(newStatus, buddyId: buddy.uniqueId, resource: nil)
                buddy.touch()
            }
        })
    }
    
    @objc public func touchBuddy() {
        if let rec = self.grdbRecord {
            rec.touch()
        }
    }
    
    public func touchBuddy(_ transaction:GRDBReadTransaction) {
        if var bud = self.grdbRecord {
            let nowdate = Date()
            do {
                bud.modified = nowdate
                try bud.update(transaction.database, columns: [Column("modified")])
            } catch {
                DDLogDebug("ChatBuddyModel.touchBuddy with error: \(error)")
            }
        }
    }
    
    @objc static func buddyFromThread(_ thread: ChatThreadModel) -> ChatBuddyModel? {
        var buddy: ChatBuddy?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                buddy = try ChatBuddy
                    .filter(Column("chatThreadId") == thread.grdbRecord?.id)
                    .fetchOne(transaction.database)
                if buddy == nil {
                    buddy = try ChatBuddy
                        .filter(Column("uniqueId") == thread.grdbRecord?.uniqueId)
                        .fetchOne(transaction.database)
                }
            })
        } catch {
            DDLogDebug("ChatBuddy.buddyFromThread with error: \(error)")
        }
        
        if let buddy = buddy {
            return ChatBuddyModel(buddy:buddy)
        }
        return nil
    }
}

public struct ChatBuddy: GRDBRecord, TableRecord {
    public var id: Int64?
    public var uniqueId: String
    
    //var accountUniqueId: String?
    //var lastMessageIdentifier: String?
    //var messageDate = Date.distantPast
    //var isGroupThread = false
    //var muteExpiration: Date?
    //var modified: Date?
    
    var username: String
    var displayName: String?
    var composingMessageString: String?
    var isArchived = false
    var muteExpiration: Date?
    var currentMessageText: String?
    var expiresIn: String?
    var lastMessageId: String?
    var accountUniqueId: String?
    var avatarData: Data?
    var subscription: Int?
    var pending: Int?
    var vCardTemp: Data?
    var lastUpdatedvCardTemp: Date?
    var photoHash: String?
    var chatThreadId: Int64
    var modified: Date?
    var sharedGroups: [String]?

    public static var databaseTableName: String {
        "chatBuddy"
    }
    
    public init(uniqueId:String) {
        self.init(uniqueId: uniqueId, chatId: nil, username: "", displayName: nil, composingString: nil, muteExpiration: nil, currentMessageText: nil, expiresIn: nil, lastMessageId: nil, accountUniqueId: nil, avatarData: nil, subscription: nil, pending: nil, vCardTemp: nil, lastUpdatedvCardTemp: nil, photoHash: nil, modified: nil)
    }
    
    public init(uniqueId:String, chatId:Int64?, username:String, displayName:String?, composingString:String?, isArchived:Bool = false, muteExpiration:Date?, currentMessageText:String?, expiresIn:String?, lastMessageId:String?, accountUniqueId:String?, avatarData:Data?, subscription:Int?, pending:Int?, vCardTemp:Data?, lastUpdatedvCardTemp:Date?, photoHash: String?, modified: Date?) {
        self.uniqueId = uniqueId
        self.chatThreadId = chatId ?? -1
        self.username = username
        self.displayName = displayName
        self.composingMessageString = composingString
        self.isArchived = isArchived
        self.muteExpiration = muteExpiration
        self.currentMessageText = currentMessageText
        self.expiresIn = expiresIn
        self.lastMessageId = lastMessageId
        self.accountUniqueId = accountUniqueId
        self.avatarData = avatarData
        self.subscription = subscription
        self.pending = pending
        self.lastUpdatedvCardTemp = lastUpdatedvCardTemp
        self.photoHash = photoHash
        self.modified = Date()
        
        self.vCardTemp = vCardTemp
    }
    
    func touch() {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            let nowdate = Date()
            var bud = self
            do {
                bud.modified = nowdate
                try bud.update(transaction.database, columns: [Column("modified")])
            } catch {
                DDLogDebug("ChatBuddy.touch with error: \(error)")
            }
        })
    }
    
    static func buddyFromThread(_ thread: ChatThread) -> ChatBuddy? {
        var buddy: ChatBuddy?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                buddy = try ChatBuddy
                    .filter(Column("chatThreadId") == thread.id)
                    .fetchOne(transaction.database)
                if buddy == nil {
                    buddy = try ChatBuddy
                        .filter(Column("uniqueId") == thread.uniqueId)
                        .fetchOne(transaction.database)
                }
            })
        } catch {
            DDLogDebug("ChatBuddy.buddyFromThread with error: \(error)")
        }
        
        return buddy
    }
    
    public static func getBuddy(uniqueId: String) -> ChatBuddy? {
        var buddy:ChatBuddy?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                buddy = try ChatBuddy
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database) 
            })
        } catch {
            DDLogDebug("ChatBuddy.getBuddy with uniqueId error: \(error)")
        }

        return buddy
    }
    
    static func getAllBuddies(for account:ChatAccount, completion: @escaping ([ChatBuddy]) -> Void) {
        var buddies:[ChatBuddy] = []
        DBManager.sharedDB().grdbStorage.asyncRead(block: { transaction in
            do {
                let cbuddies = try ChatBuddy
                    .filter(Column("accountUniqueId") == account.uniqueId)
                    .fetchAll(transaction.database)
                
                buddies = cbuddies.filter({$0.username != account.username})
            } catch {
                DDLogDebug("ChatBuddy.getAllBuddies with error: \(error)")
            }
        }, completion: {
            completion(buddies)
        })
    }
}

extension ChatBuddy {
    static let messages = hasMany(ChatMessage.self)
    var messages: QueryInterfaceRequest<ChatMessage> {
        request(for: ChatBuddy.messages)
    }
    
    //static let thread = belongsTo(ChatThread.self)//belongsTo(ChatThread.self)
    //var thread: QueryInterfaceRequest<ChatThread> {
    //    request(for: ChatBuddy.thread)
    //}
}

