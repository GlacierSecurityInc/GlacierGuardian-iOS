//  Glacier
//  Created by Prem Pratap Singh on 11/11/25.
//  Copyright © 2025 Glacier. All rights reserved.

import UIKit
import MCEmojiPicker

/**
 This is a wrapper VC for presenting MCEmojiPickerViewController as a native sheet view
 */
class EmojiPickerViewController: UIViewController, MCEmojiPickerDelegate, UIAdaptivePresentationControllerDelegate {
    
    // MARK: - Public properties
    
    var didGetReactionEmoji: ((String) -> Void)?
    
    // MARK: - Lifecycle methods
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        let emojiPickerVC = MCEmojiPickerViewController()
        emojiPickerVC.delegate = self
        emojiPickerVC.sourceView = self.view
        emojiPickerVC.presentationController?.delegate = self
        present(emojiPickerVC, animated: false)
    }
    
    func didGetEmoji(emoji: String) {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        
        self.didGetReactionEmoji?(emoji)
        self.presentingViewController?.dismiss(animated: false)
    }
    
    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        self.dismiss(animated: false)
    }
}
