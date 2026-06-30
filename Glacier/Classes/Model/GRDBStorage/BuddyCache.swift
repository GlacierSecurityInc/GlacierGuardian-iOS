//
//  BuddyCache.swift
//  Glacier
//
//  Created by andyfriedman on 9/14/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation

extension Notification.Name {
    /// Posted on main queue when a 1:1 buddy's chat state changes. UserInfo: ["buddyId": String, "chatState": Int]
    static let GlacierBuddyChatStateDidChange = Notification.Name("GlacierBuddyChatStateDidChange")
    
    /// Posted on main queue when the typing occupant set for a room changes. UserInfo: ["roomId": String, "typingNames": [String]]
    static let GlacierRoomTypingOccupantsDidChange = Notification.Name("GlacierRoomTypingOccupantsDidChange")
}

@objc open class BuddyCache: NSObject {
    private static let sharedBuddyCache = BuddyCache()
    private let queue = DispatchQueue(label: "BuddyCache.queue", attributes: .concurrent)
    
    var chatStates: [String:NSNumber] = [:]
    var lastSentChatStates: [String:NSNumber] = [:]
    var statusMessages: [String:String] = [:]
    var threadStatuses: [String:[String:NSNumber]] = [:]
    var waitingForvCardTempFetch: [String:NSNumber] = [:]
    var lastSeenDates: [String:Date] = [:]
    var roomProperties: [String:RoomRuntimeProperties] = [:]
    
    /// roomId -> [occupantJID: displayName]
    var roomTypingOccupants: [String: [String: String]] = [:]
    
    @objc public class func shared() -> BuddyCache {
        return sharedBuddyCache
    }
    
    /*public init() {
        
    }*/

    //#pragma mark Setters/Getters

    @objc func setChatState(_ chatState:ChatState, buddyId:String) {
        queue.async(flags: .barrier) {
            self.chatStates.updateValue(NSNumber(value: chatState.rawValue), forKey: buddyId)
            
            let stateRaw = chatState.rawValue
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .GlacierBuddyChatStateDidChange,
                    object: nil,
                    userInfo: ["buddyId": buddyId, "chatState": stateRaw]
                )
            }
        }
    }

    func chatState(buddy: ChatBuddy) -> ChatState {
        var chatState:ChatState = .unknown
        queue.sync {
            if let state = self.chatStates[buddy.uniqueId] {
                chatState = ChatState(rawValue: state.intValue) ?? .unknown
            }
        }
        return chatState
    }

    @objc func setLastSentChatState(_ lastSentChatState:ChatState, buddy:ChatBuddyModel) {
        queue.async(flags: .barrier) {
            self.lastSentChatStates.updateValue(NSNumber(value: lastSentChatState.rawValue), forKey: buddy.uniqueId)
            buddy.touchBuddy()
        }
    }

    @objc func lastSentChatState(buddy:ChatBuddyModel) -> ChatState {
        var lastSentChatState:ChatState = .unknown
        queue.sync {
            if let state = self.lastSentChatStates[buddy.uniqueId] {
                lastSentChatState = ChatState(rawValue: state.intValue) ?? .unknown
            }
        }
        return lastSentChatState
    }

    @objc func setStatusMessage(_ statusMessage:String?, buddyId:String) {
        
        queue.async(flags: .barrier) {
            if let status = statusMessage {
                self.statusMessages.updateValue(status, forKey: buddyId)
            } else {
                self.statusMessages.removeValue(forKey: buddyId)
            }
        }
    }

    func statusMessage(buddy:ChatBuddy) -> String? {
        var statusMessage:String?
        queue.sync {
            statusMessage = self.statusMessages[buddy.uniqueId]
        }
        return statusMessage
    }

    @objc func setThreadStatus(_ status:ThreadStatus, buddyId:String, resource:String?) {
        var buddyDict:[String:NSNumber]?
        queue.sync {
            buddyDict = self.threadStatuses[buddyId]
        }
        if buddyDict == nil {
            buddyDict = [:]
        }
        
        //var rsrc = resource
        queue.async(flags: .barrier) {
            if let resource = resource {
                buddyDict?.updateValue(NSNumber(value: status.rawValue), forKey: resource)
            }
            
            if resource == nil {
                self.threadStatuses.removeValue(forKey: buddyId)
            }
            
            if let bdict = buddyDict {
                self.threadStatuses.updateValue(bdict, forKey: buddyId)
            }
        }
    }

    func threadStatus(buddyId:String) -> ThreadStatus {
        
        var resourceInfo: [String:NSNumber]?

        queue.sync {
            resourceInfo = self.threadStatuses[buddyId]
        }
        
        var status = ThreadStatus.offline
        if resourceInfo != nil, let resInfo = resourceInfo{
            for info in resInfo {
                if let resourceStatus = ThreadStatus(rawValue: info.value.intValue) {
                    // Check if it less than becauase ThreadStatusAvailable == 0 and the closer you are to ThreadStatusAvailable the more 'real' it is.
                    if (resourceStatus.rawValue < status.rawValue && resourceStatus != ThreadStatus.unknown) {
                        status = resourceStatus
                    }
                    
                    if (status == .available) {
                        break
                    }
                }
            }
        }
        
        return status
    }

    #if !TARGET_IS_EXTENSION
    func setWaitingForChatvCardTempFetch(waiting:Bool, vCardId:String, collection:String) {
        queue.async(flags: .barrier) {
            self.waitingForvCardTempFetch[vCardId] = waiting as NSNumber
            if collection == ChatBuddyModel.collection() {
                if let budcard = ChatBuddy.getBuddy(uniqueId: vCardId) {
                    budcard.touch()
                }
            } else if collection == ChatAccountModel.collection() {
                if let acard = ChatAccountModel.getXMPPAccount(uniqueId: vCardId) {
                    acard.touchAccount()
                }
            }
        }
    }

    public func waitingForChatvCardTempFetch(_ vCardId: String) -> Bool {
        var waiting = false
        queue.sync {
            if let bval = self.waitingForvCardTempFetch[vCardId]?.boolValue {
                waiting = bval
            }
        }
        return waiting
    }
    #endif

    /**
     * Last Seen is associated with querying a presence with delayed delivery. See https://xmpp.org/extensions/xep-0318.html
     */
    func lastSeenDate(buddy: ChatBuddy) -> Date? {
        
        var date:Date?
        queue.sync {
            date = self.lastSeenDates[buddy.uniqueId]
        }
        return date
    }

    func setLastSeen(date:Date?, buddy: ChatBuddy) {
        queue.async(flags: .barrier) {
            if let date = date {
                self.lastSeenDates.updateValue(date, forKey: buddy.uniqueId)
            } else {
                self.lastSeenDates.removeValue(forKey: buddy.uniqueId)
            }
            buddy.touch()
        }
    }
    
    @objc func setLastSeen(date:Date?, buddyModel: ChatBuddyModel) {
        if let bud = buddyModel.grdbRecord {
            self.setLastSeen(date: date, buddy: bud)
        }
    }

    @objc func runtimePropertiesFor(room: ChatRoomModel) -> RoomRuntimeProperties? {
        
        var properties:RoomRuntimeProperties?
        //queue.sync(flags: .barrier) {
        queue.sync {
            properties = self.roomProperties[room.uniqueId]
            if properties == nil {
                properties = RoomRuntimeProperties()
                queue.async(flags: .barrier) { //was commented out
                    self.roomProperties.updateValue(properties!, forKey: room.uniqueId)
                }
            }
        }
        return properties
    }

    func setJid(_ jid:String, online:Bool, room:ChatRoomModel) {
        if let properties = self.runtimePropertiesFor(room: room) {
            if online {
                if !properties.onlineJids.contains(jid) {
                    properties.onlineJids.append(jid)
                }
            } else {
                if let index = properties.onlineJids.firstIndex(of: jid) {
                    properties.onlineJids.remove(at: index)
                }
            }
        }
    }

    func jidOnline(jid:String, room:ChatRoomModel) -> Bool {
        if let properties = self.runtimePropertiesFor(room: room) {
            return properties.onlineJids.contains(jid)
        }
        
        return false
    }


    /** Clears everything for given buddies */
    @objc func purgeAllProperties(buddies: [ChatBuddyModel]) {
        
        if buddies.isEmpty {
            return
        }
        
        queue.async(flags: .barrier) {
            for buddy in buddies {
                self.chatStates.removeValue(forKey: buddy.uniqueId)
                self.lastSentChatStates.removeValue(forKey: buddy.uniqueId)
                self.statusMessages.removeValue(forKey: buddy.uniqueId)
                self.threadStatuses.removeValue(forKey: buddy.uniqueId)
                self.waitingForvCardTempFetch.removeValue(forKey: buddy.uniqueId)
                buddy.touchBuddy()
            }
        }
    }
    
    /// Updates the typing state for a room occupant and notifies observers.
    func setTypingOccupant(jid: String, displayName: String, forRoom roomId: String, isTyping: Bool) {
        queue.async(flags: .barrier) {
            var occupants = self.roomTypingOccupants[roomId] ?? [:]
            if isTyping {
                occupants[jid] = displayName
            } else {
                occupants.removeValue(forKey: jid)
            }
            self.roomTypingOccupants[roomId] = occupants
            let names = Array(occupants.values)
            let jids = Array(occupants.keys)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .GlacierRoomTypingOccupantsDidChange,
                    object: nil,
                    userInfo: ["roomId": roomId, "typingNames": names, "typingJIDs": jids]
                )
            }
        }
    }
    
    func typingNames(forRoom roomId: String) -> [String] {
        var names: [String] = []
        queue.sync {
            names = Array(self.roomTypingOccupants[roomId]?.values ?? [:].values)
        }
        return names
    }

    /** Clears everything for given rooms */
    @objc func purgeAllProperties(rooms:[ChatRoomModel]) {
        
        if rooms.isEmpty {
            return
        }
        
        queue.async(flags: .barrier) {
            for room in rooms {
                self.roomProperties.removeValue(forKey: room.uniqueId)
                self.roomTypingOccupants.removeValue(forKey: room.uniqueId)
            }
        }
    }
}

@objc open class RoomRuntimeProperties : NSObject {
    @objc var joined:Bool = false
    @objc var hasFetchedHistory:Bool = false
    @objc var hasFetchedOwners:Bool = false
    @objc var hasFetchedAdmins:Bool = false
    @objc var hasFetchedMembers:Bool = false
    @objc var onlineJids:[String] = []
}
