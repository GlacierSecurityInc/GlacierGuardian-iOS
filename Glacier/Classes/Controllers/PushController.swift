//
//  PushController.swift
//  ChatSecure
//
//  Created by David Chiles on 9/3/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

import Foundation
import UserNotifications
import TwilioVoice

@objc public enum PushPreference: Int {
    case undefined
    case disabled
    case enabled
}

/**
 The purpose of this class is to tie together the api client and the data store.
 It also provides some helper methods that makes dealing with the api easier
 */
open class PushController: NSObject {
    var pubsubEndpoint: NSString?
    
    var pushToken: String?
    var voipToken: String?
    
    /// This will delete all your push data and disable push
    @objc open func deactivate() {
        PushController.setPushPreference(.disabled)
    }
    
    //MARK: Push Preferences
    
    @objc public static func getPushPreference() -> PushPreference {
        guard let value = UserDefaults.standard.object(forKey: kGlacierPushEnabledKey) as? NSNumber else {
            return .undefined
        }
        if value.boolValue == true {
            return .enabled
        } else {
            return .disabled
        }
    }
    
    @objc public static func setPushPreference(_ preference: PushPreference) {
        var bool = false
        if preference == .enabled {
            bool = true
        }
        UserDefaults.standard.set(bool, forKey: kGlacierPushEnabledKey)
        UserDefaults.standard.synchronize()
    }
    
    //MARK: Utility
    
    /// Asks for notification authorization and, on success, re-registers for remote
    /// notifications.
    ///
    /// The authorization request itself, the `GlacierUserNotificationsChanged` post and
    /// the APNs re-registration all live in `GuardianPermissionManager` now, so this call
    /// queues behind any other permission prompt already in flight instead of stacking a
    /// system alert on top of one. Push *preference* is still this class's business.
    @objc public static func registerForPushNotifications() {
        GuardianPermissionManager.shared.request(.notifications)
    }
    
    @objc public static func checkPushNotifications() {
        if PushController.getPushPreference() != .enabled {
            PushController.enablePush()
        } else {
            UNUserNotificationCenter.current().getNotificationSettings(completionHandler: { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional: return
                case .denied, .notDetermined: PushController.enablePush()
                case .ephemeral: return
                }
            })
        }
    }
    
    private static func enablePush() {
        PushController.setPushPreference(.enabled)
        PushController.registerForPushNotifications()
    }
    
    @objc public func setPushToken(_ token: String!) -> Void {
        pushToken = token
    }
    
    @objc public func getPushToken() -> String? {
        return pushToken
    }
    
    @objc public func setVoipToken(_ token: Data) -> Void {
        voipToken = token.toHexString()
    }
    
    @objc public func getVoipToken() -> String? {
        return voipToken
    }
}
