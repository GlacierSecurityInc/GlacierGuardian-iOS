//
//  ContextMenuDelegate.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 17/10/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import UIKit
import MessageKit

/**
 This helps in delegating context menu interaction events to the chat rooms
 */
protocol ContextMenuDelegate: AnyObject {
    func addReaction(_ emoji: String, to message: any GRDBRecord)
    func handleAction(_ menuItem: ContextMenuItem, for message: any GRDBRecord)
    func showMoreEmojis(for message: any GRDBRecord)
}
