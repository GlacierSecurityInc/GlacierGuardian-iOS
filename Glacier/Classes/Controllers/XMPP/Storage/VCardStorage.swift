//  ChatSecureCore
//  Created by Chris Ballinger on 3/3/18.
//  Copyright © 2018 Chris Ballinger. All rights reserved.

import Foundation
import XMPPFramework

public class VCardStorage: NSObject {
    
    
    /// nil jid returns account's vCard
    /// Opens implicit background read transaction
    private func vCard(jid: XMPPJID? = nil,
                       stream: XMPPStream) -> ChatvCard? {
        guard let myJID = stream.myJID,
        let accountId = stream.accountId else {
            return nil
        }
        return self.vCard(jid: jid, myJID: myJID, accountId: accountId)
    }
    
    /// nil jid returns account's vCard
    private func vCard(jid: XMPPJID? = nil,
                       myJID: XMPPJID,
                       accountId: String) -> ChatvCard? {
        //XMPPAccount and XMPPBuddy fulfill the ChatvCard protocol
        guard let jid = jid else {
            return ChatAccountModel.getXMPPAccount(uniqueId: accountId)
        }
        if jid.isEqual(to: myJID, options: .bare) {
            return ChatAccountModel.getXMPPAccount(uniqueId: accountId)
        } else {
            return ChatBuddyModel.fetchBuddyModel(jid: jid, accountUniqueId: accountId)
        }
    }
}

// MARK: - XMPPvCardAvatarStorage

extension VCardStorage: XMPPvCardAvatarStorage {
    public func photoData(for jid: XMPPJID, xmppStream stream: XMPPStream) -> Data? {
        guard let vCard = vCard(jid: jid, stream: stream) else {
            return nil
        }
        return vCard.avatarData
    }
    
    public func photoHash(for jid: XMPPJID, xmppStream stream: XMPPStream) -> String? {
        guard let vCard = vCard(jid: jid, stream: stream) else {
            return nil
        }
        return vCard.photoHash
    }
    
    
    public func clearvCardTemp(for jid: XMPPJID, xmppStream stream: XMPPStream) {
        guard let myJID = stream.myJID,
            let accountId = stream.accountId else {
                return
        }
        
        guard let vCard = self.vCard(jid: jid, myJID: myJID, accountId: accountId) else {
            DDLogError("No vCard found for \(jid)")
            return
        }
        vCard.vCardTemp = nil
        vCard.waitingForvCardTempFetch = false
        vCard.lastUpdatedvCardTemp = nil
        
        if let account = vCard as? ChatAccountModel {
            account.saveXMPPAccountAsync()
        } else if let buddy = vCard as? ChatBuddyModel {
            buddy.saveThread()
            ChatThread.touch(uniqueId: buddy.uniqueId)
        }
    }
}

// MARK: - XMPPvCardTempModuleStorage

extension VCardStorage: XMPPvCardTempModuleStorage {
    public func configure(withParent aParent: XMPPvCardTempModule, queue: DispatchQueue) -> Bool {
        return true
    }
    
    public func vCardTemp(for jid: XMPPJID, xmppStream stream: XMPPStream) -> XMPPvCardTemp? {
        return vCard(jid: jid, stream: stream)?.vCardTemp
    }
    
    public func setvCardTemp(_ vCardTemp: XMPPvCardTemp, for jid: XMPPJID, xmppStream stream: XMPPStream) {
        guard let myJID = stream.myJID,
            let accountId = stream.accountId else {
                return
        }
        
        guard let vCard = self.vCard(jid: jid, myJID: myJID, accountId: accountId) else {
            DDLogError("No vCard found for \(jid)")
            return
        }
        vCard.vCardTemp = vCardTemp
        vCard.waitingForvCardTempFetch = false
        vCard.lastUpdatedvCardTemp = Date()
        if let account = vCard as? ChatAccountModel {
            account.grdbRecord?.modified = Date()
            account.saveXMPPAccount()
        } else if let buddy = vCard as? ChatBuddyModel {
            buddy.grdbRecord?.modified = Date()
            buddy.saveThread()
            ChatThread.touch(uniqueId: buddy.uniqueId)
        }
    }
    
    public func myvCardTemp(for stream: XMPPStream) -> XMPPvCardTemp? {
        return vCard(stream: stream)?.vCardTemp
    }
    
    public func shouldFetchvCardTemp(for jid: XMPPJID, xmppStream stream: XMPPStream) -> Bool {
        guard stream.isAuthenticated else {
            return false
        }
        guard let vCard = vCard(jid: jid, stream: stream),
        let lastUpdated = vCard.lastUpdatedvCardTemp else {
            return true
        }
        if vCard.waitingForvCardTempFetch {
            return false
        } else if lastUpdated.timeIntervalSinceNow <= -24*60*60 {
            // Saving is not required due to internal use of in-memory BuddyCache
            //This goes to the cache and does not change the database object.
            vCard.waitingForvCardTempFetch = true
            return true
        } else {
            return false
        }
    }
    
    
}
