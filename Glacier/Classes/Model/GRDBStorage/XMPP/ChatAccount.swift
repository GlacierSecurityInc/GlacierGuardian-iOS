//
//  ChatAccount.swift
//  Glacier
//
//  Created by andyfriedman on 9/18/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import GRDB
import SAMKeychain
import CryptoKit
import CocoaLumberjack
import XMPPFramework

@objc open class ChatAccountModel: GRDBModel {
    @objc public static let defaultPort:UInt = 80
    public static let accountImage = UIImage(named: "glacier.png", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
    var grdbRecord:ChatAccount?
    
    convenience init(account:ChatAccount) {
        self.init(uniqueId: account.uniqueId)
        self.grdbRecord = account
    }
    
    @objc convenience init(username:String) {
        self.init()
        grdbRecord = ChatAccount(uniqueId: self.uniqueId, username: username, domain: GlacierInfo.defaultHost(), resource: ChatAccountModel.newResource(), port: Int(Self.defaultPort), displayName: username, loginDate: nil, lastHistoryFetchDate: nil, pushPubsubEndpoint: nil, pushPubsubNode: nil, org: nil, apiKey:nil, avatarData: nil, vCardTemp: nil, lastUpdatedvCardTemp: nil, photoHash: nil, modified: nil)
    }
}

#if !TARGET_IS_EXTENSION
extension ChatAccountModel: ChatvCard {
    @objc public var vCardTemp: XMPPvCardTemp? {
        get {
            var vtemp = XMPPvCardTemp.v()
            //vtemp.setNameAndAvatar(self.grdbRecord?.displayName, avatar: self.grdbRecord?.avatarData)
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
            BuddyCache.shared().setWaitingForChatvCardTempFetch(waiting: newValue, vCardId: self.uniqueId, collection: ChatAccountModel.collection())
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
            
            if let aData = newValue, aData.count > 0, let data = aData as? NSData, let sha1 = Insecure.SHA1.hash(data: data) as? NSData {
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

extension ChatAccountModel {
    @objc static func newResource() -> String {
        let r = arc4random() % 99999
        let xresource = GlacierInfo.xmppResource
        return String(format: "%@%d", xresource, r)
    }
    
    func protocolClass() -> AnyClass? {
    #if TARGET_IS_EXTENSION
        return nil
    #else
        return XMPPManager.self
    #endif
    }
    
    @objc func removeKeychainPassword(_ error:NSError?) throws {
        var error: NSError?
        let result = SAMKeychain.deletePassword(forService: kOTRServiceName, account: self.uniqueId, accessGroup: kGlacierKeyGroup, error:&error) //need accessGroup: kGlacierKeyGroup?
        if let error = error {
            throw KeychainError.failure(description: "error deleting password: \(error)")
        }
        guard result else {
            throw KeychainError.failure(description: "could not delete password")
        }
        
        //return result
    }

    /*@objc public func setPassword(_ password:String) {
        if password.count == 0 {
            //NSAssert(password.length > 0, @"Improperly removing password!");
            DDLogError("Improperly removing password! To remove password call removeKeychainPassword!")
            return
        }
        
        var error: NSError?
        let result = SAMKeychain.setPassword(password, forService: kOTRServiceName, account: self.uniqueId, error:&error)
        if result == false {
            DDLogError("Error saving password to keychain: \(String(describing: error?.localizedDescription)) \(String(describing: error?.userInfo))")
            //[GlacierLog glogWithLogMsg:@"Error retrieving account password from keychain" detail:self.uniqueId];
        }
    }

    @objc public func password() -> String? {
        var error: NSError?
        let password = SAMKeychain.password(forService: kOTRServiceName, account: self.uniqueId, error:&error)
        if (error != nil) {
            DDLogError("Error retreiving password from keychain: \(String(describing: error?.localizedDescription)) \(String(describing: error?.userInfo))")
            //[GlacierLog glogWithLogMsg:@"Error retrieving account password from keychain" detail:self.uniqueId];
        }
        
        return password
    }*/
    
    @objc public var password: String? {
        get {
            var error: NSError?
            let password = SAMKeychain.password(forService: kOTRServiceName, account: self.uniqueId, accessGroup: kGlacierKeyGroup, error:&error)
            if (error != nil) {
                DDLogError("Error retreiving password from keychain: \(String(describing: error?.localizedDescription)) \(String(describing: error?.userInfo))")
                //[GlacierLog glogWithLogMsg:@"Error retrieving account password from keychain" detail:self.uniqueId];
            }
            
            return password
        }
        set {
            guard let pass = newValue else { return }
            if pass.count == 0 {
                //NSAssert(password.length > 0, @"Improperly removing password!");
                DDLogError("Improperly removing password! To remove password call removeKeychainPassword!")
                return
            }
            
            var error: NSError?
            let result = SAMKeychain.setPassword(pass, forService: kOTRServiceName, account: self.uniqueId, accessGroup:kGlacierKeyGroup, error:&error)
            if result == false {
                DDLogError("Error saving password to keychain: \(String(describing: error?.localizedDescription)) \(String(describing: error?.userInfo))")
                //[GlacierLog glogWithLogMsg:@"Error retrieving account password from keychain" detail:self.uniqueId];
            }
        }
    }
    
    @objc public var domain: String? {
        get {
            return self.grdbRecord?.domain
        }
        set {
            self.grdbRecord?.domain = newValue
        }
    }

    @objc public var bypassNetworkCheck: Bool {
        get {
            return self.grdbRecord?.bypassNetworkCheck ?? true
        }
        set {
            self.grdbRecord?.bypassNetworkCheck = newValue
        }
    }
    
    @objc public var useStageConsole: Bool {
        get {
            return self.grdbRecord?.useStageConsole ?? false
        }
        set {
            self.grdbRecord?.useStageConsole = newValue
        }
    }
    
    @objc public var disableLinkFetching: Bool {
        get {
            return self.grdbRecord?.disableAutomaticURLFetching ?? false
        }
        set {
            self.grdbRecord?.disableAutomaticURLFetching = newValue
        }
    }
    
    @objc public var isReadReceiptsOn: Bool {
        get {
            return self.grdbRecord?.isReadReceiptsOn ?? true
        }
        set {
            self.grdbRecord?.isReadReceiptsOn = newValue
        }
    }
    
    @objc public var smsEnabled: Bool {
        get {
            return self.grdbRecord?.smsEnabled ?? false
        }
        set {
            self.grdbRecord?.smsEnabled = newValue
        }
    }
    
    @objc public var rebootReminderEnabled: Bool {
        get {
            return self.grdbRecord?.rebootReminderEnabled ?? false
        }
        set {
            self.grdbRecord?.rebootReminderEnabled = newValue
        }
    }
    
    @objc public var trackingEnabled: Bool {
        get {
            return self.grdbRecord?.trackingEnabled ?? false
        }
        set {
            self.grdbRecord?.trackingEnabled = newValue
        }
    }
    
    @objc public var forceTracking: Bool {
        get {
            return self.grdbRecord?.forceTracking ?? false
        }
        set {
            self.grdbRecord?.forceTracking = newValue
        }
    }
    
    @objc public var trackingInterval: Int {
        get {
            return self.grdbRecord?.trackingInterval ?? 300
        }
        set {
            self.grdbRecord?.trackingInterval = newValue
        }
    }
    
    @objc public var trackingOn: Bool {
        get {
            return self.grdbRecord?.trackingOn ?? false
        }
        set {
            self.grdbRecord?.trackingOn = newValue
        }
    }
    
    @objc public var resource: String? {
        get {
            return self.grdbRecord?.resource
        }
        set {
            self.grdbRecord?.resource = newValue ?? ""
        }
    }
    
    @objc public var loginDate: Date? {
        get {
            return self.grdbRecord?.loginDate
        }
        set {
            self.grdbRecord?.loginDate = newValue ?? Date()
        }
    }
    
    @objc public var port: Int {
        get {
            return self.grdbRecord?.port ?? Int(ChatAccountModel.defaultPort)
        }
        set {
            self.grdbRecord?.port = newValue
        }
    }
    
    @objc public var pushPubsubEndpoint: String? {
        get {
            return self.grdbRecord?.pushPubsubEndpoint
        }
        set {
            self.grdbRecord?.pushPubsubEndpoint = newValue
        }
    }
    
    @objc public var pushPubsubNode: String? {
        get {
            return self.grdbRecord?.pushPubsubNode
        }
        set {
            self.grdbRecord?.pushPubsubNode = newValue
        }
    }
    
    /*@objc public var avatarData: Data? {
        get {
            return self.grdbRecord?.avatarData
        }
    }*/
    
    @objc public var accountId: Int64 {
        get {
            return self.grdbRecord?.id ?? 0
        }
    }
}

extension ChatAccountModel {
    static var currentAccount:ChatAccountModel?
    
    @objc static func getXMPPAccount(uniqueId: String) -> ChatAccountModel? {
        if let cacct = currentAccount, cacct.uniqueId == uniqueId {
            return cacct
        }
        
        var acct:ChatAccountModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let codable = try ChatAccount
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database) {
                    acct = ChatAccountModel(account: codable)
                    currentAccount = acct
                }
            })
        } catch {
            DDLogDebug("ChatAccountModel.getXMPPAccount with uniqueId error: \(error)")
        }

        return acct
    }
    
    @objc static func getXMPPAccount(uniqueId: String, transaction:GRDBReadTransaction) -> ChatAccountModel? {
        if let cacct = currentAccount, cacct.uniqueId == uniqueId {
            return cacct
        }
        
        var acct:ChatAccountModel?
        do {
            if let codable = try ChatAccount
                .filter(Column("uniqueId") == uniqueId)
                .fetchOne(transaction.database) {
                acct = ChatAccountModel(account: codable)
                currentAccount = acct
            }
        } catch {
            DDLogDebug("ChatAccountModel.getXMPPAccount with uniqueId error: \(error)")
        }

        return acct
    }
    
    @objc static func getChatAccount(_ acctId: Int64) -> ChatAccountModel? {
        if let cacct = currentAccount, cacct.grdbRecord?.id == acctId {
            return cacct
        }
        
        var acct:ChatAccountModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let codable = try ChatAccount
                    .filter(Column("id") == acctId)
                    .fetchOne(transaction.database) {
                    acct = ChatAccountModel(account: codable)
                    currentAccount = acct
                }
            })
        } catch {
            DDLogDebug("ChatAccountModel.getXMPPAccount with uniqueId error: \(error)")
        }

        return acct
    }
    
    @objc public func touchAccount() {
        if let rec = self.grdbRecord {
            rec.touch()
        }
    }
    
    @objc var accountType: ChatAccountType {
        return ChatAccountType.jabber
    }
    
    @objc static func countXMPPAccounts() -> Int {
        var count = 0
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                count = try ChatAccount
                    .fetchCount(transaction.database)
            })
        } catch {
            DDLogDebug("ChatAccountModel.countXMPPAccounts error: \(error)")
        }

        return count
    }
    
    @objc static func firstAccount() -> ChatAccountModel? {
        var account:ChatAccountModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let caccount = try ChatAccount
                    .fetchOne(transaction.database) {
                    account = ChatAccountModel(account: caccount)
                }
            })
        } catch {
            DDLogDebug("ChatAccountModel.firstAccount error: \(error)")
        }

        return account
    }
    
    @objc static func allXMPPAccounts() -> [ChatAccountModel] {
        var accounts:[ChatAccountModel] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let codables = try ChatAccount
                    .fetchAll(transaction.database)
                for codable in codables {
                    accounts.append(ChatAccountModel(account: codable))
                }
            })
        } catch {
            DDLogDebug("ChatAccountModel.allXMPPAccounts error: \(error)")
        }

        return accounts
    }
    
    @objc static func allAutoLoginAccounts() -> [ChatAccountModel] {
        var accounts:[ChatAccountModel] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let codables = try ChatAccount
                    .filter(Column("autologin") == true)
                    .fetchAll(transaction.database)
                for codable in codables {
                    accounts.append(ChatAccountModel(account: codable))
                }
            })
        } catch {
            DDLogDebug("ChatAccountModel.allAutoLoginAccounts error: \(error)")
        }

        return accounts
    }
    
    @objc static func allXMPPAccounts(username: String) -> [ChatAccountModel] {
        var accounts:[ChatAccountModel] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let codables = try ChatAccount
                    .filter(Column("username") == username)
                    .fetchAll(transaction.database)
                for codable in codables {
                    accounts.append(ChatAccountModel(account: codable))
                }
            })
        } catch {
            DDLogDebug("ChatAccountModel.allXMPPAccounts with username error: \(error)")
        }

        return accounts
    }
    
    @objc static func accountForStream(_ stream:XMPPStream?) -> ChatAccountModel? {
        guard let stag = stream?.tag  as? String else { return nil }
        
        return ChatAccountModel.getXMPPAccount(uniqueId: stag)
    }
    
    @objc func saveXMPPAccount(){
        do {
            try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                self.grdbRecord?.grdbSave(transaction: transaction)
                ChatAccountModel.currentAccount = nil
            })
        } catch {
            DDLogDebug("ChatAccountModel.save with error: \(error)")
        }
    }
    
    @objc func saveXMPPAccountAsync(){
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            self.grdbRecord?.grdbSave(transaction: transaction)
            ChatAccountModel.currentAccount = nil
        })
    }
    
    @objc func removeXMPPAccount(){
        do {
            try self.removeKeychainPassword(nil)
        } catch {
            DDLogDebug("ChatAccountModel.remove account, removeKeychainPassword with error: \(error)")
        }
        
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            self.grdbRecord?.grdbRemove(transaction: transaction)
        })
    }
}

extension ChatAccountModel: UserInfoProfile {
    
    @objc public var displayName: String {
        get {
            guard let grec = grdbRecord else { return "" }
            if let displayName = grec.displayName, displayName.count > 0, !(displayName == grec.username) {
                return displayName
            }
            if let user = grec.username.otr_displayName() {
                return user
            }
            return grec.displayName!
        }
        set {
            self.grdbRecord?.displayName = newValue
        }
    }
    
    @objc public var username: String {
        get {
            return self.grdbRecord?.username ?? ""
        }
        set {
            self.grdbRecord?.username = newValue
        }
    }
    
    @objc public var bareJID: XMPPJID? {
        return XMPPJID(string: self.username)
    }
    
#if !TARGET_IS_EXTENSION
    public var avatarImage: UIImage {
        get {
            //self.getAvatarImage()
            let grec = self.grdbRecord!
            return OTRImages.avatarImage(withUniqueIdentifier: self.uniqueId, avatarData: grec.avatarData, displayName: grec.displayName, username: grec.username)
        }
    }
    
    public var avatarBorderColor: UIColor? {
        get {
            if let xmpp = OTRProtocolManager.sharedInstance().xmppManager(forChatAccount: self) {
                if (xmpp.loginStatus == OTRLoginStatus.authenticated) {
                    return Colors.color(with:ThreadStatus.available)
                }
            }
            return nil
        }
    }
#endif
}

struct ChatAccount: GRDBRecord, TableRecord {
    public var id: Int64?
    public var uniqueId: String
    var username: String
    var domain: String?
    var resource: String
    var port: Int
    var accountType: Int
    var displayName: String?
    var rememberPassword = true
    var autologin = true
    var bypassNetworkCheck = true
    var useStageConsole = false
    var smsEnabled = false
    var rebootReminderEnabled = true
    var trackingEnabled = false
    var forceTracking = false
    var trackingOn = false
    var trackingInterval = 300
    var disableAutomaticURLFetching = false
    var isReadReceiptsOn = true
    var loginDate: Date?
    var lastHistoryFetchDate: Date?
    var pushPubsubEndpoint: String?
    var pushPubsubNode: String?
    var org: String?
    var apiKey: String?
    var avatarData:Data?
    var vCardTemp:Data?
    var lastUpdatedvCardTemp:Date?
    var photoHash:String?
    var password:String?
    var modified: Date?

    public static var databaseTableName: String {
        "chatAccount"
    }
    
    public init(uniqueId:String, username:String, domain:String?, resource:String, port:Int, displayName:String?, loginDate:Date?, lastHistoryFetchDate:Date?, pushPubsubEndpoint:String?, pushPubsubNode: String?, org:String?, apiKey:String?, avatarData:Data?, vCardTemp:Data?, lastUpdatedvCardTemp:Date?, photoHash: String?, modified: Date?) {
        self.uniqueId = uniqueId
        
        self.username = username
        self.domain = domain
        self.resource = resource
        self.port = port
        self.accountType = 3 //jabber
        self.displayName = displayName
        self.loginDate = loginDate
        self.lastHistoryFetchDate = lastHistoryFetchDate
        self.pushPubsubEndpoint = pushPubsubEndpoint
        self.pushPubsubNode = pushPubsubNode
        self.org = org
        self.apiKey = apiKey
        self.lastUpdatedvCardTemp = lastUpdatedvCardTemp
        self.photoHash = photoHash
        self.avatarData = avatarData
        self.vCardTemp = vCardTemp
        self.modified = Date()
    }
    
    func touch() {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            let nowdate = Date()
            var account = self
            do {
                account.modified = nowdate
                try account.update(transaction.database, columns: [Column("modified")])
            } catch {
                DDLogDebug("ChatAccount.touch with error: \(error)")
            }
        })
    }
}

extension ChatAccount {
    static let threads = hasMany(ChatThread.self)
    var threads: QueryInterfaceRequest<ChatThread> {
        request(for: ChatAccount.threads)
    }
}
