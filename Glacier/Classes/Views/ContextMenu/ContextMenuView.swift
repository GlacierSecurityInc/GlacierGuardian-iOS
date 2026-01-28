//  Glacier
//  Created by Prem Pratap Singh on 17/10/25.
//  Copyright © 2025 Glacier. All rights reserved.

import UIKit
import MessageKit

/**
 This is the context menu that is displayed when user long presses on a chat room bubble.
 It presents,
 1. Emojis list for adding reaction to the long pressed chat message
 2. Copy chat message
 3. Delete chat message
 */
class ContextMenuView: UIView {
    
    // MARK: - Public properties
    
    let message: any GRDBRecord
    let location: CGPoint
    let delegate: ContextMenuDelegate?
    
    // MARK: - Private properties
    
    private var messageKind: MessageKind? {
        guard let chatMessage = message as? ChatMessage else {
            guard let chatRoomMessage = message as? ChatRoomMessage else {
                return nil
            }
            return chatRoomMessage.kind
        }
        return chatMessage.kind
    }
    
    private var messageProtocol: MessageProtocol? {
        guard let chatMessage = message as? ChatMessage else {
            guard let chatRoomMessage = message as? ChatRoomMessage else {
                return nil
            }
            let chatRoomMesageModel = ChatRoomMessageModel(message: chatRoomMessage)
            return chatRoomMesageModel
        }
        let chatMesageModel = ChatMessageModel(message: chatMessage)
        return chatMesageModel
    }
    
    // MARK: - Initilizer
    
    init(message: any GRDBRecord, location: CGPoint, delegate: ContextMenuDelegate) {
        self.message = message
        self.delegate = delegate
        self.location = location
        
        super.init(frame: .zero)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Private methods
    
    private func setupView() {
        let isDarkMode = traitCollection.userInterfaceStyle == .dark
        
        let contentView = UIView()
        contentView.backgroundColor = isDarkMode ? UIColor.systemGray4 : UIColor.white
        contentView.layer.cornerRadius = 12
        contentView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.clipsToBounds = true
        addSubview(contentView)
        
        // Main content stack
        let mainStack = UIStackView()
        mainStack.axis = .vertical
        mainStack.distribution = .fillProportionally
        mainStack.alignment = .top
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainStack)
        
        // Emoji row
        let emojiStack = UIStackView()
        emojiStack.axis = .horizontal
        emojiStack.spacing = 10
        emojiStack.alignment = .center
        
        let emojis = ["❤️", "👍", "👎", "😂", "😮", "😢"]
        for emoji in emojis {
            let button = createEmojiButton(emoji: emoji)
            button.addTarget(self, action: #selector(didTapEmoji(_:)), for: .touchUpInside)
            emojiStack.addArrangedSubview(button)
        }
        
        let moreEmojiButton = createEmojiButton(emoji: "•••")
        moreEmojiButton.addTarget(self, action: #selector(didTapOnMoreEmojiButton(_:)), for: .touchUpInside)
        moreEmojiButton.accessibilityLabel = "More reactions"
        emojiStack.addArrangedSubview(moreEmojiButton)
        
        mainStack.addArrangedSubview(emojiStack)
        
        var actions: [ContextMenuItem] = []
        if let kind = messageKind {
            let divider = UIView()
            divider.backgroundColor = UIColor.separator
            divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
            mainStack.addArrangedSubview(divider)
            
            switch kind {
            case .text, .attributedText, .emoji, .photo:
                actions = [.copy, .delete]
            default:
                actions = [.delete]
            }
            
            if let messageProtocol = self.messageProtocol {
                if !messageProtocol.isMessageIncoming, messageProtocol.messageError != nil {
                    actions.append(.resend)
                }
                if let mkey = messageProtocol.messageMediaItemKey, !mkey.isEmpty, messageProtocol.url != nil, messageProtocol.messageError != nil {
                    actions.append(.cancelDownload)
                }
            }
            
            actions.append(.viewProfile)
            
            for action in actions {
                let button = createActionButton(title: action.label)
                button.addTarget(self, action: #selector(didTapAction(_:)), for: .touchUpInside)
                mainStack.addArrangedSubview(button)
            }
        }
        
        // Position near the long press location
        let menuHeight = (actions.count + 1) * 40
        let menuSize = CGSize(width: 300, height: CGFloat(menuHeight))
        var menuFrame = CGRect(origin: location, size: menuSize)
        let containerBounds = UIScreen.main.bounds
        
        // Adjust to stay within bounds
        if menuFrame.maxX > containerBounds.maxX {
            menuFrame.origin.x = containerBounds.maxX - menuSize.width - 10
        }
        if menuFrame.maxY > containerBounds.maxY {
            menuFrame.origin.y = location.y - menuSize.height - 10
        }
        if menuFrame.minX < containerBounds.minX {
            menuFrame.origin.x = containerBounds.minX + 10
        }
        if menuFrame.minY < containerBounds.minY {
            menuFrame.origin.y = containerBounds.minY + 10
        }
        self.frame = menuFrame
        
        // Constraints
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
        
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 4)
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 8
    }
    
    private func createEmojiButton(emoji: String) -> UIButton {
        let isDarkMode = traitCollection.userInterfaceStyle == .dark
        
        let button = UIButton()
        button.setTitle(emoji, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.setTitleColor(isDarkMode ? UIColor.white : UIColor.black, for: .normal)
        button.backgroundColor = isDarkMode ? UIColor.black.withAlphaComponent(0.6) : UIColor.systemGray5.withAlphaComponent(0.6)
        button.contentEdgeInsets = UIEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }
    
    private func createActionButton(title: String) -> UIButton {
        let isDarkMode = traitCollection.userInterfaceStyle == .dark
        
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(isDarkMode ? UIColor.white : UIColor.black, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18)
        button.contentHorizontalAlignment = .left
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
    
    @objc private func didTapEmoji(_ sender: UIButton) {
        guard let emoji = sender.title(for: .normal) else {
            return
        }
        
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        
        delegate?.addReaction(emoji, to: message)
        removeFromSuperview()
    }
    
    @objc private func didTapOnMoreEmojiButton(_ sender: UIButton) {
        delegate?.showMoreEmojis(for: message)
        removeFromSuperview()
    }
    
    @objc private func didTapAction(_ sender: UIButton) {
        guard let buttonTitle = sender.title(for: .normal),
              let menuItem = ContextMenuItem(rawValue: buttonTitle) else {
            return
        }
        delegate?.handleAction(menuItem, for: message)
        removeFromSuperview()
    }
}
