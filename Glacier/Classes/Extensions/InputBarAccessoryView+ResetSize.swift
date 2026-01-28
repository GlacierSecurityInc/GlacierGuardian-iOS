//
//  InputTextView+ResetSize.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 29/09/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import InputBarAccessoryView

extension InputBarAccessoryView {
    
    // Resets set to blank text
    func resetText() {
        self.inputTextView.text = String()
    }
    
    // Resets input text view size to default size
    func resetSize() {
        self.inputTextView.invalidateIntrinsicContentSize()
        self.setNeedsLayout()
        self.layoutIfNeeded()
    }
}
