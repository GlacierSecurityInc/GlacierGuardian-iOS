//
//  ChatvCard.swift
//  Glacier
//
//  Created by andyfriedman on 11/7/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation

@objc public protocol ChatvCard {
    @objc var vCardTemp: XMPPvCardTemp? { get set }
    @objc var lastUpdatedvCardTemp: Date? { get set }
    @objc var waitingForvCardTempFetch: Bool { get set }
    @objc var photoHash: String? { get set }
    @objc var avatarData: Data? { get set }
    
    //@objc func copyAsSelf() -> Self?
}
