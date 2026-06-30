//
//  UIViewController+Glacier.swift
//  Glacier
//

import UIKit

extension UIViewController {
    @objc func isGlacierVisible() -> Bool {
        return isViewLoaded && view.window != nil && UIApplication.shared.applicationState == .active
    }
}
