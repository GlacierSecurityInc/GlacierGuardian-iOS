//
//  VoiceCallViewController.swift
//  Glacier
//
//  Created by andyfriedman on 1/24/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import UIKit
import Foundation
import Font_Awesome_Swift
import CallKit
import TwilioVoice

@objc open class VoiceCallViewController: UIViewController, GlacierCallDelegateProtocol {
    
    @IBOutlet weak var mainView: UIView!
    @IBOutlet weak var minimizedView: UIView!
    
    @IBOutlet weak var miniMuteLabel: UILabel!
    @IBOutlet weak var miniBarTitleLabel: UILabel!
    
    @IBOutlet weak var profileImageView: UIImageView!
    
    @IBOutlet weak var signalStateLabel: UILabel!
    
    @IBOutlet weak var topView: UIView!
    @IBOutlet weak var closeButton: UIButton!
    @IBOutlet weak var nameLabel: UILabel!
    @IBOutlet weak var progressLabel: UILabel!
    
    @IBOutlet weak var buttonView: UIView!
    @IBOutlet weak var muteButton: UIButton!
    @IBOutlet weak var speakerButton: UIButton!
    
    @IBOutlet weak var dialerButton: UIButton!
    @IBOutlet weak var disconnectButton: UIButton!
    @IBOutlet weak var mutedMark: UIButton!
    
    @IBOutlet weak var bottomView: UIView! //IOSM-532
    
    var callManager: CallManager?
    
    //var connectCompletionHandler: ((Bool)->Swift.Void?)? = nil
    
    var incomingPushCompletionCallback: (() -> Void)?
    var callKitCompletionCallback: ((Bool) -> Void)? = nil
    //var activeCallInvites: [String: CallInvite]! = [:]
    var activeCalls: [String: Call]! = [:]
    let CALL_TO = "to"
    let CALL_FROM = "from"
        
    // activeCall represents the last connected call
    var activeCall: Call? = nil
    
    var callTimer: Timer?
    var callTimeCount = 0
    var idleCount = 0
    var ourCall: TwilioCall?
    var nameTitle: String?
    var avatar: UIImage?
    var bluetoothPossible:Bool = false
    var userDisconnecting = false
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self) 
    }
    
    @objc public func setCallManager(_ callManager: CallManager) {
        self.callManager = callManager
    }
    
    func setContact(_ contact: PhoneContact) {
        self.nameTitle = contact.name.capitalized
        
        if let av = contact.avatar {
            self.avatar = av
        }
    }
    
    override public func viewDidLoad() {
        super.viewDidLoad()
        
        let mainTapGesture = UITapGestureRecognizer(target: self, action: #selector(viewTapped))
        mainView.isUserInteractionEnabled = true
        mainView.addGestureRecognizer(mainTapGesture)
        
        let miniTapGesture = UITapGestureRecognizer(target: self, action: #selector(minimizedViewTapped))
        minimizedView.isUserInteractionEnabled = true
        minimizedView.addGestureRecognizer(miniTapGesture)
        
        UIApplication.shared.isIdleTimerDisabled = true //ALF IOSM-462, 471
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil) //IOSM-521
        
        setupViews()
    }
    
    //IOSM-521
    @objc private func becameActive() {
        UIApplication.shared.isIdleTimerDisabled = true
        if CallManager.sharedCallManager().isSpeakerMode() {
            self.speakerButton.isSelected = true
        }
    }
    
    //ALF IOSM-521
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    //ALF IOSM-521
    override public func viewWillDisappear(_ animated: Bool) {
        // Allow the device to sleep.
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        //profileImageView.layer.cornerRadius = profileImageView.frame.height / 2.0
        profileImageView.layer.cornerRadius = profileImageView.layer.bounds.width / 2
        profileImageView.clipsToBounds = true
        
        muteButton.layer.cornerRadius = muteButton.frame.height / 2
        muteButton.clipsToBounds = true
        speakerButton.layer.cornerRadius = speakerButton.frame.height / 2
        speakerButton.clipsToBounds = true
        disconnectButton.layer.cornerRadius = disconnectButton.frame.height / 2
        disconnectButton.clipsToBounds = true
        dialerButton.layer.cornerRadius = dialerButton.frame.height / 2
        dialerButton.clipsToBounds = true
        
        signalStateLabel.layer.cornerRadius = signalStateLabel.frame.height / 2
        signalStateLabel.clipsToBounds = true
        mutedMark.layer.cornerRadius = mutedMark.frame.height / 2
        mutedMark.clipsToBounds = true
        
        //remoteCollectionView.frame = view.bounds
    }
    
    // MARK: - UI
    
    private func setupViews() {
        
        //profileImageView.layer.cornerRadius = self.view.bounds.width / 2
        
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
        
        var normalImage: UIImage?
        var selectedImage: UIImage?
        
        normalImage = UIImage(named: "ic-mute-off", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        selectedImage = UIImage(named: "ic-mute-on", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        muteButton.setImage(normalImage, for: .normal)
        muteButton.setImage(selectedImage, for: .selected)
        
        normalImage = UIImage(named: "ic-speaker-off", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        selectedImage = UIImage(named: "ic-speaker-on", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        speakerButton.setImage(selectedImage, for: .selected)
        speakerButton.setImage(normalImage, for: .normal)
        // Allow changing audio routes while the call is connecting
        speakerButton.isEnabled = true
        
        //ALF IOSM-451 if bluetooth
        if callManager?.isBluetoothAvailable() ?? false {
            normalImage = UIImage(named: "ic-bluetooth-on", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
            speakerButton.setImage(normalImage, for: .normal)
        }
        
        if (nameTitle != nil) {
            nameLabel?.text = nameTitle
        }
        
        if let avatar = self.avatar {
            let imagesize = profileImageView.frame.size
            profileImageView.image = avatar.scalePreservingAspectRatio(targetSize: imagesize)
        }
        
        dialerButton.tintColor = .white
        
        disconnectButton.backgroundColor = .red
        disconnectButton.tintColor = .white
        let buttonConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .medium)
        let phoneDown = UIImage(systemName: "phone.down.fill", withConfiguration: buttonConfiguration)
        disconnectButton.setImage(phoneDown, for: UIControl.State())
        
    }
    
    //GlacierCallDelegateProtocol
    public func connectCall(_ call: TwilioCall) {
        self.ourCall = call
        self.speakerButton.isEnabled = true
    }
    

    
    //ALF IOSM-464 (next 3)
    public func handleAudioDenied() {
        handlePermissionDenied("Allow Audio", message: "Whoops! It looks like you have not permitted Glacier to access your Microphone. To use Glacier calling, please enable the Microphone in the Glacier settings on your device.", includeEnable: true)
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
        //
    }
    
    public func setConnectedCall(_ call: TwilioCall, activeCall: Call, with: String) {
        self.ourCall = call
        self.activeCall = activeCall
        nameLabel.text = with.capitalized//with.displayName.capitalized
        self.speakerButton.isEnabled = true
    }
    
    private func showCallMenu(state: Bool) {
        UIView.animate(withDuration: 0.4, animations: {
            self.topView.alpha = state ? 1.0 : 0
            self.buttonView.alpha = state ? 1.0 : 0
            //self.disconnectButton.alpha = state ? 1.0 : 0
        }, completion: { _ in
            self.topView.isHidden = !state
            self.buttonView.isHidden = !state
            //self.disconnectButton.isHidden = !state
            //self.signalStateLabel.isHidden = state
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
        let appDelegate = UIApplication.shared.delegate as! OTRAppDelegate
        let screenSize = UIScreen.main.bounds
        appDelegate.callWindow?.backgroundColor = .clear
        appDelegate.callWindow?.frame = CGRect(x: 0, y: 0, width: screenSize.width, height: screenSize.height)
        minimizedView.isHidden = true
        mainView.isHidden = false
        bottomView.isHidden = false //IOSM-532
        
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
            showCallMenu(state: false)
        }
        
        if callTimeCount < 3600 {
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
    
    
    @IBAction func dialerAction(_ sender: Any) {
        self.closeAction(self)
        if let appDelegate = Application.shared.delegate as? OTRAppDelegate {
            appDelegate.window?.rootViewController = appDelegate.dialerViewController
        }
    }
    
    @IBAction func muteAction(_ sender: UIButton) {
        guard let activeCall = getActiveCall(), let uuid = self.ourCall?.callUuid else {
            return
        }

        activeCall.isMuted = !activeCall.isMuted
        muteButton.isSelected = activeCall.isMuted
        
        self.callManager?.performMuteAction(uuid: uuid, isMuted: activeCall.isMuted)
        self.viewTapped() //IOSM-475
    }
    
    public func muteAudio(_ shouldMute: Bool) {
        muteButton.isSelected = shouldMute
        mutedMark.isHidden = !shouldMute
        miniMuteLabel.isHidden = !shouldMute
        
        if let activeCall = getActiveCall() {
            activeCall.isMuted = shouldMute
        }
    }
    
    func getActiveCall() -> Call? {
        if let activeCall = activeCall {
            return activeCall
        } else if activeCalls.count == 1 {
            // This is a scenario when the only remaining call is still on hold after the previous call has ended
            return activeCalls.first?.value
        } else {
            return nil
        }
    }
    
    //ALF IOSM-451
    public func setBluetoothEnabled(_ bluetoothEnabled: Bool) {
        DispatchQueue.main.async {
            var normalImage: UIImage?
            if (bluetoothEnabled) {
                normalImage = UIImage(named: "ic-bluetooth-on", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
                self.speakerButton.setImage(normalImage, for: .normal)
            } else {
                normalImage = UIImage(named: "ic-speaker-off", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
                self.speakerButton.setImage(normalImage, for: .normal)
            }
        }
    }
    
    @IBAction func speakerAction(_ sender: UIButton) {
        //sender.isSelected = !sender.isSelected
        //self.callManager?.performSpeakerAction(isSelected: sender.isSelected)
        
        if self.bluetoothPossible || callManager?.isBluetoothAvailable() ?? false {
            let actionsheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

            actionsheet.addAction(UIAlertAction(title: "Bluetooth", style: .default, handler: { (action) -> Void in
                sender.isSelected = false
                self.callManager?.performSpeakerAction(selection: SpeakerChoice.bluetooth)
            }))
            actionsheet.addAction(UIAlertAction(title: "Speaker", style: .default, handler: { (action) -> Void in
                sender.isSelected = true
                self.callManager?.performSpeakerAction(selection: SpeakerChoice.speaker)
            }))
            actionsheet.addAction(UIAlertAction(title: "Phone", style: .default, handler: { (action) -> Void in
                sender.isSelected = false
                self.callManager?.performSpeakerAction(selection: SpeakerChoice.receiver)
                self.bluetoothPossible = true
            }))
            actionsheet.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { (action) -> Void in
                //do nothing
            }))
            self.present(actionsheet, animated: true, completion: nil)
        } else {
            sender.isSelected = !sender.isSelected
            self.callManager?.performSpeakerAction(isSelected: sender.isSelected)
        }
        self.viewTapped() //IOSM-475
    }
    
    @IBAction func closeAction(_ sender: Any) {
        self.bottomView.isHidden = true //IOSM-532
        let topSafeArea = view.safeAreaInsets.top
        let screenSize = UIScreen.main.bounds
        let appDelegate = UIApplication.shared.delegate as! OTRAppDelegate
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
        let cuuid = self.activeCall?.uuid
        self.userDisconnecting = true
        
        //self.activeCall?.disconnect()
        
        // call doesn't exist yet if we haven't connected. What's the uuid then?
        if let uuid = cuuid {
            self.callManager?.performEndCallAction(uuid: uuid, userInitiated: true)
        } else {
            self.callManager?.performCancelCallAction(userInitiated: true)
        }
    }
    
    public func holdCall(_ onHold: Bool) {
        //localAudioTrack?.isEnabled = !onHold
    }
    
    public func disconnectCall(_ userInitiated: Bool) {
        //print("***** disconnectCall")
        self.callManager?.finalizeVoiceCall()
        killCallTimer()
        dismiss(animated: true) {
            let appDelegate = UIApplication.shared.delegate as! OTRAppDelegate
            appDelegate.callWindow?.rootViewController = nil
            appDelegate.callWindow?.frame = CGRect.zero
            appDelegate.callWindow?.resignKey()
            let screenSize = UIScreen.main.bounds
            appDelegate.window?.frame = CGRect(x: 0, y: 0, width: screenSize.width, height: screenSize.height)
            appDelegate.chatRoomViewController.enablePhoneButton(true)
            appDelegate.chatViewController.enablePhoneButton(true)
            UIApplication.shared.isIdleTimerDisabled = false //ALF IOSM-462, 471
        }
    }
    
    public func turnOnVideo() {
        //not used for VoiceCall but part of GlacierCallDelegateProtocol
    }
    
    public func isConnected() -> Bool {
        return false
    }
    
    public func setStatus(_ status: String) {
        DispatchQueue.main.async {
            self.progressLabel.text = status
        }
    }
}

// MARK: - TVOCallDelegate

extension VoiceCallViewController: CallDelegate {
    public func callDidStartRinging(call: Call) {
        DDLogInfo("callDidStartRinging:")
        /*if let curcall = CallManager.sharedCallManager().currentCall {
            let num = curcall.isCaller ? curcall.receiver : curcall.caller
            //print("***** callDidStartRinging about to getMAtchingContact for \(num ?? "")")
            if let num = num, let contact = TwilioBackendManager.sharedMgr().getMatchingContact(num) {
                //self.setNameTitle(contact.name)
                if let avatar = contact.avatar {
                    print("***** callDidStartRinging contact avatar \(avatar.size) with view size \(profileImageView.frame.size)")
                    profileImageView.image = avatar
                }
            }
        }*/
    }
    
    public func callDidConnect(call: Call) {
        //print("***** callDidConnect with \(call.uuid)")
        DDLogInfo("***** Call Connected to \(call.description) as \(call.from ?? "")")
        self.progressLabel.text = "00:00"
        self.miniBarTitleLabel.text = "TAP TO RETURN TO CALL - 00:00"
        
        self.callTimer = Timer.scheduledTimer(timeInterval: 1.0,
                                              target: self,
                                              selector: #selector(VoiceCallViewController.processCallTimer),
                                              userInfo: nil,
                                              repeats: true)
        
        //if let caller = self.ourCall?.caller {
            //avatar = OTRImages.avatarImage(withUsername: displayname)
        //}
        
        self.ourCall?.answerCallAction?.fulfill(withDateConnected: Date())
    }

    public func callIsReconnecting(call: Call, error: Error) {
        DDLogInfo("call:isReconnectingWithError:")
    }
    
    public func callDidReconnect(call: Call) {
        DDLogInfo("callDidReconnect:")
    }
    
    public func callDidFailToConnect(call: Call, error: Error) {
        DDLogInfo("Call failed to connect: \(error.localizedDescription)")
        self.callKitCompletionCallback?(false)
        
        if let uuid = call.uuid {
            //self.callManager?.reportCallDisconnected(uuid: uuid, error: error)
            
            if self.userDisconnecting == false {
                self.callManager?.performEndCallAction(uuid: uuid, userInitiated: false)
            }
        }

        self.activeCall = nil
        
        if self.userDisconnecting {
            self.disconnectCall(false)
        }
    }
    
    public func callDidDisconnect(call: Call, error: Error?) {
        if let error = error {
            DDLogInfo("Call failed: \(error.localizedDescription)")
        } else {
            DDLogInfo("Call disconnected")
        }
        
        //print("***** callDidDisconnect")
        
        if let uuid = call.uuid {
            //self.callManager?.reportCallDisconnected(uuid: uuid, error: error)
            
            if self.userDisconnecting == false {
                self.callManager?.performEndCallAction(uuid: uuid, userInitiated: false)
            } else {
                self.disconnectCall(false)
                //self.callManager?.reportCallDisconnected(uuid: uuid, error: error)
            }
        }
        
        //remove the avatar from view
        self.activeCall = nil
    }
    
    public func callDidReceiveQualityWarnings(call: Call, currentWarnings: Set<NSNumber>, previousWarnings: Set<NSNumber>) {
        /**
        * currentWarnings: existing quality warnings that have not been cleared yet
        * previousWarnings: last set of warnings prior to receiving this callback
        *
        * Example:
        *   - currentWarnings: { A, B }
        *   - previousWarnings: { B, C }
        *   - intersection: { B }
        *
        * Newly raised warnings = currentWarnings - intersection = { A }
        * Newly cleared warnings = previousWarnings - intersection = { C }
        */
        var warningsIntersection: Set<NSNumber> = currentWarnings
        warningsIntersection = warningsIntersection.intersection(previousWarnings)
        
        var newWarnings: Set<NSNumber> = currentWarnings
        newWarnings.subtract(warningsIntersection)
        if newWarnings.count > 0 {
            qualityWarningsUpdatePopup(newWarnings, isCleared: false)
        }
        
        var clearedWarnings: Set<NSNumber> = previousWarnings
        clearedWarnings.subtract(warningsIntersection)
        if clearedWarnings.count > 0 {
            qualityWarningsUpdatePopup(clearedWarnings, isCleared: true)
        }
    }
    
    func qualityWarningsUpdatePopup(_ warnings: Set<NSNumber>, isCleared: Bool) {
        var popupMessage: String = "Warnings detected: "
        if isCleared {
            popupMessage = "Warnings cleared: "
        }
        
        let mappedWarnings: [String] = warnings.map { number in warningString(Call.QualityWarning(rawValue: number.uintValue)!)}
        popupMessage += mappedWarnings.joined(separator: ", ")
        
        /*qualityWarningsToaster.alpha = 0.0
        qualityWarningsToaster.text = popupMessage
        UIView.animate(withDuration: 1.0, animations: {
            self.qualityWarningsToaster.isHidden = false
            self.qualityWarningsToaster.alpha = 1.0
        }) { [weak self] finish in
            guard let strongSelf = self else { return }
            let deadlineTime = DispatchTime.now() + .seconds(5)
            DispatchQueue.main.asyncAfter(deadline: deadlineTime, execute: {
                UIView.animate(withDuration: 1.0, animations: {
                    strongSelf.qualityWarningsToaster.alpha = 0.0
                }) { (finished) in
                    strongSelf.qualityWarningsToaster.isHidden = true
                }
            })
        }*/
    }
    
    func warningString(_ warning: Call.QualityWarning) -> String {
        switch warning {
        case .highRtt: return "high-rtt"
        case .highJitter: return "high-jitter"
        case .highPacketsLostFraction: return "high-packets-lost-fraction"
        case .lowMos: return "low-mos"
        case .constantAudioInputLevel: return "constant-audio-input-level"
        default: return "Unknown warning"
        }
    }
}
