//
//  MessagesViewControllerState.swift
//  ChatSecure
//
//  Created by David Chiles on 2/23/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

import Foundation

/// A simple model to encompass all the possible states that affect the send button. In the future this could have more properties for the lock and title bar
@objc open class MessagesViewControllerState:NSObject {
    
    /** This should reflect whether the textview currently has text */
    @objc open var hasText = false
    
    /** Reflects media messages can be sent. */
    @objc open var canSendMedia = true
    
    /** This should reflect how messages should be sent and what the buddy prefrences are */
    @objc open var messageSecurity = GlacierMessageTransportSecurity.plaintext
    
    /** This should reflect if the thread(buddy or room) is online or not. */
    @objc open var isThreadOnline = false
    
    /// Resets all state
    @objc open func reset() {
        hasText = false
        canSendMedia = true
        messageSecurity = .invalid
        isThreadOnline = false
    }
}
