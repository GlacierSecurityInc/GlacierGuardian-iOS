//  Glacier
//  Created by Prem Pratap Singh on 13/10/25.
//  Copyright © 2025 Glacier. All rights reserved.

struct ChatMessageReaction: Codable, Equatable {
    let senderJid: String
    var reactions: [String]
    
    struct Constants {
        static let senderJid = "senderJid"
        static let reactions = "reactions"
    }
}
