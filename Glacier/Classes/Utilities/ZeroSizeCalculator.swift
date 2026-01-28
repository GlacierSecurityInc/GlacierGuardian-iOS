//
//  CustomTextMessageSizeCalculator.swift
//  ChatExample
//
//  Created by Vignesh J on 30/04/21.
//  Copyright © 2021 MessageKit. All rights reserved.
//

import MessageKit
import UIKit

class ZeroSizeCalculator: MessageSizeCalculator {
  override func messageContainerSize(
    for message: MessageType,
    at indexPath: IndexPath)
    -> CGSize
  {
      return .zero
  }

  func messageLabelSize(
    for message: MessageType,
    at _: IndexPath)
    -> CGSize
  {
    return .zero
  }
    
    open override func sizeForItem(at indexPath: IndexPath) -> CGSize {
        let dataSource = messagesLayout.messagesDataSource
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        let itemHeight = cellTopLabelSize(for: message, at: indexPath).height
        return CGSize(width: messagesLayout.itemWidth, height: itemHeight)
    }
    
    open override func avatarSize(for message: MessageType, at indexPath: IndexPath) -> CGSize {
        return .zero
    }
}
