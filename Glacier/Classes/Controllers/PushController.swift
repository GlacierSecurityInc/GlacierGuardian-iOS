//  ChatSecure
//  Created by David Chiles on 9/3/15.

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
        guard let value = UserDefaults.standard.object(forKey: kOTRPushEnabledKey) as? NSNumber else {
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
        UserDefaults.standard.set(bool, forKey: kOTRPushEnabledKey)
        UserDefaults.standard.synchronize()
    }
    
    //MARK: Utility
    
    @objc public static func registerForPushNotifications() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.badge, .alert, .sound], completionHandler: { (granted, error) in
            DispatchQueue.main.async(execute: {
                // TODO: Handle push registration error
                let app = Application.shared
                NotificationCenter.default.post(name: Notification.Name(rawValue: OTRUserNotificationsChanged), object: app.delegate, userInfo:nil)
                if (granted) {
                    app.registerForRemoteNotifications()
                }
            })
        })
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
