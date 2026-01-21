//
//  UserReactionDetailsTableViewCell.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 29/10/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import UIKit

/**
 It informs the chat room views about user interactions with the reaction emojis
 */
protocol UserReactionDetailsTableViewCellDelegate {
    func didRemoveAllReactions(for id: String)
}

/**
 It presents user reaction details like avatar image, name and list of reaction emojis
 */
class UserReactionDetailsTableViewCell: UITableViewCell {
    
    // MARK: Public properties
    
    static let identifier = "UserReactionDetailsTableViewCell"
    
    var delegate: UserReactionDetailsViewDelegate?
    var cellDelegate: UserReactionDetailsTableViewCellDelegate?
    var reactionDetails: UserReactionDetails? {
        didSet {
            self.showReactionDetails()
        }
    }
    
    // MARK: - Private propertis
    
    private var didShowReactionDetails: Bool = false
    
    // MARK: UI controls
    
    private  lazy var avatarImage: UIImageView = {
        let image = UIImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.layer.borderWidth = 1
        image.layer.borderColor = traitCollection.userInterfaceStyle == .dark ? UIColor.gray.cgColor : UIColor.darkGray.cgColor
        return image
    }()
    
    private lazy var nameInitialsLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 20, weight: .medium)
        return label
    }()
    
    private lazy var nameLabel: UILabel = {
        var label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        label.textColor = traitCollection.userInterfaceStyle == .dark ? UIColor.white : UIColor.black
        return label
    }()
    
    private lazy var reactionsStackView: UIStackView = {
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.spacing = 4
        stackView.distribution = .fill
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()
   
    // MARK: - Lifecycle methods
    
    override func layoutSubviews() {
        super.layoutSubviews()
        self.configureView()
    }
    
    override func prepareForReuse() {
        self.avatarImage.image = nil
        self.nameInitialsLabel.text = nil
        self.nameLabel.text = nil
        self.reactionsStackView.removeFromSuperview()
        self.didShowReactionDetails = false
    }
    
    // MARK: - Private methods
    
    private func configureView() {
        self.selectionStyle = .none
        
        self.addSubview(self.avatarImage)
        let avtarImageSize: CGFloat = 40
        NSLayoutConstraint.activate([
            self.avatarImage.leftAnchor.constraint(equalTo: self.leftAnchor, constant: 0),
            self.avatarImage.centerYAnchor.constraint(equalTo: self.centerYAnchor, constant: 0),
            self.avatarImage.widthAnchor.constraint(equalToConstant: avtarImageSize),
            self.avatarImage.heightAnchor.constraint(equalToConstant: avtarImageSize)
        ])
        self.avatarImage.layer.cornerRadius = avtarImageSize / 2
        self.avatarImage.clipsToBounds = true
        
        self.addSubview(nameInitialsLabel)
        NSLayoutConstraint.activate([
            nameInitialsLabel.centerXAnchor.constraint(equalTo: self.avatarImage.centerXAnchor, constant: 0),
            nameInitialsLabel.centerYAnchor.constraint(equalTo: self.avatarImage.centerYAnchor, constant: 0)
        ])
        
        self.addSubview(self.nameLabel)
        NSLayoutConstraint.activate([
            self.nameLabel.centerYAnchor.constraint(equalTo: self.avatarImage.centerYAnchor, constant: 0),
            self.nameLabel.leftAnchor.constraint(equalTo: self.avatarImage.rightAnchor, constant: 10)
        ])
        
        self.addSubview(self.reactionsStackView)
        NSLayoutConstraint.activate([
            self.reactionsStackView.centerYAnchor.constraint(equalTo: self.nameLabel.centerYAnchor, constant: 0),
            self.reactionsStackView.rightAnchor.constraint(equalTo: self.rightAnchor, constant: 0),
            self.reactionsStackView.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            self.reactionsStackView.heightAnchor.constraint(equalToConstant: 25)
        ])
    }
    
    private func showReactionDetails() {
        guard !self.didShowReactionDetails, let details = self.reactionDetails else { return }
        if let imageData = details.avatarImage, let image = UIImage(data: imageData) {
            self.avatarImage.image = image
            self.nameInitialsLabel.text = nil
        } else {
            self.nameInitialsLabel.text = details.displayName.getInitials()
        }
        self.nameLabel.text = details.displayName
        
        for reaction in details.reactions {
            let button = UIButton()
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitle(reaction, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
            button.heightAnchor.constraint(equalToConstant: 25).isActive = true
            button.widthAnchor.constraint(equalToConstant: 25).isActive = true
            button.addTarget(self, action: #selector(didTapReaction(_:)), for: .touchUpInside)
            reactionsStackView.addArrangedSubview(button)
        }
        
        self.didShowReactionDetails = true
    }
    
    @objc private func didTapReaction(_ sender: UIButton) {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        
        guard var details = self.reactionDetails,
              details.isSelf,
              let reaction = sender.title(for: .normal),
              let index = details.reactions.firstIndex(of: reaction) else {
            return
        }
        
        details.reactions.remove(at: index)
        delegate?.didTapOn(reaction: reaction) {
            if details.reactions.isEmpty {
                self.cellDelegate?.didRemoveAllReactions(for: details.id)
            } else {
                self.reactionsStackView.removeArrangedSubview(sender)
                sender.removeFromSuperview()
                
                self.reactionDetails?.reactions = details.reactions
            }
        }
    }
}
