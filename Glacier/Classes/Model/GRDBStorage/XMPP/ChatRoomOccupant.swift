//
//  ChatRoomOccupant.swift
//  Glacier
//
//  Created by andyfriedman on 9/20/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import GRDB
import XMPPFramework


@objc public enum RoomOccupantRole:Int {
    case none = 0
    case participant = 1
    case moderator = 2
    case visitor = 3
    
    public init(stringValue: String) {
        self = RoomOccupantRoleHelper.role(withString: stringValue)
    }
}

// Helper class to create from string, callable from obj-c
@objc public class RoomOccupantRoleHelper: NSObject {
    @objc public static func role(withString role:String) -> RoomOccupantRole {
        switch role {
        case "moderator":
            return RoomOccupantRole.moderator
        case "participant":
            return RoomOccupantRole.participant
        case "visitor":
            return RoomOccupantRole.visitor
        default:
            return RoomOccupantRole.none
        }
    }
}

@objc public enum RoomOccupantAffiliation:Int {
    case none = 0
    case outcast = 1
    case member = 2
    case admin = 3
    case owner = 4
    /// Value used when updating the DB. This enables us to remove occupants that used to be
    /// members, admins or owners, but are no longer that (e.g. they may have been kicked).
    /// Before fetching the lists for room [members, admins, owners] we mark all existing
    /// [members, admins, owners] as 'transient'. We then update the database from the lists.
    /// After this, we remove all occupants with affiliation 'transient', since they are no
    /// longer in the lists (or their affiliation would have been updated).
    case transient = 99
    
    public func isOwner() -> Bool {
        switch self {
        case .owner: return true
        default: return false
        }
    }
    
    public init(stringValue: String) {
        self = RoomOccupantAffiliationHelper.affiliation(withString: stringValue)
    }
    
    public var stringValue:String {
        get {
            switch self {
            case .owner: return "owner"
            case .admin: return "admin"
            case .member: return "member"
            case .outcast: return "outcast"
            default: return "none"
            }
        }
    }
}

// Helper class to create from string, callable from obj-c
@objc public class RoomOccupantAffiliationHelper: NSObject {
    @objc public static func affiliation(withString affiliation:String) -> RoomOccupantAffiliation {
        switch affiliation {
        case "owner":
            return RoomOccupantAffiliation.owner
        case "admin":
            return RoomOccupantAffiliation.admin
        case "member":
            return RoomOccupantAffiliation.member
        case "outcast":
            return RoomOccupantAffiliation.outcast
        default:
            return RoomOccupantAffiliation.none
        }
    }
}

@objc open class ChatRoomOccupantModel: GRDBModel {
    var grdbRecord:ChatRoomOccupant?
    
    convenience init(occupant:ChatRoomOccupant) {
        self.init(uniqueId: occupant.uniqueId)
        self.grdbRecord = occupant
    }
}

extension ChatRoomOccupantModel {
    
    /** This is the role of the occupant in the room */
    @objc open var role:RoomOccupantRole {
        get {
            guard let orole = self.grdbRecord?.role else {
                return .none
            }
            return RoomOccupantRole(rawValue: orole) ?? .none
        }
        set {
            self.grdbRecord?.role = newValue.rawValue
        }
    }

    /** This is the affiliation of the occupant in the room */
    @objc open var affiliation:RoomOccupantAffiliation {
        get {
            guard let affil = self.grdbRecord?.affiliation else {
                return .none
            }
            return RoomOccupantAffiliation(rawValue: affil) ?? .none
        }
        set {
            self.grdbRecord?.affiliation = newValue.rawValue
        }
    }
    
    /** Aka "nickname". This is the name your known as in the room. Seems to be username without domain */
    @objc open var roomName:String? {
        return jid?.resource
    }
    
    /** This is the JID of the participant as it's known in the room i.e. groupchat@conference.domain.com/user123 */
    @objc open var jid: XMPPJID? {
        get {
            guard let jidString = self.grdbRecord?.jid else {  //
                return nil
            }
            return XMPPJID(string: jidString)
        }
        set {
            self.grdbRecord?.jid = newValue?.full
        }
    }
    
    /** When given by the server we get the room participants real JID*/
    @objc open var realJID:XMPPJID? {
        get {
            guard let jidString = self.grdbRecord?.realJid else {  //_realJID else {
                return nil
            }
            return XMPPJID(string: jidString)?.bareJID
        }
        set {
            self.grdbRecord?.realJid = newValue?.bare
        }
    }
    
    /** When given by the server we get the room participants real JID*/
    @objc open var buddyUniqueId:String? {
        get {
            return self.grdbRecord?.buddyUniqueId
        }
        set {
            self.grdbRecord?.buddyUniqueId = newValue
        }
    }
    
#if !TARGET_IS_EXTENSION
    @objc open func avatarImage() -> UIImage {
        return OTRImages.avatarImage(withUniqueIdentifier: self.uniqueId, avatarData: nil, displayName: roomName, username: self.realJID?.full)
    }
#endif
    
    // changed subject to name, reqts to owner only
    public func canModifyName() -> Bool {
        // TODO - Check muc#roomconfig_changesubject, participants may be allowed to change subject based on config!
        return [RoomOccupantAffiliation.owner].contains(self.affiliation)
    }
    
    public func canInviteOthers() -> Bool {
        // TODO - participants may be allowed
        return self.role == .moderator || [RoomOccupantAffiliation.owner, RoomOccupantAffiliation.admin].contains(self.affiliation)
    }
    
    //https://xmpp.org/extensions/xep-0045.html#grantadmin
    //An owner can grant admin status to a member or an unaffiliated user; this is done by changing the user's affiliation to "admin":
    public func canGrantAdmin(_ occupant:ChatRoomOccupantModel) -> Bool {
        let ownerAffiliation = (self.affiliation == .owner)
        return ownerAffiliation && (occupant.affiliation == .member || occupant.affiliation == .none)
    }

    public func canRevokeMembership(_ occupant:ChatRoomOccupantModel) -> Bool {
        if occupant.affiliation == .owner {
            return false
        }
        if self.affiliation == .owner {
            return true
        }
        if self.affiliation == .admin && occupant.affiliation != .admin {
            return true
        }
        return false
    }

    //https://xmpp.org/extensions/xep-0045.html#ban
    //An admin or owner can ban one or more users from a room. The ban MUST be performed based on the occupant's bare JID. In order to ban a user, an admin MUST change the user's affiliation to "outcast".
    //As with Kicking an Occupant, a user cannot be banned by an admin with a lower affiliation. Therefore, if an admin attempts to ban an owner, the service MUST deny the request and return a <not-allowed/> error to the sender
    public func canBan(_ occupant:ChatRoomOccupantModel) -> Bool {
        return self.affiliation == .owner || (self.affiliation == .admin && occupant.affiliation != .owner)
    }
}

extension ChatRoomOccupantModel {
    @objc public convenience init(jid: XMPPJID?, roomUniqueId: String, uniqueId: String) {
        self.init(uniqueId: uniqueId)
        self.grdbRecord = ChatRoomOccupant(uniqueId: self.uniqueId, roomId: nil, jid: jid?.full, roomUniqueId: roomUniqueId, buddyUniqueId: nil, realJid: nil, role: nil, affiliation: nil)
    }
    
    // jid is the full JID of the room participant e.g. groupchat@conference.domain.com/user123
    @objc public convenience init(jid: XMPPJID?, roomUniqueId: String) {
        self.init()
        self.grdbRecord = ChatRoomOccupant(uniqueId: self.uniqueId, roomId: nil, jid: jid?.full, roomUniqueId: roomUniqueId, buddyUniqueId: nil, realJid: nil, role: nil, affiliation: nil)
    }
    
    public func buddy() -> ChatBuddy? {
        if let buddyUniqueId = self.grdbRecord?.buddyUniqueId {
            return ChatBuddy.getBuddy(uniqueId: buddyUniqueId)
        }
        return nil
    }
    
    @objc public static func occupant(jid: XMPPJID?,
                                      realJID: XMPPJID?,
                                      roomJID: XMPPJID,
                                      accountId: String,
                                      createIfNeeded: Bool) -> ChatRoomOccupantModel? {
        return Self.occupant(jid: jid, realJID: realJID, roomJID: roomJID, accountId: accountId, createIfNeeded: createIfNeeded, transaction: nil)
    }
    
    @objc public static func occupant(jid: XMPPJID?,
                               realJID: XMPPJID?,
                               roomJID: XMPPJID,
                               accountId: String,
                            createIfNeeded: Bool, transaction: GRDBWriteTransaction?) -> ChatRoomOccupantModel? {
        assert(jid != nil || realJID != nil, "Cannot create occupant if both jid and realJID are nil!")
        // Bail out if both paramters are nil
        if jid == nil && realJID == nil {
            DDLogError("Cannot create occupant if both jid and realJID are nil!")
            return nil
        }
        let roomUniqueId = ChatRoomModel.createUniqueId(accountId, jid: roomJID.bare)
        var matchingOccupants: [ChatRoomOccupantModel] = []
        
        let jidColumn = Column("jid")
        let realJidColumn = Column("realJid")
        var conditions:[SQLSpecificExpressible] = []
        
        if let jid = jid, let realJID = realJID {
            conditions.append(realJidColumn == realJID.bare)
            conditions.append(jidColumn.like(jid.full))
        } else if let jid = jid {
            conditions.append(jidColumn.like(jid.full))
        } else if let realJID = realJID {
            conditions.append(realJidColumn == realJID.bare)
        }
        
        do {
            if let trans = transaction {
                let records = try ChatRoomOccupant
                    .filter(Column("roomUniqueId") == roomUniqueId)
                    .filter(conditions.joined(operator: .or))
                    .fetchAll(trans.database)
                for record in records {
                    if record.jid != nil || record.realJid != nil {
                        matchingOccupants.append(ChatRoomOccupantModel(occupant: record))
                    }
                }
            } else {
                try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                    let records = try ChatRoomOccupant
                        .filter(Column("roomUniqueId") == roomUniqueId)
                        .filter(conditions.joined(operator: .or))
                        .fetchAll(transaction.database)
                    for record in records {
                        if record.jid != nil || record.realJid != nil {
                            matchingOccupants.append(ChatRoomOccupantModel(occupant: record))
                        }
                    }
                })
            }
        } catch {
            DDLogError("ChatRoomOccupantModel.occupant error: \(error)")
            return nil
        }
        
        if matchingOccupants.count > 1 {
            DDLogWarn("WARN: More than one ChatRoomOccupantModel matching query")

            // if we have a corrupted database with extra occupants, try to filter
            // out some of the bad ones
            let filtered = matchingOccupants.filter({ (occupant) -> Bool in
                occupant.jid != nil
            })
            let toremove = matchingOccupants.filter({ (occupant) -> Bool in
                occupant.jid == nil
            })
            if filtered.count > 0 {
                matchingOccupants = filtered
                for remove in toremove {
                    if let transaction = transaction {
                        remove.grdbRecord?.grdbRemove(transaction: transaction)
                    } else {
                        remove.remove()
                    }
                }
            }
            
            // get most recent, probably has 
        }
        var _occupant: ChatRoomOccupantModel? = matchingOccupants.first
        var created = false
        if _occupant == nil {
            if createIfNeeded {
                _occupant = ChatRoomOccupantModel(jid: jid, roomUniqueId: roomUniqueId)
                created = true
            } else {
                return nil
            }
        } else {
//#if !TARGET_IS_EXTENSION
//            _occupant = _occupant?.copyAsSelf()
//#else
//            _occupant = _occupant?.copy() as? Self
//#endif
        }
        guard let occupant = _occupant else {
            return nil
        }
        
        // sometimes a bad database makes this nil
        if occupant.jid == nil, let jid = jid {
            occupant.jid = jid
        }
        
        // Set realJID?
        if let realJID = realJID {
            occupant.realJID = realJID
        }

        // While we're at it, match room occupant with a buddy on our roster if possible
        // This should probably be moved elsewhere
        if let transaction = transaction {
            if let realJID = occupant.realJID, let buddy = ChatBuddyModel.fetchBuddy(jid: realJID, accountUniqueId: accountId, transaction: transaction) {
                occupant.grdbRecord?.buddyUniqueId = buddy.uniqueId
            } else if let resource = jid?.resource, let buddy = ChatBuddyModel.fetchBuddyFrom(displayName: resource, accountUniqueId: accountId, transaction: transaction) {
                occupant.grdbRecord?.buddyUniqueId = buddy.uniqueId
                if occupant.realJID == nil {
                    occupant.realJID = XMPPJID(string: buddy.username)
                }
            }
        } else {
            if let realJID = occupant.realJID, let buddy = ChatBuddyModel.fetchBuddy(jid: realJID, accountUniqueId: accountId) {
                occupant.grdbRecord?.buddyUniqueId = buddy.uniqueId
            } else if let resource = jid?.resource, let buddy = ChatBuddyModel.fetchBuddyFrom(displayName: resource, accountUniqueId: accountId) {
                occupant.grdbRecord?.buddyUniqueId = buddy.uniqueId
                if occupant.realJID == nil {
                    occupant.realJID = XMPPJID(string: buddy.username)
                }
            }
        }
        
        if created, let real = occupant.realJID?.bare {
            var existingOcc:ChatRoomOccupant?
            do {
                if let transaction = transaction {
                    existingOcc = try ChatRoomOccupant
                        .filter(Column("roomUniqueId") == roomUniqueId)
                        .filter(Column("realJid") == real)
                        .fetchOne(transaction.database)
                } else {
                    try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                        existingOcc = try ChatRoomOccupant
                            .filter(Column("roomUniqueId") == roomUniqueId)
                            .filter(Column("realJid") == real)
                            .fetchOne(transaction.database)
                    })
                }
            } catch {
                DDLogError("ChatRoomOccupantModel.occupant error: \(error)")
                return nil
            }
            
            if var existing = existingOcc, let newjid = occupant.grdbRecord?.jid {
                existing.jid = newjid
                return ChatRoomOccupantModel(occupant: existing)
            }
        }
        
        return occupant
    }
    
    /*public func copyAsSelf() -> Self? {
        return self.copy() as? Self
    }*/
    
    @objc public static func allXMPPRoomOccupants(for roomId: String) -> [ChatRoomOccupantModel] {
        var occupants:[ChatRoomOccupantModel] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let records = try ChatRoomOccupant
                    .filter(Column("roomUniqueId") == roomId)
                    .order(Column("realJid"))
                    .fetchAll(transaction.database)
                for record in records {
                    occupants.append(ChatRoomOccupantModel(occupant: record))
                }
            })
        } catch {
            DDLogError("ChatRoomOccupantModel.allXMPPRoomOccupants error: \(error)")
        }
        
        return occupants
    }
    
    @objc public static func allXMPPRoomOccupants(for roomId: String, transaction: GRDBReadTransaction) -> [ChatRoomOccupantModel] {
        var occupants:[ChatRoomOccupantModel] = []
        do {
            let records = try ChatRoomOccupant
                .filter(Column("roomUniqueId") == roomId)
                .order(Column("realJid"))
                .fetchAll(transaction.database)
            for record in records {
                occupants.append(ChatRoomOccupantModel(occupant: record))
            }
        } catch {
            DDLogError("ChatRoomOccupantModel.allXMPPRoomOccupants error: \(error)")
        }
        
        return occupants
    }
    
    @objc public static func numberOfOccupants(for roomId: String) -> Int {
        var count = 0
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                count = try ChatRoomOccupant
                    .filter(Column("roomUniqueId") == roomId)
                    .fetchCount(transaction.database)
            })
        } catch {
            DDLogError("ChatRoomOccupantModel.numberOfOccupants error: \(error)")
        }
        
        return count
    }
    
    @objc public func save() {
        self.grdbRecord?.storeInGRDB()
    }
    
    @objc public func remove() {
        self.grdbRecord?.remove(completion: {})
    }
}

struct ChatRoomOccupant: GRDBRecord {
    var id: Int64?
    var uniqueId: String
    var jid: String?
    var roomUniqueId: String?
    var chatRoomId: Int64
    var buddyUniqueId: String?
    var realJid: String?
    //var roomName: String?
    var role: Int?
    var affiliation: Int?
    
    public static var databaseTableName: String {
        "chatRoomOccupant"
    }
    
    public init(uniqueId:String, roomId:Int64?, jid:String?, roomUniqueId:String?, buddyUniqueId:String?, realJid:String?, role:Int?, affiliation:Int?) {
        self.uniqueId = uniqueId
        self.chatRoomId = roomId ?? -1
        self.jid = jid
        self.roomUniqueId = roomUniqueId
        self.buddyUniqueId = buddyUniqueId
        self.realJid = realJid
        //self.roomName = occupant.roomName
        self.role = role
        self.affiliation = affiliation
    }
}

extension ChatRoomOccupant: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(uniqueId)
    }

    public static func == (lhs: ChatRoomOccupant, rhs: ChatRoomOccupant) -> Bool {
        lhs.uniqueId == rhs.uniqueId
    }
}
