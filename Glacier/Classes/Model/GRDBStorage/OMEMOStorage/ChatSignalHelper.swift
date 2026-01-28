//
//  ChatSignalHelper.swift
//  Glacier
//
//  Created by andyfriedman on 12/13/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation

@objc open class ChatSignalHelper:NSObject {
    @objc public static func removeSignalSignedPreKey(for accountKey: String) {
        ChatSignedPreKey.removeSignalSignedPreKey(for: accountKey)
    }
    
    @objc public static func removeAccountSignalIdKey(for accountId: String) {
        ChatAccountSignalIdentity.removeAccountSignalIdKey(for: accountId)
    }
    
    @objc public static func countOMEMODevices(for buddyId: String) -> Int {
        return ChatOmemoDevice.countOMEMODevices(for: buddyId)
    }
}
