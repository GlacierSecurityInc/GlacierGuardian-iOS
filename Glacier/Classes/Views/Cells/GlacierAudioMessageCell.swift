//
//  GlacierAudioMessageCell.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 03/11/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import UIKit
import MessageKit

/**
 Informs chat room about user interaction with cell controls
 */
protocol GlacierAudioMessageCellDelegate {
    func didChangeAudioPlaybackSpeed(_ speed: Float)
}

/**
 It sets up custom UI design with an additional audio playback speed control button
 */
class GlacierAudioMessageCell: AudioMessageCell {
    
    // MARK: - Public properties
    
    var cellDelegate: GlacierAudioMessageCellDelegate?
    
    var isPlaybackSpeedButtonHidden: Bool = false {
        didSet {
            if let speed = UserDefaults.standard.value(forKey: kAudioPlaybackSpeed) as? Float,
               let playbackSpeed = AudioPlaybackSpeed(rawValue: speed) {
                self.audioPlaybackSpeed = playbackSpeed
            }
            
            UIView.animate(withDuration: 0.1, delay: 0, options: .curveEaseIn) {
                self.playbackSpeedButton.alpha = self.isPlaybackSpeedButtonHidden ? 0 : 1
            }
        }
    }
    
    // MARK: - Private properties
    
    private lazy var playbackSpeedButton: UIButton = {
        let speedButton = UIButton(frame: .zero)
        speedButton.translatesAutoresizingMaskIntoConstraints = false
        speedButton.layer.cornerRadius = 15
        speedButton.layer.borderWidth = 1
        speedButton.titleLabel?.font = UIFont.systemFont(ofSize: 12)
        return speedButton
    }()
    
    private var audioPlaybackSpeed: AudioPlaybackSpeed = .one {
        didSet {
            playbackSpeedButton.setTitle(audioPlaybackSpeed.title, for: .normal)
        }
    }
    
    private var playButtonLeadingConstraint: NSLayoutConstraint?
    private var progressViewLeadingConstraint: NSLayoutConstraint?
    
    // MARK: - Lifecycle methods
    
    override func setupConstraints() {
        playButton.translatesAutoresizingMaskIntoConstraints = false
        activityIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        progressView.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        
        playButtonLeadingConstraint = playButton.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor, constant: 10)
        playButtonLeadingConstraint?.isActive = true
        
        progressViewLeadingConstraint = progressView.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor, constant: 10)
        progressViewLeadingConstraint?.isActive = true
        
        NSLayoutConstraint.activate([
            playButton.topAnchor.constraint(equalTo: messageContainerView.topAnchor, constant: 10),
            playButton.widthAnchor.constraint(equalToConstant: 30),
            playButton.heightAnchor.constraint(equalToConstant: 30),
            
            activityIndicatorView.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            activityIndicatorView.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            
            playbackSpeedButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 10),
            playbackSpeedButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor, constant: 0),
            playbackSpeedButton.widthAnchor.constraint(equalToConstant: 30),
            playbackSpeedButton.heightAnchor.constraint(equalToConstant: 30),
            
            durationLabel.trailingAnchor.constraint(equalTo: messageContainerView.trailingAnchor, constant: -15),
            durationLabel.widthAnchor.constraint(equalToConstant: 35),
            durationLabel.bottomAnchor.constraint(equalTo: messageContainerView.bottomAnchor, constant: -10),
            
            progressView.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -10),
            progressView.centerYAnchor.constraint(equalTo: durationLabel.centerYAnchor, constant: 0)
        ])
    }
    
    override func setupSubviews() {
        super.messageContainerView.addSubview(playbackSpeedButton)
        playbackSpeedButton.alpha = 0
        
        super.setupSubviews()
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
    }
    
    /// Handle tap gesture on contentView and its subviews.
    open override func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let touchLocation = gesture.location(in: self)
        
        // compute playback speed button touch area
        let playbackButtonTouchArea = CGRect(
            x: playbackSpeedButton.frame.origin.x - 10.0,
            y: playbackSpeedButton.frame.origin.y - 10,
            width: playbackSpeedButton.frame.size.width + 20,
            height: playbackSpeedButton.frame.size.height + 20)
        let translateTouchLocation = convert(touchLocation, to: messageContainerView)
        if playbackButtonTouchArea.contains(translateTouchLocation) {
            let availableSpeeds = AudioPlaybackSpeed.allCases
            if var index = availableSpeeds.firstIndex(where: { $0.title == audioPlaybackSpeed.title }) {
                index += 1
                if index == availableSpeeds.count {
                    index = 0
                }
                audioPlaybackSpeed = availableSpeeds[index]
            }
            cellDelegate?.didChangeAudioPlaybackSpeed(audioPlaybackSpeed.speed)
        } else {
            super.handleTapGesture(gesture)
        }
    }
    
    open override func configure(
        with message: MessageType,
        at indexPath: IndexPath,
        and messagesCollectionView: MessagesCollectionView) {
            super.configure(with: message, at: indexPath, and: messagesCollectionView)
            
            guard let dataSource = messagesCollectionView.messagesDataSource else {
                return
            }
            if !dataSource.isFromCurrentSender(message: message) {
                playButtonLeadingConstraint?.constant = 15
                progressViewLeadingConstraint?.constant = 15
            } else {
                playButtonLeadingConstraint?.constant = 10
                progressViewLeadingConstraint?.constant = 10
            }
            playButton.setNeedsLayout()
            progressView.setNeedsLayout()
            
            guard let displayDelegate = messagesCollectionView.messagesDisplayDelegate else {
                return
            }
            
            let tintColor = displayDelegate.audioTintColor(for: message, at: indexPath, in: messagesCollectionView)
            playbackSpeedButton.setTitleColor(tintColor, for: .normal)
            playbackSpeedButton.layer.borderColor = tintColor.cgColor
            
            if let speed = UserDefaults.standard.value(forKey: kAudioPlaybackSpeed) as? Float,
               let playbackSpeed = AudioPlaybackSpeed(rawValue: speed) {
                self.audioPlaybackSpeed = playbackSpeed
            } else {
                self.audioPlaybackSpeed = AudioPlaybackSpeed.one
            }
            
            displayDelegate.configureAudioCell(self, message: message)
        }
}
