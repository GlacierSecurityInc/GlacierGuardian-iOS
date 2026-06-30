//
//  ContextMenuItem.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 17/10/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import Foundation

/**
 It contains data and state for context menu items
 */
enum ContextMenuItem: String, Identifiable, CaseIterable {
    case copy = "Copy"
    case delete = "Delete"
    case resend = "Resend"
    case cancelDownload = "Cancel"
    case viewProfile = "View Profile"
    
    // MARK: - Public properties
    
    var id: String { UUID().uuidString }
    
    var label: String { self.rawValue }
}
