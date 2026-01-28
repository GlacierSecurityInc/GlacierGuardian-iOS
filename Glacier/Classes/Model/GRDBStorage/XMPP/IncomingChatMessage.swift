//
//  IncomingChatMessage.swift
//  Glacier
//
//  Created by andyfriedman on 9/13/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation

public class IncomingChatMessage: ChatMessageModel {
    public convenience init() {
        var chatMsg = ChatMessage()
        chatMsg.type = ChatMessageType.incoming.rawValue
        self.init(message:chatMsg)
    }
}
