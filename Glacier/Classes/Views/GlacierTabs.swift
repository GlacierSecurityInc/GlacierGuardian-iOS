//
//  GlacierTabs.swift
//  Glacier
//
//  Created by andyfriedman on 11/29/22.
//  Copyright © 2022 Glacier. All rights reserved.
//

import UIKit
import PureLayout

@objc public class GlacierTabs: UITabBar {
    var addedConstraints = false
    var smsEnabled = false
    @objc let chatsItem = UITabBarItem(title: "Chats", image: UIImage(named: "08-chat", in: GlacierInfo.resourcesBundle, compatibleWith: nil), tag: Screen.chats.rawValue)
    @objc let smsItem = UITabBarItem(title: "SMS", image: UIImage(named: "PushOnboarding", in: GlacierInfo.resourcesBundle, compatibleWith: nil), tag: Screen.sms.rawValue)
    @objc let dialItem = UITabBarItem(title: "Phone", image: UIImage(named: "dialpad", in: GlacierInfo.resourcesBundle, compatibleWith: nil), tag: Screen.dial.rawValue)
    @objc let hubItem = UITabBarItem(title: "Hub", image: UIImage(systemName: "checkerboard.shield"), tag: Screen.security.rawValue)
    @objc let settingsItem = UITabBarItem(title: "Settings", image: UIImage(systemName: "gearshape.fill"), tag: Screen.settings.rawValue)
    @objc let contactsItem = UITabBarItem(title: "Contacts", image: UIImage(systemName: "person.circle.fill"), tag: Screen.contacts.rawValue)
    @objc let historyItem = UITabBarItem(title: "History", image: UIImage(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90"), tag: Screen.history.rawValue)
    
    @objc(GlacierTabsScreen) public enum Screen: Int {
        case chats = 0
        case sms = 1
        case dial = 2
        case security = 3
        case settings = 4
        case contacts = 5
        case history = 6
    }
    
    public init() {
        super.init(frame: .zero)
        self.doInitStuff()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.doInitStuff()
    }
    
    @available(*, unavailable, message:"use other constructor instead.")
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        self.doInitStuff()
    }
    
    func doInitStuff() {
        self.items = [chatsItem, hubItem, settingsItem]
        //self.delegate = self
        self.selectedItem = chatsItem
        
        let appearance = UITabBarAppearance.init()
        appearance.backgroundColor = GlobalTheme.shared.lightThemeColor.withAlphaComponent(0.5)
            
        let glacierBlue = UIColor.bubbleBlue()
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: glacierBlue]
        appearance.stackedLayoutAppearance.selected.iconColor = glacierBlue
            
        self.standardAppearance = appearance
        self.scrollEdgeAppearance = appearance
        self.tintColor = UIColor.bubbleBlue()
        
        self.setNeedsUpdateConstraints()
    }
    
    public override func awakeFromNib() {
        super.awakeFromNib()
    }
    
    func setPhoneModule() {
        self.items = [chatsItem, smsItem, dialItem, contactsItem, historyItem]
        self.setNeedsDisplay()
        smsEnabled = true
    }
    
    @objc func setSMSEnabled(_ enabled:Bool) {
        self.tintColor = UIColor.bubbleBlue()
        if (enabled && !smsEnabled) {
            self.items = [chatsItem, smsItem, dialItem, hubItem, settingsItem]
            self.setNeedsDisplay()
        } else if (!enabled && smsEnabled) {
            self.items = [chatsItem, hubItem, settingsItem]
            self.setNeedsDisplay()
        }
        smsEnabled = enabled
    }
    
    //IOSM#99
    @objc func setSecurityAlert(_ alert:Bool) {
        if alert == true {
            showDotBadge(for: hubItem)
        } else {
            hideDotBadge(for: hubItem)
        }
    }
    
    public override func updateConstraints()
    {
        if (!self.addedConstraints) {
            self.autoPinEdge(toSuperviewEdge: ALEdge.trailing)
            self.autoPinEdge(toSuperviewEdge: ALEdge.leading)
            self.autoPinEdge(toSuperviewEdge: ALEdge.bottom)
            
            if let superbottom = superview?.safeAreaLayoutGuide.bottomAnchor {
                NSLayoutConstraint.activate([
                    //self.heightAnchor.constraint(equalToConstant: CGFloat(49)),
                    self.topAnchor.constraint(equalTo: superbottom, constant: -49)
                ])
            } else {
                NSLayoutConstraint.activate([
                    self.heightAnchor.constraint(equalToConstant: CGFloat(49))
                ])
            }
            
            self.addedConstraints = true
        }
        
        super.updateConstraints()
    }
}

// MARK: Functions for showing/hiding subtle red dot badge on the tab items

extension GlacierTabs {
    private func showDotBadge(for tabBarItem: UITabBarItem, ofColor: UIColor = .red.withAlphaComponent(0.7)) {
        guard self.items?.firstIndex(of: tabBarItem) != nil,
              let tabItemView = tabBarItem.value(forKey: "view") as? UIView else {
            return
        }
        
        guard tabItemView.subviews.first(where: { $0.tag == 999 }) == nil else {
            return
        }
        
        let redDot = UIView()
        redDot.backgroundColor = ofColor
        redDot.translatesAutoresizingMaskIntoConstraints = false
        redDot.layer.cornerRadius = 4
        redDot.tag = 999
        tabItemView.addSubview(redDot)
        
        NSLayoutConstraint.activate([
            redDot.widthAnchor.constraint(equalToConstant: 8),
            redDot.heightAnchor.constraint(equalToConstant: 8),
            redDot.topAnchor.constraint(equalTo: tabItemView.topAnchor, constant: 4),
            redDot.trailingAnchor.constraint(equalTo: tabItemView.trailingAnchor, constant: -22)
        ])
    }

    private func hideDotBadge(for tabBarItem: UITabBarItem) {
        guard self.items?.firstIndex(of: tabBarItem) != nil,
              let tabItemView = tabBarItem.value(forKey: "view") as? UIView else {
            return
        }
        
        guard let redDot = tabItemView.viewWithTag(999) else {
            return
        }
        redDot.removeFromSuperview()
    }
}
