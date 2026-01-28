//  Glacier
//  Created by Prem Pratap Singh on 11/10/25.
//  Copyright © 2025 Glacier. All rights reserved.

import MessageKit
import UIKit
import Foundation

extension MessageContentCell {
    
    /**
     Returns tag number for the stack view containing list of user reactions
     */
    private var reactionsStackViewTag: Int { 999 }
    
    /**
     This method checks if the given chat message has user reactions. If yes, it adds a `StackView` in the view
     that contains `ReactionView` for each of the user reactions.
     */
    func showReactionsIfAny(for message: any GRDBRecord, isIncomingMessage: Bool, isShowingTopLabelText: Bool) {
        var messageReactions: [ChatMessageReaction]?
        if let chatMessage = message as? ChatMessage {
            messageReactions = chatMessage.reactions
        } else if let chatRoomMessage = message as? ChatRoomMessage {
            messageReactions = chatRoomMessage.reactions
        }
        guard let reactions = messageReactions, !reactions.isEmpty else {
            if let view = contentView.viewWithTag(reactionsStackViewTag), let existingStackView = view as? UIStackView {
                existingStackView.removeFromSuperview()
            }
            return
        }
        
        // Group reactions by emoji and count occurrences
        var reactionCounts: [String: Int] = [:]
        var accessibilityLabel = ""
        for reaction in reactions {
            for emoji in reaction.reactions {
                reactionCounts[emoji, default: 0] += 1
                accessibilityLabel += "\(emoji)_"
            }
        }
        
        if let view = contentView.viewWithTag(reactionsStackViewTag), let existingStackView = view as? UIStackView {
            // Don't proceed if the emojis are the same as before
            if let existingAccessibilityLabel = existingStackView.accessibilityLabel, existingAccessibilityLabel == accessibilityLabel {
                return
            }
            existingStackView.removeFromSuperview()
        }
        
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.spacing = 32
        stackView.distribution = .fill
        stackView.alignment = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.tag = reactionsStackViewTag
        stackView.accessibilityLabel = accessibilityLabel
        
        // Create ReactionView for each unique reaction and its count
        for (reaction, count) in reactionCounts {
            let reactionView = ReactionView()
            reactionView.configure(reaction: reaction, count: count)
            stackView.addArrangedSubview(reactionView)
        }
        
        // Add stack view to the cell's content view
        contentView.addSubview(stackView)
        
        // Setup stack view constraints
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: messageContainerView.topAnchor, constant: -25),
            stackView.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            stackView.heightAnchor.constraint(equalToConstant: 30)
        ])
        
        // Setup reaction LTR or RTL alignment based on incoming/outgoing message type
        if isIncomingMessage {
            stackView.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor, constant: 8).isActive = true
        } else {
            stackView.trailingAnchor.constraint(equalTo: messageContainerView.trailingAnchor, constant: -(avatarView.frame.width + 8)).isActive = true
        }
        
        // Adjust top label text position
        if isShowingTopLabelText {
            DispatchQueue.main.async {
                self.messageTopLabel.frame.origin.y = self.messageContainerView.frame.origin.y - 45
            }
        }
    }
    
    /**
     Checks if the given touch event overlaps any reaction view bounding box. If yes, it is treated as a touch event for the reaction view.
     Given touch object belongs to message collection view.
     */
    func checkIfUserTouchedAnyReaction(_ touch: UITouch, didTouchReaction: @escaping (String?) -> Void) {
        guard let reactionStackView = contentView.viewWithTag(reactionsStackViewTag) as? UIStackView else {
            didTouchReaction(nil)
            return
        }
        
        let cellPoint = touch.location(in: reactionStackView)
        for view in reactionStackView.arrangedSubviews {
            if let reactionView = view as? ReactionView, let reaction = reactionView.reaction {
                let frame: CGRect = CGRect(x: reactionView.frame.origin.x, y: reactionView.frame.origin.y, width: 30, height: 30)
                if frame.contains(cellPoint) {
                    didTouchReaction(reaction)
                    break
                }
            }
        }
        
        didTouchReaction(nil)
    }
}

/**
 Presents UI for reaction emoji, reactions count and the background
 */
class ReactionView: UIView {
    
    // MARK: - Public properties
    var reaction: String?
    
    // MARK: - Private properties
    private var count: Int = 0
    private var didConfigure = false
    
    // MARK: - Public methods
    
    func configure(reaction: String, count: Int) {
        guard !didConfigure else { return }
        
        self.reaction = reaction
        self.count = count
        
        setupView()
        didConfigure = true
    }
    
    // MARK: - Private methods
    
    private func setupView() {
        guard let reactionGraphics = reaction else { return }
        let isDarkMode = traitCollection.userInterfaceStyle == .dark
        
        // Background and container view
        let containerView = UIView(frame: .zero)
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        containerView.layer.borderWidth = 1.0
        containerView.layer.borderColor = isDarkMode ? UIColor.white.cgColor : UIColor.black.cgColor
        containerView.layer.cornerRadius = 8
        addSubview(containerView)
        
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            containerView.heightAnchor.constraint(equalToConstant: 30),
            containerView.widthAnchor.constraint(equalToConstant: 30)
        ])
        
        // Reaction emoji
        let reactionLabel = UILabel()
        reactionLabel.translatesAutoresizingMaskIntoConstraints = false
        reactionLabel.font = .systemFont(ofSize: 14, weight: .medium)
        reactionLabel.adjustsFontSizeToFitWidth = true
        reactionLabel.textAlignment = .center
        reactionLabel.text = reactionGraphics
        containerView.addSubview(reactionLabel)
        
        NSLayoutConstraint.activate([
            reactionLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 5),
            reactionLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -5),
            reactionLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor, constant: 0),
            reactionLabel.heightAnchor.constraint(equalTo: containerView.heightAnchor)
        ])
        
        // Reactions count
        guard count > 1 else { return }
        let countLabel = UILabel()
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        countLabel.adjustsFontSizeToFitWidth = true
        countLabel.textColor = UIColor.white
        countLabel.textAlignment = .center
        countLabel.text = "\(count)"
        containerView.addSubview(countLabel)
        
        NSLayoutConstraint.activate([
            countLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -2),
            countLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -2),
            countLabel.widthAnchor.constraint(equalToConstant: 15),
            countLabel.heightAnchor.constraint(equalToConstant: 15),
        ])
    }
}
