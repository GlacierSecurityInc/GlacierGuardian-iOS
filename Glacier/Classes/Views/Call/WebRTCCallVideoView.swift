//
//  WebRTCCallVideoView.swift
//  Glacier
//
//  Created by andyfriedman on 5/5/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import Foundation
import WebRTC
import PureLayout

public protocol CallVideoCellDelegate: NSObjectProtocol {
    func doCleanup()
    func hideAvatar(hide:Bool)
    func showMuted(show:Bool)
}

class WebRTCCallVideoView: UICollectionView {
    
    //weak var memberViewDelegate: CallMemberViewDelegate?
    let layout: CallVideoGridLayout
    var participantsArray: [WebRTCCallParticipant] = []
    
    init() {
        self.layout = CallVideoGridLayout()
        super.init(frame: .zero, collectionViewLayout: layout)
        layout.delegate = self
        self.backgroundColor = GlobalTheme.shared.lightThemeColor

        register(WebRTCVideoGridCell.self, forCellWithReuseIdentifier: WebRTCVideoGridCell.reuseIdentifier)
        
        dataSource = self
        delegate = self
    }

    required init?(coder: NSCoder) {
        self.layout = CallVideoGridLayout()
    
        super.init(coder: coder)
        self.frame = .zero
        self.collectionViewLayout = layout
        layout.delegate = self
        self.backgroundColor = GlobalTheme.shared.lightThemeColor

        register(WebRTCVideoGridCell.self, forCellWithReuseIdentifier: WebRTCVideoGridCell.reuseIdentifier)
        dataSource = self
        delegate = self
    }

    //deinit { call.removeObserver(self) }
    
    func addParticipant(videoView: RTCMTLVideoView, name: String?, image: UIImage?) {
        //create a VideoView here and add it
        //let videoView = RTCMTLVideoView(frame: .zero)
        let callParticipant = WebRTCCallParticipant(view: videoView, image:image, name:name)
        //callParticipant.participant.delegate = callParticipant
        callParticipant.participantView.delegate = self
        participantsArray.append(callParticipant)
        self.backgroundColor = GlobalTheme.shared.lightThemeColor
        
        DispatchQueue.main.async {
            self.reloadData()
        }
    }
    
    func removeAllParticipants() {
        participantsArray.removeAll()
        DispatchQueue.main.async {
            self.reloadData()
        }
    }
}

extension WebRTCCallVideoView: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? WebRTCVideoGridCell else { return }
        cell.cleanupRemoteParticipant()
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        
    }
}

extension WebRTCCallVideoView: UICollectionViewDataSource {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return participantsArray.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: WebRTCVideoGridCell.reuseIdentifier,
            for: indexPath
        ) as! WebRTCVideoGridCell
        
        let participant = participantsArray[indexPath.row]
        DDLogInfo("collectionView cellForItemAt row: \(indexPath.row)")
        
        cell.configure(participant: participant, numRecs: participantsArray.count)
        participant.setCallVideoCellDelegate(delegate: cell)
        
        return cell
    }
}

// MARK:- RTCVideoViewDelegate
extension WebRTCCallVideoView: RTCVideoViewDelegate {
    func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        self.setNeedsLayout()
    }
}
    

extension WebRTCCallVideoView: CallVideoGridLayoutDelegate {
    var maxColumns: Int {
        //return 2
        let wide = width
        if wide > 1080 {
            return 4
        } else if wide > 768 {
            return 3
        } else {
            return 2
        }
    }

    var maxRows: Int {
        if height > 1024 {
            return 4
        } else {
            return 3
        }
    }
    
    var width: CGFloat {
        return self.frame.width
    }
    
    var height: CGFloat {
        return self.frame.height
    }

    var maxItems: Int { maxColumns * maxRows }
}

class WebRTCVideoGridCell: UICollectionViewCell {
    static let reuseIdentifier = "WebRTCVideoGridCell"
    var callParticipant: WebRTCCallParticipant?
    private var hasBeenConfigured = false
    private var oneOf = 1 //not good coding here
    
    let mutedView = UIButton()
    
    let avatarView = AvatarImageView()
    lazy var avatarWidthConstraint = avatarView.autoSetDimension(.width, toSize: CGFloat(avatarDiameter))
    var avatarDiameter: UInt {
        layoutIfNeeded()

        if bounds.width > 350 && oneOf <= 2 {
            return 240
        } else if bounds.width > 180 {
            return 112
        } else if bounds.width > 102 {
            return 96
        } else if bounds.width > 36 {
            return UInt(bounds.width) - 36
        } else {
            return 16
        }
    }
    
    override var bounds: CGRect {
        didSet { updateDimensions() }
    }

    override var frame: CGRect {
        didSet { updateDimensions() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.layer.cornerRadius = 10
        contentView.clipsToBounds = true
    }
    
    
    func configure(participant: WebRTCCallParticipant, numRecs: Int) {
        hasBeenConfigured = true
        oneOf = numRecs
        
        participant.participantView.frame = bounds
        contentView.addSubview(participant.participantView)
        participant.participantView.autoPinEdgesToSuperviewEdges()
        participant.participantView.contentMode = .scaleAspectFill
        
        if let img = participant.participantImage {
            avatarView.image = img
        } else {
            DDLogError("Can't find participantImage in configure")
        }
        
        contentView.addSubview(avatarView)
        avatarWidthConstraint.constant = CGFloat(avatarDiameter)
        avatarView.configureView(numRecs: oneOf)
        
        setupMicOffButton()
        mutedView.isHidden = !participant.isMuted
        
        // check if videoEnabled
        //var hide = false
        //hideAvatar(hide: hide)
        
        callParticipant = participant
    }
    
    private func setupMicOffButton() {
        mutedView.translatesAutoresizingMaskIntoConstraints = false;
        let micOffImage = UIImage(systemName: "mic.slash.fill")
        mutedView.setImage(micOffImage, for: UIControl.State())
        mutedView.tintColor = UIColor.lightGray
        mutedView.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        mutedView.isHidden = true
        
        contentView.addSubview(mutedView)
        
        mutedView.autoPinEdge(.top, to: .bottom, of: avatarView, withOffset: 5.0)
        let xconstraint = NSLayoutConstraint(
            item: mutedView,
            attribute: .centerX,
            relatedBy: .equal,
            toItem: contentView,
            attribute: .centerX,
            multiplier: 1.0,
            constant: 0.0)
        contentView.addConstraint(xconstraint)
        xconstraint.isActive = true
    }
    
    private func updateDimensions() {
        guard hasBeenConfigured else { return }
        callParticipant?.participantView.frame = bounds
        avatarWidthConstraint.constant = CGFloat(avatarDiameter)
    }
    
    func cleanupRemoteParticipant() {
        callParticipant?.setCallVideoCellDelegate(delegate: nil)
        callParticipant?.participantView.removeFromSuperview()
        avatarView.removeFromSuperview()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension WebRTCVideoGridCell: CallVideoCellDelegate {
    func doCleanup() {
        cleanupRemoteParticipant()
    }
    
    func hideAvatar(hide:Bool) {
        avatarView.isHidden = hide
    }
    
    func showMuted(show:Bool) {
        mutedView.isHidden = !show
    }
}

class WebRTCCallParticipant : NSObject {
    //let participant: RemoteParticipant!
    //let buddy: ChatBuddyModel!
    let participantView: RTCMTLVideoView!
    var participantImage: UIImage?
    var participantName: String?
    var isMuted = false
    weak var callCellDelegate: CallVideoCellDelegate?
    
    public init(view: RTCMTLVideoView, image: UIImage?, name: String?) {
        //buddy = remoteParticipant
        participantView = view
        participantImage = image
        participantName = name
    }
    
    func setCallVideoCellDelegate(delegate: CallVideoCellDelegate?) {
        callCellDelegate = delegate
    }
}

class AvatarImageView: UIImageView {

    public init() {
        super.init(frame: .zero)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    public override init(image: UIImage?) {
        super.init(image: image)
    }

    func configureView(numRecs: Int) {
        self.autoPinConstraints(numRecs: numRecs)
        self.layer.masksToBounds = true
        self.contentMode = .scaleToFill
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = frame.size.width / 2
    }
    
    func autoPinConstraints(numRecs: Int)
    {
        self.translatesAutoresizingMaskIntoConstraints = false;
        let constraint = NSLayoutConstraint(
            item: self,
            attribute: .width,
            relatedBy: .equal,
            toItem: self,
            attribute: .height,
            multiplier: 1.0,
            constant: 0.0)
        constraint.autoInstall()
        
        if (numRecs > 1) {
            autoCenterInSuperview()
        } else {
            let xconstraint = NSLayoutConstraint(
                item: self,
                attribute: .centerX,
                relatedBy: .equal,
                toItem: superview,
                attribute: .centerX,
                multiplier: 1.0,
                constant: 0.0)
            xconstraint.autoInstall()
        
            let yconstraint = NSLayoutConstraint(
                item: self,
                attribute: .centerY,
                relatedBy: .equal,
                toItem: superview,
                attribute: .centerY,
                multiplier: 0.8,
                constant: 0.0)
            yconstraint.autoInstall()
        }
    }
}
