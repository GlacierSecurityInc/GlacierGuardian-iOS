//
//  VideoCallViewController.swift
//  Created by Guillermo Olmedo on 4/15/20.
//  Copyright © 2020 Glacier Security. All rights reserved.
//

import UIKit
import Foundation
import Font_Awesome_Swift
import CallKit
import WebRTC
import AVKit

@objc open class VideoCallViewController: UIViewController, GlacierCallDelegateProtocol {
    
    @IBOutlet weak var mainView: UIView!
    @IBOutlet weak var minimizedView: UIView!
    
    @IBOutlet weak var miniMuteLabel: UILabel!
    @IBOutlet weak var miniBarTitleLabel: UILabel!
    
    @IBOutlet weak var profileImageView: UIImageView!
    //@IBOutlet weak var remoteView: VideoView!
    
    @IBOutlet weak var remoteParticipantsView: WebRTCCallVideoView!
    
    @IBOutlet weak var signalStateLabel: UILabel!
    
    @IBOutlet weak var topView: UIView!
    @IBOutlet weak var closeButton: UIButton!
    @IBOutlet weak var addButton: UIButton!
    @IBOutlet weak var nameLabel: UILabel!
    @IBOutlet weak var progressLabel: UILabel!
    
    @IBOutlet weak var buttonView: UIView!
    @IBOutlet weak var muteButton: UIButton!
    @IBOutlet weak var videoButton: UIButton!
    @IBOutlet weak var speakerButton: UIButton!
    @IBOutlet weak var flipButton: UIButton!
    //@IBOutlet weak var speakerLabel: UILabel!
    
    @IBOutlet weak var disconnectButton: UIButton!
    @IBOutlet weak var mutedMark: UIButton!
    
    @IBOutlet weak var bottomView: UIView!
    
    private lazy var routePickerView: AVRoutePickerView = {
        let picker = AVRoutePickerView()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.prioritizesVideoDevices = false
        return picker
    }()
    
    var callManager: CallManager?
    
    var connectCompletionHandler: ((Bool)->Swift.Void?)? = nil
    
    @IBOutlet weak var localView: UIView! //VideoView
    //var localVideoView: VideoView?
    
    private var localRenderer: RTCMTLVideoView?
    private var remoteRenderer: RTCMTLVideoView?
    private var pendingRemoteRender = false
    private var pendingParticipant: (name: String?, image: UIImage?)?
    
    var callTimer: Timer?
    var callTimeCount = 0
    var idleCount = 0
    var currentCall: TwilioCall?
    var nameTitle: String?
    var bluetoothPossible:Bool = false
    var reconnecting:Bool = false
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        // We are done with camera
        //self.currentCall?.webrtcClient?.terminateSession() //stopCaptureLocalVideo()
        self.currentCall?.webrtcClient = nil
        self.currentCall = nil
    }
    
    @objc public func setCallManager(_ callManager: CallManager) {
        self.callManager = callManager
        self.currentCall = callManager.currentCall
    }
    
    @objc public func setNameTitle(_ name: String) {
        self.nameTitle = name.capitalized
    }
    
    override public func viewDidLoad() {
        super.viewDidLoad()
        
        let mainTapGesture = UITapGestureRecognizer(target: self, action: #selector(viewTapped))
        mainView.isUserInteractionEnabled = true
        mainView.addGestureRecognizer(mainTapGesture)
        
        let miniTapGesture = UITapGestureRecognizer(target: self, action: #selector(minimizedViewTapped))
        minimizedView.isUserInteractionEnabled = true
        minimizedView.addGestureRecognizer(miniTapGesture)
        
        localRenderer?.isHidden = true
        flipButton.isHidden = true
        videoButton.isSelected = false
        videoButton.isHidden = true
        
        UIApplication.shared.isIdleTimerDisabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        
        setupViews()
    }
    
    @objc private func becameActive() {
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    override public func viewWillDisappear(_ animated: Bool) {
        // Allow the device to sleep.
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        profileImageView.layer.cornerRadius = profileImageView.frame.height / 2.0
        profileImageView.clipsToBounds = true
        
        muteButton.layer.cornerRadius = muteButton.frame.height / 2
        muteButton.clipsToBounds = true
        videoButton.layer.cornerRadius = videoButton.frame.height / 2
        videoButton.clipsToBounds = true
        speakerButton.layer.cornerRadius = speakerButton.frame.height / 2
        speakerButton.clipsToBounds = true
        flipButton.layer.cornerRadius = flipButton.frame.height / 2
        flipButton.clipsToBounds = true
        disconnectButton.layer.cornerRadius = disconnectButton.frame.height / 2
        disconnectButton.clipsToBounds = true
        addButton.layer.cornerRadius = addButton.frame.height / 2
        addButton.clipsToBounds = true
        
        signalStateLabel.layer.cornerRadius = signalStateLabel.frame.height / 2
        signalStateLabel.clipsToBounds = true
        mutedMark.layer.cornerRadius = mutedMark.frame.height / 2
        mutedMark.clipsToBounds = true
        
        //remoteCollectionView.frame = view.bounds
    }
    
    // MARK: - UI
    
    private func setupViews() {
        localRenderer = RTCMTLVideoView(frame: CGRect.zero)
        remoteRenderer = RTCMTLVideoView(frame: self.view.frame)
        localRenderer?.translatesAutoresizingMaskIntoConstraints = false
        self.remoteRenderer?.delegate = self
        renderRemoteVideoIfReady()
        addPendingParticipantIfNeeded()
        
        var localWidth = 63
        var localHeight = 112
        if (self.view.frame.size.width > 750) {
            localWidth = 100
            localHeight = 178
        }
        NSLayoutConstraint.activate([
            localRenderer!.heightAnchor.constraint(equalToConstant: CGFloat(localHeight)),
            localRenderer!.widthAnchor.constraint(equalToConstant: CGFloat(localWidth))
        ])
        
        localView.addSubview(localRenderer!)

        localRenderer?.leadingAnchor.constraint(equalTo:localView.leadingAnchor).isActive = true
        localRenderer?.trailingAnchor.constraint(equalTo:localView.trailingAnchor).isActive = true
        localRenderer?.topAnchor.constraint(equalTo:localView.topAnchor).isActive = true
        localRenderer?.bottomAnchor.constraint(equalTo:localView.bottomAnchor).isActive = true
        
        localRenderer?.layer.cornerRadius = 10.0
        localRenderer?.clipsToBounds = true
        localRenderer?.contentMode = .scaleAspectFill
        
        minimizedView.backgroundColor = .clear
        minimizedView.isHidden = true
        
        miniMuteLabel.setFAIcon(icon: .FAMicrophoneSlash, iconSize: 14)
        miniMuteLabel.isHidden = true
        
        miniBarTitleLabel.text = "TAP TO RETURN TO CALL - Ringing..."
        
        mutedMark.isHidden = true
        signalStateLabel.isHidden = true
        
        closeButton.tintColor = .white
        closeButton.setFAIcon(icon: .FAAngleDown, iconSize: 35, forState: UIControl.State())
        
        signalStateLabel.backgroundColor = .orange
        signalStateLabel.textColor = .white
        signalStateLabel.alpha = 0.7
        //signalStateLabel.setFAText(prefixText: "", icon: .FASignal, postfixText: "  POOR CONNECTION", size: 10)
        
        let icMuteOffImage = UIImage(named: "ic-mute-off", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        let icMuteOnImage = UIImage(named: "ic-mute-on", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        muteButton.setImage(icMuteOffImage, for: .normal)
        muteButton.setImage(icMuteOnImage, for: .selected)
        
        let icVideoOnImage = UIImage(named: "ic-video-on", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        let icVideoOffImage = UIImage(named: "ic-video-off", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        videoButton.setImage(icVideoOffImage, for: .normal)
        videoButton.setImage(icVideoOnImage, for: .selected)
        videoButton.isSelected = false
        videoButton.isEnabled = false
        
        let icFlipCameraImage = UIImage(named: "ic-flip-camera", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        flipButton.setImage(icFlipCameraImage, for: UIControl.State())
        
        addButton.tintColor = .white
        addButton.setFAIcon(icon: .FAVideoCamera, iconSize: 25, forState: UIControl.State())
        addButton.isHidden = true
        if self.currentCall?.audioOnly == true {
            addButton.isHidden = false
        } else {
            videoButton.isHidden = false
            localRenderer?.isHidden = false
            flipButton.isHidden = false
            videoButton.isSelected = true
        }
        
        let icMicrophoneOnImage = UIImage(named: "ic-microphone-on", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        speakerButton.setImage(icMicrophoneOnImage, for: .normal)
        speakerButton.setImage(icMicrophoneOnImage, for: .selected)
        // Enable audio route changes immediately
        speakerButton.isEnabled = true
        
        if callManager?.isBluetoothAvailable() ?? false {
            let icBluetoothOnImage = UIImage(named: "ic-bluetooth-on", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
            speakerButton.setImage(icBluetoothOnImage, for: .normal)
        }
        
        if (nameTitle != nil) {
            nameLabel?.text = nameTitle
        }
        
        disconnectButton.backgroundColor = .red
        disconnectButton.tintColor = .white
        let buttonConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .medium)
        let phoneDown = UIImage(systemName: "phone.down.fill", withConfiguration: buttonConfiguration)
        disconnectButton.setImage(phoneDown, for: UIControl.State())
        
        view.addSubview(routePickerView)
        NSLayoutConstraint.activate([
            routePickerView.widthAnchor.constraint(equalToConstant: 1),
            routePickerView.heightAnchor.constraint(equalToConstant: 1),
            routePickerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            routePickerView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
    }
    
    @objc private func didTapRouteButton() {
        guard let internalButton = routePickerView.subviews.compactMap({ $0 as? UIButton }).first else {
            return
        }
        internalButton.sendActions(for: .touchUpInside)
    }
    
    @objc private func handleRouteChange(_ notification: Notification) {
        updateRouteButtonIcon()
    }
    
    private func updateRouteButtonIcon() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        
        guard let output = outputs.first else {
            return
        }
        
        var speakerIcon = "ic-microphone-on"
        switch output.portType {
        case .builtInSpeaker:
            speakerIcon = "ic-speaker-on"
            break
        case .builtInReceiver:
            speakerIcon = "ic-microphone-on"
            break
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            speakerIcon = "ic-bluetooth-on"
            break
        case .headphones, .headsetMic:
            speakerIcon = "ic-speaker-on"
            break
        case .airPlay:
            speakerIcon = "ic-bluetooth-on"
            break
        case .carAudio:
            speakerIcon = "ic-bluetooth-on"
        default:
            break
        }
        
        let iconImage = UIImage(named: speakerIcon, in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        self.speakerButton.setImage(iconImage, for: .normal)
    }
    
    public func handleAudioDenied() {
        handlePermissionDenied("Allow Audio", message: "Whoops! It looks like you have not permitted Guardian to access your Microphone. To use Guardian calling, please enable the Microphone in the Guardian settings on your device.", includeEnable: true)
    }
    
    func handleVideoDenied() {
        handlePermissionDenied("Allow Video", message: "Whoops! It looks like you have not permitted Guardian to access your Camera. To use Guardian video calling, please enable the Camera in the Guardian settings on your device. Note: You cannot do this during the call or the call will drop.", includeEnable: false)
    }
    
    func handlePermissionDenied(_ title: String, message: String, includeEnable: Bool) {
        DispatchQueue.main.async {
            let permissionAlert = UIAlertController(title: title, message: message, preferredStyle: .alert)

            if (includeEnable) {
                permissionAlert.addAction(UIAlertAction(title: "Enable", style: .default, handler: { (action) -> Void in
                    if let appSettings = URL(string: UIApplication.openSettingsURLString) {
                        Application.shared.open(appSettings, options: [:], completionHandler: nil)
                    }
                }))
                permissionAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { (action) -> Void in
                    //do nothing
                }))
            } else {
                permissionAlert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: { (action) -> Void in
                    //do nothing
                }))
            }
            
            self.present(permissionAlert, animated: true, completion: nil)
        }
    }
    
    public func handleVideoUpgradeRequest(completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            //if app is not visible, automatically decline
            if UIApplication.shared.applicationState != .active {
                completion(false)
                return
            }
            
            let alert = UIAlertController(
                title: "Video Request",
                message: "The remote user wants to add video to this call. Allow?",
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(title: "Accept", style: .default) { _ in
                completion(true)
            })
            alert.addAction(UIAlertAction(title: "Decline", style: .cancel) { _ in
                completion(false)
            })
        
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    public func doConnectCall(_ call: TwilioCall, with: String) {
        //self.connectCall(call)
        self.currentCall = call
        if self.currentCall?.audioOnly == false {
            addButton.isHidden = true
            videoButton.isHidden = false
            localRenderer?.isHidden = false
            flipButton.isHidden = false
            videoButton.isSelected = true
        }
        self.videoButton.isEnabled = true
        self.speakerButton.isEnabled = true
        nameLabel.text = with.capitalized
    }
    
    private func showCallMenu(state: Bool) {
        UIView.animate(withDuration: 0.4, animations: {
            self.topView.alpha = state ? 1.0 : 0
            self.buttonView.alpha = state ? 1.0 : 0
            //self.disconnectButton.alpha = state ? 1.0 : 0
        }, completion: { _ in
            self.topView.isHidden = !state
            self.buttonView.isHidden = !state
        })
    }
    
    private func killCallTimer() {
        callTimer?.invalidate()
        callTimer = nil
    }
    
    // MARK: - Callbacks
    
    @objc func viewTapped() {
        idleCount = 0
        showCallMenu(state: true)
    }
    
    @objc func minimizedViewTapped() {
        let appDelegate = UIApplication.shared.delegate as! GlacierAppDelegate
        let screenSize = UIScreen.main.bounds
        appDelegate.callWindow?.backgroundColor = .clear
        appDelegate.callWindow?.frame = CGRect(x: 0, y: 0, width: screenSize.width, height: screenSize.height)
        minimizedView.isHidden = true
        mainView.isHidden = false
        bottomView.isHidden = false
        
        if appDelegate.isGroupChatController {
            appDelegate.chatRoomViewController.view.endEditing(true)
        } else {
            appDelegate.chatViewController.view.endEditing(true)
        }
        
        UIView.animate(withDuration: 0.5, delay: 0, options: [.curveEaseInOut], animations: {
            self.mainView.alpha = 1.0
        }, completion: nil)
        
        appDelegate.window?.frame = CGRect(x: 0, y: 0, width: screenSize.width, height: screenSize.height)
    }
    
    @objc func processCallTimer() {
        callTimeCount += 1
        if idleCount >= 0 { idleCount += 1 }
        
        if idleCount > 10 {
            idleCount = -1
            //showCallMenu(state: false)
        }
        
        if self.currentCall?.callstatus == .disconnected {
            //don't change progressLabel
        } else if callTimeCount < 3600 {
            let minutes = callTimeCount / 60
            let seconds = callTimeCount % 60
            progressLabel.text = String(format: "%02d:%02d", minutes, seconds)
        } else {
            let hours = callTimeCount / (60 * 60)
            let minutes = callTimeCount / 60
            let seconds = callTimeCount % 60
            progressLabel.text = String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        
        miniBarTitleLabel.text = "TAP TO RETURN TO CALL - \(progressLabel.text ?? "")"
    }
    
    @IBAction func muteAction(_ sender: UIButton) {
        if let call = self.currentCall, let client = call.webrtcClient, let uuid = call.callUuid {
            let muteThis = client.isAudioEnabled()
            DDLogDebug("muteAction \(muteThis)")
            self.callManager?.performMuteAction(uuid: uuid, isMuted: muteThis)
        }
        self.viewTapped()
    }
    
    public func muteAudio(_ shouldMute: Bool) {
        DDLogDebug("muteAudio \(shouldMute)")
        muteButton.isSelected = shouldMute
        if let call = self.currentCall {
            if shouldMute {
                call.webrtcClient?.muteAudio()
            } else {
                call.webrtcClient?.unmuteAudio()
            }
            mutedMark.isHidden = !shouldMute
            miniMuteLabel.isHidden = !shouldMute
        }
    }
    
    @IBAction func upgradeToVideoAction(_ sender: Any) {
        if let mgr = self.callManager, mgr.checkVideoPermissions() == true {
            self.handleVideoDenied()
            return
        }
        
        self.turnOnVideo()
        self.callManager?.sendVideoUpgradeOffer()
    }
    
    func addVideo() {
        guard let webClient = self.currentCall?.webrtcClient, let localVideo = self.localRenderer else { return }
        webClient.addVideo()
        webClient.startCaptureLocalVideo(renderer: localVideo, andCameraPosition: .front)
    }
    
    @IBAction func videoAction(_ sender: UIButton) {
        if let mgr = self.callManager, mgr.checkVideoPermissions() == true {
            handleVideoDenied()
            return
        }
        
        guard let localVideo = self.localRenderer, let webClient = self.currentCall?.webrtcClient else {
            // some kind of alert error
            return
        }
        
        sender.isSelected = !sender.isSelected
        
        //handle webrtc
        if sender.isSelected {
            //maybe check if we've already started, ie if
            //webClient.startCaptureLocalVideo(renderer: localVideo, andCameraPosition: .front)
            webClient.showVideo()
        } else {
            //webClient.stopCaptureLocalVideo()
            webClient.hideVideo()
        }
        
        localVideo.isHidden = !sender.isSelected
        if videoButton.isHidden {
            flipButton.isHidden = !sender.isSelected
            videoButton.isHidden = !sender.isSelected
        }
        
        //if goto video with bluetooth on, keep bluetooth on
        //if goto video with bluetooth off, turn on speaker
        //if off video with bluetooth on, keep bluetooth on
        //if off video with bluetooth off, turn off speaker
        
        //self.callManager?.performSpeakerAction(isSelected: sender.isSelected)
        //speakerButton.isSelected = sender.isSelected
        //note: if i put it on phone bluetooth shouldn't be available
        if !speakerButton.isSelected && callManager?.isBluetoothAvailable() ?? false {
            self.callManager?.performSpeakerAction(selection: SpeakerChoice.bluetooth)
            speakerButton.isSelected = false
        } else {
            self.callManager?.performSpeakerAction(isSelected: sender.isSelected)
            speakerButton.isSelected = sender.isSelected
        }
        self.viewTapped()
        //profileImageView.isHidden = sender.isSelected
    }
    
    public func setBluetoothEnabled(_ bluetoothEnabled: Bool) {
        DispatchQueue.main.async {
            var normalImage: UIImage?
            if (bluetoothEnabled) {
                normalImage = UIImage(named: "ic-bluetooth-on", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
                self.speakerButton.setImage(normalImage, for: .normal)
            }
        }
    }
    
    @IBAction func speakerAction(_ sender: UIButton) {
        // Triggering AVRoutePickerView button for presentation
        if let internalButton = routePickerView.subviews.compactMap({ $0 as? UIButton }).first {
            internalButton.sendActions(for: .touchUpInside)
        }
        self.viewTapped()
    }
    
    @IBAction func flipCameraAction(_ sender: UIButton) {
        self.currentCall?.webrtcClient?.switchCamera()
        self.viewTapped()
    }
    
    @IBAction func closeAction(_ sender: Any) {
        self.bottomView.isHidden = true
        let topSafeArea = view.safeAreaInsets.top
        let screenSize = UIScreen.main.bounds
        let appDelegate = UIApplication.shared.delegate as! GlacierAppDelegate
        appDelegate.callWindow?.frame = CGRect(x: 0, y: 0, width: screenSize.width, height: topSafeArea + 44)
        appDelegate.callWindow?.backgroundColor = .green
        
        UIView.animate(withDuration: 0.5, delay: 0, options: [.curveEaseInOut], animations: {
            self.mainView.alpha = 0
        }, completion: { _ in
            self.minimizedView.isHidden = false
            self.mainView.isHidden = true
        })
        
        let isiPhone = UIDevice.current.userInterfaceIdiom == .phone
        let phoneHeight:CGFloat = 20.0
        let safeHeight = (isiPhone ? phoneHeight : topSafeArea)
        
        appDelegate.window?.frame = CGRect(x: 0,
                                           y: safeHeight + 44.0,
                                           width: screenSize.width,
                                           height: screenSize.height - safeHeight - 44)
    }
    
    @IBAction func disconnectAction(_ sender: Any) {
        disconnectCall(true)
        if let ruuid = self.currentCall?.callUuid {
            self.callManager?.performEndCallAction(uuid:ruuid, userInitiated: true)
        }
    }

    func cleanupRemoteParticipants() {
        remoteParticipantsView.removeAllParticipants()
    }
    
    public func holdCall(_ onHold: Bool) {
        //localAudioTrack?.isEnabled = !onHold
        //localVideoTrack?.isEnabled = !onHold
    }
    
    public func disconnectCall(_ userInitiated: Bool) {
        DDLogDebug("disconnectCall")
        self.callManager?.performSpeakerAction(isSelected: false)  //selection: SpeakerChoice.bluetooth)
        
        if (userInitiated) {
            if let url = Bundle.main.url(forResource: "MarimbaBlink", withExtension: "wav") {
                self.callManager?.playSound(soundUrl: url)
            }
        }
        
        //self.room?.disconnect()
        //actually do what is required to end the call...which is?
        killCallTimer()
        DispatchQueue.main.async {
            self.dismiss(animated: true) {
                let appDelegate = UIApplication.shared.delegate as! GlacierAppDelegate
                appDelegate.callWindow?.rootViewController = nil
                appDelegate.callWindow?.frame = CGRect.zero
                appDelegate.callWindow?.resignKey()
                let screenSize = UIScreen.main.bounds
                appDelegate.window?.frame = CGRect(x: 0, y: 0, width: screenSize.width, height: screenSize.height)
                appDelegate.chatRoomViewController.enablePhoneButton(true)
                appDelegate.chatViewController.enablePhoneButton(true)
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
    
    public func turnOnVideo() {
        //DDLogInfo("***** turnOnVideo")
        if self.currentCall?.audioOnly == true {
            self.addVideo()
            //self.currentCall?.audioOnly = false
        }
        DispatchQueue.main.async {
            self.videoAction(self.videoButton)
        }
    }
    
    public func turnOffVideo() {
        DispatchQueue.main.async {
            self.videoAction(self.videoButton)
            self.remoteParticipantsView.participantsArray.first?.callCellDelegate?.hideAvatar(hide: false)
            self.flipButton.isHidden = true
            self.videoButton.isHidden = true
        }
        DDLogDebug("turnOffVideo")
        self.currentCall?.audioOnly = true
        self.currentCall?.webrtcClient?.removeVideoOffer()
    }
    
    public func setStatus(_ status: String) {
        if status.starts(with: "Reconnecting") {
            self.currentCall?.callstatus = .disconnected
        }
        DispatchQueue.main.async {
            self.progressLabel.text = status
        }
    }
}

extension VideoCallViewController : WebRTCConnectionDelegate {
    func webRTCCallConnected() {
        self.currentCall?.callstatus = .connected
        if self.remoteParticipantsView.participantsArray.count > 0 {
            guard let url = Bundle.main.url(forResource: "MarimbaDing", withExtension: "wav") else { return }
            self.callManager?.playSound(soundUrl: url)
            return
        }

        DispatchQueue.main.async {
            if let webClient = self.currentCall?.webrtcClient {
                if self.currentCall?.audioOnly == false {
                    if webClient.videoIsEnabled(), let localVideo = self.localRenderer {
                        if let mgr = self.callManager, mgr.checkVideoPermissions() == true {
                            self.handleVideoDenied()
                        } else {
                            webClient.startCaptureLocalVideo(renderer: localVideo, andCameraPosition: .front)
                        }
                    }
                    self.renderRemoteVideoIfReady()
                    //webClient.turnSpeakerOn()
                    //self.speakerButton.isSelected = true
                    //self.callManager?.performSpeakerAction(selection: SpeakerChoice.speaker)
                }  else if webClient.getSpeakerOn() {
                    //webClient.turnSpeakerOn()
                    //self.callManager?.performSpeakerAction(selection: SpeakerChoice.speaker)
                }
            }
            
            self.progressLabel.text = "00:00"
            self.miniBarTitleLabel.text = "TAP TO RETURN TO CALL - 00:00"
            
            self.callTimer = Timer.scheduledTimer(timeInterval: 1.0,
                                                  target: self,
                                                  selector: #selector(VideoCallViewController.processCallTimer),
                                                  userInfo: nil,
                                                  repeats: true)
            
            self.profileImageView.isHidden = true
            
            var caller = self.currentCall?.caller
            var budjid = caller ?? ""
            if let call = self.currentCall, call.isCaller == true {
                budjid = call.receiver!
            }
            
            let callbuddy = self.callManager?.getCallBuddy(budjid)
            var displayname = callbuddy?.displayName
            var avatar = callbuddy?.avatarImage
            
            if displayname == nil, let jid = XMPPJID(string: budjid) {
                displayname = jid.user
            }
            if avatar == nil {
                avatar = GlacierImages.avatarImage(withUsername: displayname)
            }
            
            var avimage = (self.currentCall?.audioOnly ?? true) ? avatar : nil
            
            //Only add if this is new
            self.addParticipantIfReady(name: displayname, image: avimage)
            guard let url = Bundle.main.url(forResource: "MarimbaDing", withExtension: "wav") else { return }
            self.callManager?.playSound(soundUrl: url)
        }
    }
    
    func webRTCCallDisconnected() {
        // DDLogInfo("***** webRTCCallDisconnected")
        self.cleanupRemoteParticipants()
        DispatchQueue.main.async {
            self.disconnectCall(true)
            //self.currentCall = nil
        }
    }
    
    func webRTCCallVideoAdded() {
        if let webClient = self.currentCall?.webrtcClient, self.remoteRenderer != nil, self.currentCall?.audioOnly == true {
            self.currentCall?.audioOnly = false
            webClient.renderRemoteVideo(to: self.remoteRenderer!)
            DispatchQueue.main.async {
                self.remoteParticipantsView.participantsArray.first?.callCellDelegate?.hideAvatar(hide: true)
            }
        }
    }
    
    func webRTCCallVideoRejected() {
        self.turnOffVideo()
    }
    
    func webRTCCallFailed() {
        self.webRTCCallDisconnected()
    }
    
    func webRTCCallClosed() {
        //
    }
    
    public func isConnected() -> Bool {
        return self.currentCall?.callstatus == .connected
    }
}

extension VideoCallViewController {
    private func renderRemoteVideoIfReady() {
        guard let webClient = self.currentCall?.webrtcClient else { return }
        guard let renderer = self.remoteRenderer else {
            self.pendingRemoteRender = true
            return
        }
        self.pendingRemoteRender = false
        webClient.renderRemoteVideo(to: renderer)
    }

    private func addParticipantIfReady(name: String?, image: UIImage?) {
        guard let renderer = self.remoteRenderer else {
            self.pendingParticipant = (name: name, image: image)
            return
        }
        self.pendingParticipant = nil
        self.remoteParticipantsView.addParticipant(videoView: renderer, name: name, image: image)
    }

    private func addPendingParticipantIfNeeded() {
        guard let pending = self.pendingParticipant else { return }
        addParticipantIfReady(name: pending.name, image: pending.image)
    }
}

extension VideoCallViewController: RTCVideoViewDelegate {
    public func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        //print("📐 Remote video resized: \(size)")
        self.currentCall?.webrtcClient?.showVideo()
    }
    
    func videoView(_ videoView: RTCVideoRenderer, didReceiveFirstFrameWith size: CGSize) {
        //print("🎥 peerConnection Remote video started. Frame size: \(size)")
        self.currentCall?.webrtcClient?.showVideo()
    }
}
