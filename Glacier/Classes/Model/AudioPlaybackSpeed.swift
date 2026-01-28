//  Glacier
//  Created by Prem Pratap Singh on 04/11/25.
//  Copyright © 2025 Glacier. All rights reserved.

import Foundation

/**
 Defines available audio playback speeds
 */
enum AudioPlaybackSpeed: Float, CaseIterable {
    case zeroPointFive = 0.5
    case one = 1
    case onePointFive = 1.5
    case two = 2
    
    // MARK: - Public properties
    
    var title: String {
        switch self {
        case .zeroPointFive: return "0.5x"
        case .one: return "1x"
        case .onePointFive: return "1.5x"
        case .two: return "2x"
        }
    }
    
    var speed: Float {
        self.rawValue
    }
}
