//
//  KeyboardObservable.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 21/11/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

/**
 KeyboardObservable protocol provides the API for getting keyboard's current height property. Any UIViewController that needs
 keyboard height value, needs to confirm to this protocol and add a new stored property `keyboardHeight` and call
 `registerKeyboardNotifications()` and `unregisterKeyboardNotifications()` methods
 
 With KeyboardObservable extension, default implementation of the internal workflows are provided for listening to keyboard related events
 and setting keyboardHeight property value.
 */
protocol KeyboardObservable: AnyObject {
    var keyboardHeight: CGFloat { get set }
    
    func registerKeyboardNotifications()
    func unregisterKeyboardNotifications()
}

// MARK: - KeyboardObservable extension

extension KeyboardObservable where Self: UIViewController {
    func registerKeyboardNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboard(notification: notification, isShowing: true)
        }
        
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboard(notification: notification, isShowing: false)
        }
    }
    
    func unregisterKeyboardNotifications() {
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }
    
    private func handleKeyboard(notification: Notification, isShowing: Bool) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        
        let height = isShowing ? keyboardFrame.height : 0
        self.keyboardHeight = height
    }
}
