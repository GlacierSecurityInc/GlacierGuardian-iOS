//
//  OutgoingChatMessage.swift
//  Glacier
//
//  Created by andyfriedman on 9/13/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation

public class OutgoingChatMessage: ChatMessageModel {
    public convenience init() {
        var chatMsg = ChatMessage()
        chatMsg.type = ChatMessageType.outgoing.rawValue
        chatMsg.read = true
        chatMsg.readDate = Date()
        self.init(message:chatMsg)
    }
}
