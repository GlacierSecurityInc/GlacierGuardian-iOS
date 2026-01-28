//
//  ReactionManager.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 07/10/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import Foundation
import XMPPFramework

/// In–memory manager that tracks reaction events and builds
/// aggregations for display.
final class ReactionManager {
    public static let shared = ReactionManager()
    
    private init() {}
    
    /// Builds and sends a reaction stanza for the current user.
    public func sendReactions(xmppId: String,
                              stanzaId: String?,
                              receiverJid: String,
                              senderJid: String,
                              isGroup: Bool,
                              reactions: [String],
                              stream: XMPPStream) {
        
        let message = XMPPMessage(type: isGroup ? "groupchat" : "chat", to: XMPPJID(string: receiverJid))
        message.addAttribute(withName: "xmlns", stringValue: "jabber:client")
        message.addAttribute(withName: "lang", stringValue: "en")
        message.addAttribute(withName: "from", stringValue: senderJid)
        
        let archived = DDXMLElement(name: "archived", xmlns: "urn:xmpp:mam:tmp")
        archived.addAttribute(withName: "by", stringValue: receiverJid)
        if let stnzId = stanzaId {
            archived.addAttribute(withName: "id", stringValue: stnzId)
        }
        message.addChild(archived)
        
        let stanza = DDXMLElement(name: "stanza-id", xmlns: "urn:xmpp:sid:0")
        stanza.addAttribute(withName: "by", stringValue: receiverJid)
        if let stnzId = stanzaId {
            stanza.addAttribute(withName: "id", stringValue: stnzId)
        }
        message.addChild(stanza)
        
        let rx = DDXMLElement(name: "reactions", xmlns: "urn:xmpp:reactions:0")
        rx.addAttribute(withName: "id", stringValue: xmppId)
        for reaction in reactions {
            let el = DDXMLElement(name: "reaction")
            el.stringValue = reaction
            rx.addChild(el)
        }
        message.addChild(rx)
        
        let store = DDXMLElement(name: "store", xmlns: "urn:xmpp:hints")
        message.addChild(store)
        
        stream.send(message)
    }
    
    public func saveReactionsInLocalDatabase(xmppId: String, senderJid: String, reactions: [ChatMessageReaction], completionHandler: @escaping ()->Void) {
        guard let chatMessageModel = ChatMessageModel.message(forMessageId: xmppId, checkIncomingType: false) as? ChatMessageModel else {
            guard let chatRoomMessageModel = ChatRoomMessageModel.getMessage(withXmppId: xmppId) else {
                return
            }
            chatRoomMessageModel.grdbRecord?.reactions = reactions.isEmpty ? nil : reactions
            chatRoomMessageModel.grdbRecord?.modified = Date()
            chatRoomMessageModel.save {
                completionHandler()
            }
            return
        }
        
        chatMessageModel.grdbRecord?.reactions = reactions.isEmpty ? nil : reactions
        chatMessageModel.grdbRecord?.modified = Date()
        chatMessageModel.save {
            completionHandler()
        }
    }
}
