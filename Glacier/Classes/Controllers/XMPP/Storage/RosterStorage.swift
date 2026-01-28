//
//  RosterStorage.swift
//  ChatSecureCore
//
//  Created by N-Pex on 2018-01-21.
//  Copyright © 2018 Chris Ballinger. All rights reserved.
//

import Foundation
import XMPPFramework

@objc public class RosterStorage: NSObject {
    
    // MARK: Properties
    
    var rosterSet: Set<ChatBuddyModel>
    
    // MARK: Init
    
    @objc public override init() {
        self.rosterSet = Set<ChatBuddyModel>()
    }
    
    // MARK: Private
    
    /// updates the subscription status
    /// sends out presence updates
    /// saves buddy and sends out a nasty NSNotification
    private func updateSubscription(buddy: ChatBuddy,
                                    presence: XMPPPresence,
                                    stream: XMPPStream) {
        let buddyModel = ChatBuddyModel(buddy: buddy)
        guard let type = presence.presenceType,
            let jid = buddyModel.bareJID else {
            return
        }
        switch type {
        case .subscribed:
            buddyModel.refetch(completion: { (buddy) in
                if let bud = buddy { //}?.copyAsSelf() {
                    bud.pendingApproval = false
                    bud.saveThread(completion: {
                        NotificationCenter.default.post(name: NSNotification.Name.BuddyPendingApprovalDidChange, object: self, userInfo: ["buddy": bud])
                    })
                }
            })
            let presence = XMPPPresence(type: .subscribe, to: jid)
            stream.send(presence)
            stream.resendMyPresence()
        case .unsubscribed:
            buddyModel.refetch(completion: { (buddy) in
                if let bud = buddy { //}?.copyAsSelf() {
                    bud.pendingApproval = false
                    bud.saveThread()
                }
            })
            let presence = XMPPPresence(type: .unsubscribe, to: jid)
            stream.send(presence)
        default:
            break
        }
    }
    
    private func updateLastSeen(buddy: ChatBuddy,
                                presence: XMPPPresence,
                                status: ThreadStatus) {
        var lastSeen: Date?
        let delayedDeliveryDate = presence.delayedDeliveryDate
        let idleDate = presence.idleSince
        if status == .available {
            lastSeen = Date()
        } else if idleDate != nil {
            lastSeen = idleDate
        } else if delayedDeliveryDate != nil {
            lastSeen = delayedDeliveryDate
        }
        if lastSeen != nil {
            BuddyCache.shared().setLastSeen(date: lastSeen, buddy: buddy)
        } //IOSM-168 remove this or get rid of delayedDelivery?
    }
}

// MARK: XMPPRosterStorage

extension RosterStorage: XMPPRosterStorage {
    public func configure(withParent aParent: XMPPRoster, queue: DispatchQueue) -> Bool {
        return true
    }
    
    public func beginRosterPopulation(for stream: XMPPStream, withVersion version: String) {
        
    }
    
    public func endRosterPopulation(for stream: XMPPStream) {
        // compare list and remove any that shouldn't be there
        guard let accountId = stream.accountId else {
            return
        }
        
        if (self.rosterSet.count == 0) {
            return
        }
        
        let budjids = self.jids(for: stream)
        var kickList = Set<XMPPJID>()
        for budjid in budjids {
            var found = false
            for item in self.rosterSet {
                if let barejid = item.bareJID {
                    if (barejid.isEqual(to: budjid)) {
                        found = true
                    }
                }
            }
                    
            if (!found) {
                kickList.insert(budjid)
            }
        }
        
        //var roomMgr:OTRXMPPRoomManager?
        for kicked in kickList {
            if let buddy = ChatBuddyModel.fetchBuddyModel(jid: kicked, accountUniqueId: accountId) {
                buddy.grdbRecord?.remove(completion: {})
            }
        }
        
        self.rosterSet.removeAll()
    }
    
    public func handleRosterItem(_ item: XMLElement, xmppStream stream: XMPPStream) {
        
    }
    
    public func handle(_ presence: XMPPPresence, xmppStream stream: XMPPStream) {
        guard let accountId = stream.accountId,
            let fromJID = presence.from,
            presence.isErrorPresence == false else {
            DDLogError("Ignoring presence \(presence)")
            return
        }
        
        guard let buddy = ChatBuddyModel.fetchBuddy(jid: fromJID, accountUniqueId: accountId) else {
            return
        }
        let status = ThreadStatus(presence: presence)
        let resource = presence.from?.resource
        
        if (presence.type == "unavailable") {
            BuddyCache.shared().setThreadStatus(ThreadStatus.offline, buddyId: buddy.uniqueId, resource: resource)
            BuddyCache.shared().setStatusMessage(OFFLINE_STRING(), buddyId: buddy.uniqueId)
            BuddyCache.shared().setChatState(ChatState.gone, buddyId: buddy.uniqueId)
        } else {
            BuddyCache.shared().setThreadStatus(status, buddyId: buddy.uniqueId, resource: resource)
            BuddyCache.shared().setStatusMessage(presence.status, buddyId: buddy.uniqueId)
        }
        
        updateSubscription(buddy: buddy, presence: presence, stream: stream)
        updateLastSeen(buddy: buddy, presence: presence, status: status)
        buddy.touch()
    }
    
    public func userExists(with jid: XMPPJID, xmppStream stream: XMPPStream) -> Bool {
        guard let accountId = stream.accountId else {
            return false
        }
        var result = false
        if let buddy = ChatBuddyModel.fetchBuddyModel(jid: jid, accountUniqueId: accountId), buddy.trustLevel == .roster {
            result = true
        }
        return result
    }
    
    public func clearAllResources(for stream: XMPPStream) {
        
    }
    
    public func clearAllUsersAndResources(for stream: XMPPStream) {
        
    }
    
    public func jids(for stream: XMPPStream) -> [XMPPJID] {
        guard let accountId = stream.accountId else {
            return []
        }
        var jids: [XMPPJID] = ChatBuddyModel.getAllBuddies(for: accountId).filter {
                $0.trustLevel == .roster
            }
            .compactMap {
                $0.bareJID
            }
        return jids
    }
    
    public func getSubscription(_ subscription: AutoreleasingUnsafeMutablePointer<NSString?>?, ask: AutoreleasingUnsafeMutablePointer<NSString?>?, nickname: AutoreleasingUnsafeMutablePointer<NSString?>?, groups: AutoreleasingUnsafeMutablePointer<NSArray?>?, for jid: XMPPJID, xmppStream stream: XMPPStream) {
        
    }
    
    
}

// MARK: XMPPRosterDelegate

extension RosterStorage: XMPPRosterDelegate {
    
    public func xmppRoster(_ sender: XMPPRoster, didReceiveRosterItem item: XMLElement) {
        
        guard let jidStr = item.attributeStringValue(forName: "jid"),
            let jid = XMPPJID(string: jidStr),
            let subscription = item.attributeStringValue(forName: "subscription"),
            let accountId = sender.accountId,
            let stream = sender.xmppStream
            else { return }
        
        if(jidStr == stream.myJID?.bare)
        {
            // ignore self buddy
            return;
        }
        
        let ask = item.attributeStringValue(forName: "ask")

        var buddy = ChatBuddyModel.fetchBuddy(jid: jid, accountUniqueId: accountId)
        if subscription == "remove" {
            if let buddy = buddy {
                buddy.remove(completion: {})
            }
        } else {
            var buddyModel:ChatBuddyModel?
            if buddy == nil {
                buddyModel = ChatBuddyModel()
                buddy = ChatBuddy(uniqueId: buddyModel!.uniqueId)
                buddy?.accountUniqueId = accountId
                    
                // We can be called with buddies that are not really on our roster, i.e.
                // they are in state none + pendingIn, so default to BuddyTrustLevelUntrusted and set to BuddyTrustLevelRoster only when we are subscribed to them.
                //buddy?.trustLevel = .untrusted
                buddy?.displayName = jid.user ?? jidStr
                buddy?.username = jid.bare
                buddyModel?.grdbRecord = buddy
            } else if let buddy = buddy {
                buddyModel = ChatBuddyModel(buddy: buddy)
                //buddyModel = buddyModel?.copyAsSelf()
            }
            guard let buddyModel = buddyModel else { return }
            buddyModel.grdbRecord?.subscription = SubscriptionAttribute(stringValue: subscription).rawValue
            //buddyModel.pendingApproval.setPendingOut(pending: (ask == "subscribe"))
            //if buddyModel.subscribedFrom {
            //    buddyModel.pendingApproval.setPendingIn(pending: false)
            //}
            //if buddyModel.subscribedTo || buddyModel.subscribedFrom {
            //    buddyModel.trustLevel = .roster
            //}
                
            // Update name
            if let name = item.attributeStringValue(forName: "name"), name.count > 0 {
                buddyModel.displayName = name
            }
                
            var groups: [String] = []
            let groupElements = item.elements(forName: "group")
            for group in groupElements {
                if let name = group.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    groups.append(name)
                }
            }
            buddyModel.grdbRecord?.sharedGroups = groups
            buddyModel.saveThread()
                
            self.rosterSet.insert(buddyModel)
        }
    }
}


extension ThreadStatus {
    
    init(presence: XMPPPresence) {
        self = ThreadStatus.from(presence: presence)
    }
    
    static func from(presence: XMPPPresence) -> ThreadStatus {
        if presence.presenceType == .unavailable {
            return .offline
        }
        switch presence.showValue {
        case .DND:
            return .donotdisturb
        case .XA:
            return .extendedaway
        case .away:
            return .away
        case .other,
             .chat:
            return .available
        @unknown default:
            return .offline
        }
    }
}
