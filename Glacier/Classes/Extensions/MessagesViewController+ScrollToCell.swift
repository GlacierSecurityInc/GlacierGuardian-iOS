//  Glacier
//  Created by Prem Pratap Singh on 21/11/25.
//  Copyright © 2025 Glacier. All rights reserved.

import MessageKit

extension MessagesViewController {
    
    /**
     Scrolls the message collection view so that the message at given index path is fully visible.
     */
    func scrollToCellIfNotFullyVisible(at indexPath: IndexPath, keyboardHeight: CGFloat) {
        guard let layoutAttributes = messagesCollectionView.layoutAttributesForItem(at: indexPath) else { return }

        let cellFrame = layoutAttributes.frame
        
        // Available visible height after accounting for input bar + keyboard
        let safeVisibleHeight = messagesCollectionView.bounds.height
                               - messageInputBar.bounds.height
                               - keyboardHeight

        let visibleTop = messagesCollectionView.contentOffset.y
        let visibleBottom = visibleTop + safeVisibleHeight
        
        var targetOffsetY: CGFloat?

        // Top of the cell is above the visible area
        if cellFrame.minY < visibleTop {
            targetOffsetY = cellFrame.minY
        }
        // Bottom of the cell is hidden behind keyboard/input bar
        else if cellFrame.maxY > visibleBottom {
            targetOffsetY = cellFrame.maxY - safeVisibleHeight
        }

        // Perform scroll if needed
        if let offsetY = targetOffsetY {
            let maxOffsetY = messagesCollectionView.contentSize.height - safeVisibleHeight
            let newOffsetY = max(0, min(offsetY, maxOffsetY))
            
            messagesCollectionView.setContentOffset(
                CGPoint(x: 0, y: newOffsetY + 10),
                animated: true
            )
        }
    }
}
