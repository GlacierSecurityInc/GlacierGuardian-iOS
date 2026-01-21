//
//  File.swift
//  ChatSecure
//
//  Created by David Chiles on 12/14/15.
//  Copyright © 2015 Chris Ballinger. All rights reserved.
//

import Foundation
import UIKit


public extension UINavigationController {
    
    @objc func otr_baseViewContorllers() -> [UIViewController] {
        var result:[UIViewController] = []
        let viewController = self.viewControllers
        for vc in viewController {
            if let nav = vc as? UINavigationController {
                result.append(contentsOf: nav.otr_baseViewContorllers())
            } else {
                result.append(vc)
            }
        }
        return result
    }
    
    /*@objc func setCustomBackButton() {
        let backButtonBackgroundImage = UIImage(systemName: "chevron.right")
        let barAppearance = UINavigationBar.appearance(whenContainedInInstancesOf: [ChatViewController.self])
        barAppearance.backIndicatorImage = backButtonBackgroundImage
        barAppearance.backIndicatorTransitionMaskImage = backButtonBackgroundImage
        let backBarButton = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
        navigationItem.backBarButtonItem = backBarButton
    }*/
}
