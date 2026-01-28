//  Glacier
//  Created by Prem Pratap Singh on 14/10/25.
//  Copyright © 2025 Glacier. All rights reserved.

import Foundation
import XMPPFramework


// MARK: - XMPPMessage Reaction Parsing
extension XMPPMessage {

    /// Extracts the ID of the `<reactions/>` element.
    var reactionsId: String? {
        return deepReactionsElement?.attributeStringValue(forName: "id")
    }

    var chatMessageReactions: NSDictionary? {
        guard let reactions = deepReactionsElement else {
            return nil
        }
        
        guard let senderJid = (reactions.parent as? DDXMLElement)?.attributeStringValue(forName: "from"),
              !senderJid.isEmpty else {
            return nil
        }
        
        let reactionNodes = reactions.elements(forName: "reaction")
        let userReactions = reactionNodes.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                                        .filter { !$0.isEmpty }
        
        return [
            ChatMessageReaction.Constants.senderJid: senderJid,
            ChatMessageReaction.Constants.reactions: userReactions
        ] as NSDictionary
    }
    
    /// A private computed property that performs a deep search for the `<reactions>` element.
    private var deepReactionsElement: DDXMLElement? {
        return self.findElementRecursively(localName: "reactions", uri: "urn:xmpp:reactions:0")
    }
}

extension DDXMLElement {
    /// Recursively searches for the first element with the given localName and namespace URI.
    fileprivate func findElementRecursively(localName: String, uri: String) -> DDXMLElement? {
        if self.name == localName, self.xmlns() == uri {
            return self
        }
        
        for child in children ?? [] {
            if let element = child as? DDXMLElement {
                if let match = element.findElementRecursively(localName: localName, uri: uri) {
                    return match
                }
            }
        }
        
        return nil
    }
}
