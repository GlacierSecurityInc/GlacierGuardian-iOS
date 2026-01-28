//
//  DefaultTheme.swift
//  ChatSecureCore
//
//  Created by Chris Ballinger on 2/23/18.
//  Copyright © 2018 Chris Ballinger. All rights reserved.
//

import Foundation

@objc public class GlobalTheme: NSObject {
    @objc public static var shared: AppTheme = DefaultTheme()
}

@objc public class DefaultTheme: NSObject, AppTheme {
    public func messagesViewController() -> UIViewController {
        return ChatViewControllerExt()
    }
    
    public let mainThemeColor = UIColor.white
    public let lightThemeColor = UIColor.lightThemeColor
    public let buttonLabelColor = UIColor.darkGray
    
    public func setupAppearance() { }
    
    public func conversationViewController() -> UIViewController {
        return ConversationViewController()
    }
    
    
    public func chatViewController() -> UIViewController {
        return ChatViewControllerExt()
    }
    
    public func chatRoomViewController() -> UIViewController {
        return ChatRoomViewControllerExt()
    }
    
    public func settingsViewController() -> UIViewController {
        return OTRSettingsViewController()
    }
    
    public func composeViewController() -> UIViewController {
        return ChatComposeViewController()
    }
}

extension UIColor {
    static var lightThemeColor: UIColor {
        return UIColor.systemGray6
    }
}
