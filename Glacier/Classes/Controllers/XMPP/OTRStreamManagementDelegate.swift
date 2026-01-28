//
//  OTRStreamManagementDelegate.swift
//  ChatSecure
//
//  Created by David Chiles on 6/15/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

import Foundation
import XMPPFramework

/**
 * The purpose of this class is to know if XEP-0198 is enabled and to mark messages when they are acknowledged by the server with the correct date
 */
@objc open class OTRStreamManagementDelegate:NSObject, XMPPStreamManagementDelegate {
    
    @objc fileprivate(set) open var streamManagementEnabled = false
    
    @objc open func xmppStreamManagement(_ sender: XMPPStreamManagement, wasEnabled enabled: XMLElement) {
        self.streamManagementEnabled = true
    }
    @objc open func xmppStreamManagement(_ sender: XMPPStreamManagement, wasNotEnabled failed: XMLElement) {
        self.streamManagementEnabled = false
    }
    
    @objc open func xmppStreamManagement(_ sender: XMPPStreamManagement, didReceiveAckForStanzaIds stanzaIds: [Any]) {
        for object in stanzaIds {
            guard let stanzaId = object as? String else {
                return
            }
                
            if let message = OutgoingChatMessage.message(forMessageId: stanzaId) as? OutgoingChatMessage {
                message.grdbRecord?.dateAcked = Date()
                message.save()
            }
        }
    }
}
