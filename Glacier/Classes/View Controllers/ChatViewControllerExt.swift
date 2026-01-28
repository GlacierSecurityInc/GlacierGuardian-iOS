//
//  ChatViewControllerExt.swift
//  Glacier
//
//  Created by andyfriedman on 11/6/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import PureLayout
import AVFoundation
import MessageKit
import MapKit

@objc open class ChatViewControllerExt: ChatViewController, OTRHoldToTalkViewStateDelegate, OTRAudioSessionManagerDelegate, UIPickerViewDataSource,UIPickerViewDelegate {
    
    static let kOTRMessagesMinimumAudioTime = 0.5
    
    var hold2TalkButton:OTRHoldToTalkView?
    var trashView:OTRAudioTrashView?
    var trashViewWidthConstraint:NSLayoutConstraint?
    var keyboardButton = UIButton(type: .roundedRect)
    var holdTalkAddedConstraints = false
    let audioSessionManager = OTRAudioSessionManager()
    var recordingBackgroundView:UIView?

    // location sharing
    private let locationManager = CLLocationManager()
    var locbar:UIToolbar?
    var mapView:MKMapView? //MapView?
    var btnMapShare:UIBarButtonItem?
    var lastLoc:CLLocationCoordinate2D?
    var awaitingLocationPermission = false
    let annotation = MKPointAnnotation()
    //var pointAnnotationManager:PointAnnotationManager?
    //let puck = Puck2DConfiguration.makeDefault()
    //private var locationTrackingCancellation: AnyCancelable?
    //let locationProvider = AppleLocationProvider()
    
    // expiring messages
    var timePickerView:UIPickerView?
    let pickerArray = ["Off", "15 seconds", "1 minute", "5 minutes", "1 day", "1 week", "4 weeks"]
    var timePickerTextField:UITextField?
    var timeTapGesture:UITapGestureRecognizer?
    var timeTapGesture2:UITapGestureRecognizer?
    var timeOn = false
    
    private var inputText: String?
    
    override public init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        self.audioSessionManager.delegate = self
        self.keyboardButton.frame = CGRectMake(0, 0, 22, 32)
        self.keyboardButton.titleLabel?.font = UIFont(name: kFontAwesomeFont, size: 20.0)
        self.keyboardButton.titleLabel?.textAlignment = NSTextAlignment.center
        let keyboardIcon: UniChar = 0xf11c
        self.keyboardButton.setTitle(String(format: "%C", keyboardIcon), for: .normal)
        self.keyboardButton.tintColor = UIColor.bubbleBlue()
        
        self.microphoneButton.addTarget(self, action: #selector(microphoneButtonTouched), for: UIControl.Event.touchUpInside)
        self.hourglassButton.addTarget(self, action: #selector(hourglassButtonTouched), for: UIControl.Event.touchUpInside)
        
        // share location
        //self.locReady = false;
        self.btnMapShare = UIBarButtonItem(title: "Locating...", style: .plain, target: self, action: #selector(shareLocation))
        self.lastLoc = kCLLocationCoordinate2DInvalid
        self.initMapStuff()
        
        NotificationCenter.default.addObserver(self, selector: #selector(enteringForeground), name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
        
        NotificationCenter.default.addObserver(self, selector: #selector(resigningActive), name: UIApplication.willResignActiveNotification, object: UIApplication.shared)
        
        self.view.setNeedsUpdateConstraints()
        self.updateTimeButton()
    }
    
    private func initMapStuff() {
        self.mapView = MKMapView(frame: self.view.bounds)
        self.mapView?.overrideUserInterfaceStyle = .dark
        self.mapView?.delegate = self
        //LocationManager.shared().addLocationDelegate(self)
        self.mapView?.userTrackingMode = .follow
        self.mapView?.showsUserLocation = true
        self.locationManager.delegate = self
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        //LocationManager.shared().removeLocationDelegate(self)
    }

    open override func viewWillAppear(_ animated:Bool) {
        super.viewWillAppear(animated)
        self.turnOnOffLocation(true)
    }

    open override func viewWillDisappear(_ animated:Bool) {
        super.viewWillDisappear(animated)
        self.turnOnOffLocation(false)
    }

    // whether to track location. only tracks location when actively on conversation
    func turnOnOffLocation(_ locationOn:Bool) {
        if (locationOn) {
            let authStatus = self.locationManager.authorizationStatus
            if (authStatus == .authorizedAlways || authStatus == .authorizedWhenInUse) {
                self.locationManager.startUpdatingLocation()
                if let loc = self.lastLoc, CLLocationCoordinate2DIsValid(loc) {
                    self.mapView?.camera.centerCoordinate = loc
                }
            }
        } else {
            self.locationManager.stopUpdatingLocation()
            //LocationManager.shared().toggleLocationUpdates(false)
            if self.locbar != nil {
                self.cancelLocation()
            }
            //print("***** Turned OFF location I think")
        }
    }

    @objc func enteringForeground(_ notification:NSNotification) {
        if self.isViewLoaded && self.view.window != nil {
            self.turnOnOffLocation(true)
        }
    }

    @objc func resigningActive(_ notification:NSNotification) {
        if self.isViewLoaded && self.view.window != nil {
            self.turnOnOffLocation(false)
        }
    }

    // MARK: AutoLayout

    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let tview = self.trashView {
            tview.trashButton.buttonCornerRadius = CGRectGetWidth(tview.trashButton.bounds) as NSNumber
        }
    }

    // MARK: Utilities

    func distanceBetween(point1:CGPoint, point2:CGPoint) -> CGFloat
    {
        return sqrt(pow(point2.x-point1.x,2)+pow(point2.y-point1.y,2))
    }

    func centerOfView(_ view1:UIView, in view2:UIView) -> CGPoint
    {
        let localCenter = CGPointMake(CGRectGetMidX(view1.bounds), CGRectGetMidY(view1.bounds))
        let trashButtonCenter = view2.convert(localCenter, from: view1)
        return trashButtonCenter
    }

    // MARK: Setup Recording

    func addPush2TalkButton() {
        self.removePush2TalkButton()
        self.hold2TalkButton = OTRHoldToTalkView(forAutoLayout: ())
        self.setHold2TalkStatusWaiting()
        self.hold2TalkButton?.delegate = self
        
        let textView = self.messageInputBar.inputTextView
        textView.addSubview(self.hold2TalkButton!)
        
        if let holdBtn = self.hold2TalkButton {
            let offset = 1.0
            holdBtn.autoPinEdgesToSuperviewEdges()
            //holdBtn.autoPinEdge(.leading, to:.leading, of:textView, withOffset:0)
            //holdBtn.autoPinEdge(.trailing, to:.trailing, of:textView, withOffset:0)
            //holdBtn.autoPinEdge(.top, to:.top, of:textView, withOffset:0)
            //holdBtn.autoPinEdge(.bottom, to:.bottom, of:textView, withOffset:0)
            let tvwidth = textView.widthAnchor
            holdBtn.widthAnchor.constraint(equalTo: tvwidth).isActive = true
        }
        
        self.view.setNeedsUpdateConstraints()
    }

    func setHold2TalkStatusWaiting() {
        self.hold2TalkButton?.textLabel.text = HOLD_TO_TALK_STRING()
        self.hold2TalkButton?.textLabel.textColor = .white
        self.hold2TalkButton?.backgroundColor = .darkGray
    }

    func setHold2TalkButtonRecording() {
        self.hold2TalkButton?.textLabel.text = RELEASE_TO_SEND_STRING()
        self.hold2TalkButton?.textLabel.textColor = .darkGray
        self.hold2TalkButton?.backgroundColor = .white
    }

    func addTrashViewItems() {
        self.removeTrashViewItems()
        self.trashView = OTRAudioTrashView(forAutoLayout: ())
        if let tview = self.trashView {
            self.view.addSubview(tview)
            
            tview.autoAlignAxis(.horizontal, toSameAxisOf:self.view, withOffset:50)
            tview.autoAlignAxis(toSuperviewAxis: .vertical)
            self.trashViewWidthConstraint = tview.autoSetDimension(.height, toSize:tview.intrinsicContentSize.height)
            tview.trashIconLabel.alpha = 0
            tview.microphoneIconLabel.alpha = 1
            tview.trashButton.isHighlighted = false
            tview.trashLabel.textColor = .white
        }
    }

    func addRecordingBackgroundView() {
        self.removeRecordingBackgroundView()
        self.recordingBackgroundView = UIView(forAutoLayout: ())
        self.recordingBackgroundView?.backgroundColor = .gray
        self.recordingBackgroundView?.alpha = 0.7
        self.view.insertSubview(self.recordingBackgroundView!, belowSubview:self.hold2TalkButton!)
        self.recordingBackgroundView?.autoPinEdgesToSuperviewEdges(with: .zero)
    }

    func removeRecordingBackgroundView() {
        self.recordingBackgroundView?.removeFromSuperview()
        self.recordingBackgroundView = nil
    }

    func removePush2TalkButton() {
        self.hold2TalkButton?.removeFromSuperview()
        self.hold2TalkButton = nil
        
        do {
            try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playback)
        } catch {
            DDLogError("ChatViewControllerExt.removePush2TalkButton error setting category")
        }
    }

    func removeTrashViewItems() {
        self.trashView?.removeFromSuperview()
        self.trashView = nil
    }


    override func updateExpiresState() { //IOSM#6
        self.updateTimeButton()
    }

    func removeMediaButtons() {
        self.removePush2TalkButton()
        self.removeRecordingBackgroundView()
        self.removeTrashViewItems()
        //self.messageInputBar.contentView.leftBarButtonItem = nil
    }

    // MARK: OTRHoldToTalkViewStateDelegate

    public func didBeginTouch(_ view:OTRHoldToTalkView) {
        //start Recording
        AVAudioSession.sharedInstance().requestRecordPermission() { [unowned self] allowed in
            DispatchQueue.main.async {
                if view.isInTouch() == false {
                    // Abort this, no longer in touch
                } else if (allowed) {
                    self.addRecordingBackgroundView()
                    self.addTrashViewItems()
                    let temporaryUrl = URL(fileURLWithPath: NSTemporaryDirectory())
                    let fileName = UUID().uuidString + ".m4a"
                    let url = temporaryUrl.appendingPathComponent(fileName)
                    self.audioSessionManager.recordAudio(to: url, error: nil)
                    self.setHold2TalkButtonRecording()
                } else {
                    let alert = UIAlertController(title: Microphone_Disabled(), message: Microphone_Reenable_Please(), preferredStyle: .alert)
                    let fix = UIAlertAction(title: "Enable", style: .default, handler: { action in
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    })
                    let cancel = UIAlertAction(title: CANCEL_STRING(), style: .cancel)
                    alert.addAction(fix)
                    alert.addAction(cancel)
                    self.present(alert, animated: true, completion: nil)
                }
            }
        }
        
    }

    public func view(_ view:OTRHoldToTalkView, touchDidMoveToPointInWindow point:CGPoint) {
        let mainWindow = UIApplication.shared.keyWindow
        let pointInView = self.view.convert(point, from: mainWindow)
        
        if let tview = self.trashView, let trashBtn = tview.trashButton, let holdBtn = self.hold2TalkButton {
            
            let trashButtonCenter = self.centerOfView(trashBtn, in: self.view)
            let holdToTalkCenter = self.centerOfView(holdBtn, in:self.view)
            
            let normalDistance = self.distanceBetween(point1: trashButtonCenter, point2:holdToTalkCenter)
            let distance = self.distanceBetween(point1:pointInView, point2:trashButtonCenter)
            
            let percentDistance = (normalDistance - distance)/normalDistance
            let defaultHeight = tview.intrinsicContentSize.height
            self.trashViewWidthConstraint?.constant = max(defaultHeight, defaultHeight+defaultHeight * percentDistance)
        
            let testPoint = tview.trashButton.convert(pointInView, from: self.view)
            let insideButton = CGRectContainsPoint(tview.trashButton.bounds, testPoint)
            
            tview.trashButton.isHighlighted = insideButton
            
            if insideButton == true {
                tview.trashIconLabel.alpha = 1;
                tview.microphoneIconLabel.alpha = 0;
                self.hold2TalkButton?.textLabel.text = RELEASE_TO_DELETE_STRING()
            } else {
                tview.trashIconLabel.alpha = percentDistance
                tview.microphoneIconLabel.alpha = 1-percentDistance
                self.hold2TalkButton?.textLabel.text = RELEASE_TO_SEND_STRING()
            }
        }
        
        self.view.setNeedsUpdateConstraints()
    }

    public func didReleaseTouch(_ view:OTRHoldToTalkView) {
        //stop recording and send
        let currentURL = self.audioSessionManager.currentRecorderURL()
        self.audioSessionManager.stopRecording()
        
        if let cururl = currentURL {
            let audioAsset = AVURLAsset(url: cururl)
            let duration = CMTimeGetSeconds(audioAsset.duration)
            // Delete recording if the button trash button is slelected or the audio is less than the minimum time.
            // This prevents taps on the record button from sending audio with extremely little length
            if (self.trashView?.trashButton.isHighlighted == true || duration < ChatViewControllerExt.kOTRMessagesMinimumAudioTime) {
                if let urlpath = currentURL?.path, FileManager.default.fileExists(atPath: urlpath) {
                    do {
                        try FileManager.default.removeItem(atPath: urlpath)
                    } catch {
                        //
                    }
                }
            } else {
                self.sendAudioFileURL(cururl)
            }
        }
        
        self.removeTrashViewItems()
        self.setHold2TalkStatusWaiting()
        self.removeRecordingBackgroundView()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.removePush2TalkButton()
            self.resetSendButton()
        }
    }
    
    private func resetSendButton() {
        messageInputBar.sendButton.image = nil
        messageInputBar.sendButton.title = "Send"
        
        guard let text = inputText, !text.isEmpty else {
            messageInputBar.inputTextView.placeholder = "Send encrypted message"
            messageInputBar.sendButton.isEnabled = false
            return
        }
        messageInputBar.inputTextView.text = text
        messageInputBar.sendButton.isEnabled = true
    }

    public func touchCancelled(_ view:OTRHoldToTalkView) {
        //stop recording and delete
        let currentURL = self.audioSessionManager.currentRecorderURL()
        self.audioSessionManager.stopRecording()
        if let urlpath = currentURL?.path, FileManager.default.fileExists(atPath: urlpath) {
            do {
                try FileManager.default.removeItem(atPath: urlpath)
            } catch {
                //
            }
        }
        self.removeTrashViewItems()
        self.setHold2TalkStatusWaiting()
        self.removeRecordingBackgroundView()
    }

    // MARK: AudioSessionDelegate
    //not sure this does anything useful, deprecated

    public func audioSession(_ audioSessionManager: OTRAudioSessionManager, didUpdateRecordingDecibel decibel:Double) {
        var scale = 0.0
        //Values for human speech range quiet to loud
        let mindB = -80.0
        let maxdB = -10.0
        if (decibel >= maxdB) {
            //too loud
            scale = 1.0
        } else if (decibel >= mindB && decibel <= maxdB) {
            //normal voice
            let powerFactor = 20.0
            let mindBScale = pow(10.0, mindB / powerFactor)
            let maxdBScale = pow(10.0, maxdB / powerFactor)
            let linearScale = pow (10.0, decibel / powerFactor)
            let scaleMin = 0.0
            let scaleMax = 1.0
            //Get a value between 0 and 1 for mindB & maxdB values
            scale = ( ((scaleMax - scaleMin) * (linearScale - mindBScale)) / (maxdBScale - mindBScale)) + scaleMin;
        }
        
        self.trashView?.setAnimationChange(30.0 * scale)
    }

    func needsLocationPermission() -> Bool {
        var needsPermission = false
        if CLLocationManager.locationServicesEnabled() {
            switch (self.locationManager.authorizationStatus) {
            case .notDetermined:
                needsPermission = true
                DispatchQueue.main.async {
                    self.locationManager.requestWhenInUseAuthorization()
                }
                break
            case .restricted, .denied:
                needsPermission = true
                DispatchQueue.main.async {
                    self.handleLocationAuthorizationDenied()
                }
                break
            default:
                needsPermission = false
                break
            }
        } else {
            needsPermission = true
        }
        
        return needsPermission
    }

    func handleLocationAuthorizationDenied() {
        let alert = UIAlertController(title: "Allow Location Access", message: "Whoops! It looks like you have not permitted Glacier to access your Location. To use this feature, please turn on Location Services while using the app in your device Glacier settings.", preferredStyle: .alert)
        let fix = UIAlertAction(title: "Enable", style: .default, handler: { action in
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        })
        let cancel = UIAlertAction(title: CANCEL_STRING(), style: .cancel)
        alert.addAction(fix)
        alert.addAction(cancel)
        self.present(alert, animated: true, completion: nil)
    }

    //IOSM-464

    // MARK: Share Location
    func attachmentPicker(_ attachmentPicker:OTRAttachmentPicker, shareLocationButtonPressed locationURL:URL)
    {
        self.dsQueue.async {
            //if self.locationTrackingCancellation == nil {
                self.turnOnOffLocation(true)
            //}
            
            if self.needsLocationPermission() {
                self.awaitingLocationPermission = true //IOSM#26
                return
            }
            
            DispatchQueue.main.async {
                self.doShareLocation() //IOSM#26
            }
        }
    }

    func doShareLocation() { //IOSM#26
        guard let mapView = self.mapView else { return }
        self.view.endEditing(true)
        self.addLocationViewBtns(true)
        guard let locbar = self.locbar else { return }
        mapView.userTrackingMode = .follow
        
        mapView.removeAnnotation(annotation)
        if let userLocation = mapView.view(for: mapView.userLocation) {
            userLocation.isHidden = false
        }
        //mapView.camera.centerCoordinateDistance = 3000
        
        self.view.insertSubview(mapView, belowSubview:locbar)
        mapView.autoPinEdgesToSuperviewEdges(with: .zero)
        
        if let latestLoc = self.lastLoc {//self.mapView?.location.latestLocation {
            self.btnMapShare?.title = "Share Location"
            
            //let coordinate = CLLocationCoordinate2DMake(latestLoc.latitude, latestLoc.longitude)
            //mapView.removeAnnotation(annotation)
            //annotation.coordinate = coordinate
            //mapView.addAnnotation(annotation)
            
        }
    }

    func addLocationViewBtns(_ shareable:Bool) {
        self.locbar = UIToolbar.init(forAutoLayout: ())
        guard let locbar = self.locbar else {return}
        //locbar.sizeToFit()
        var barItems:[UIBarButtonItem] = []
        
        let btnCancel = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancelLocation))
        if (!shareable) {
            btnCancel.title = "Close"
        }
        barItems.append(btnCancel)
        
        let btnFlex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        barItems.append(btnFlex)
        
        if shareable, let mapShare = self.btnMapShare {
            barItems.append(mapShare)
        }
        
        locbar.setItems(barItems, animated: true)
        
        let lblColor = UIColor.label
        locbar.barTintColor = GlobalTheme.shared.lightThemeColor
        locbar.tintColor = lblColor
        locbar.isTranslucent = false
        
        self.view.addSubview(locbar)
        self.removeMediaButtons()
        
        let inputView = self.messageInputBar.inputTextView
        locbar.autoPinEdge(.leading, to:.leading, of:self.view, withOffset:0)
        locbar.autoPinEdge(.trailing, to:.trailing, of:self.view, withOffset:0)
        locbar.autoPinEdge(.top, to:.top, of:inputView, withOffset:0)
        locbar.autoPinEdge(.bottom, to:.bottom, of:inputView, withOffset:0)
        let ivwidth = self.view.bounds.width
        locbar.widthAnchor.constraint(equalToConstant: ivwidth).isActive = true
        self.locbar = locbar
        
        self.view.setNeedsUpdateConstraints()
    }

    @objc func cancelLocation() {
        self.mapView?.userTrackingMode = .none
        //mapView?.removeAnnotation(annotation)
        
        self.awaitingLocationPermission = false
        self.locbar?.removeFromSuperview()
        self.locbar = nil
        self.mapView?.removeFromSuperview()
    }

    @objc func shareLocation() {
        if let lat = self.lastLoc?.latitude, let lon = self.lastLoc?.longitude {
            let userLocString = "geo:".appendingFormat("%f,%f", lat, lon)
            
            self.cancelLocation()
            self.messageInputBar.inputTextView.text = userLocString
            self.messageInputBar.didSelectSendButton()
        }
    }


    override func findBuddyLocation(_ buddyloc:String, with message:ChatMessage) {
        let buddycomponents = buddyloc.replacingOccurrences(of: "geo:", with: "")
        let loccomponents = buddycomponents.components(separatedBy: ",")
        if loccomponents.count != 2 {
            return
        }
        
        guard let latd = Double(loccomponents.first!),
            let lond = Double(loccomponents.last!) else
            { return }
        
        self.view.endEditing(true)
        self.addLocationViewBtns(false)
        guard let locbar = self.locbar, let mapView = self.mapView else { return }
        
        if let userLocation = mapView.view(for: mapView.userLocation) {
            userLocation.isHidden = true
        }
        
        self.view.insertSubview(mapView, belowSubview:locbar)
        mapView.autoPinEdgesToSuperviewEdges(with: .zero)
        mapView.userTrackingMode = .none
        
        let coordinate = CLLocationCoordinate2DMake(latd, lond)
        //mapView.setCenter(coordinate, animated: true)
        
        mapView.removeAnnotation(annotation)
        
        //var annotation = PointAnnotation(coordinate: coordinate)
        annotation.coordinate = coordinate
        
        var text = self.getThreadName()
        if message.type == ChatMessageType.outgoing.rawValue {
            text = self.sender.displayName
        }
        
        if let tname = text {
            annotation.title = tname
        }

        mapView.addAnnotation(annotation)
        //self.mapView?.camera.centerCoordinate = coordinate
        var region = MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
        self.mapView?.region = region
        
        //let camera = MKMapCamera(lookingAtCenter: coordinate, fromDistance: 1000, pitch: 0, heading: 0)
        //mapView.setCamera(camera, animated: true)
    }
    //END share location functions

    @objc func microphoneButtonTouched(_ sender:Any) {
        self.view.endEditing(true)
        
        inputText = messageInputBar.inputTextView.text
        messageInputBar.inputTextView.text = nil
        
        let keyboardImg = UIImage(systemName: "keyboard")?.withRenderingMode(.alwaysTemplate)
        messageInputBar.sendButton.image = keyboardImg// setImage(keyboardImg, for: .normal)
        messageInputBar.sendButton.title = nil// setTitle(nil, for: .normal)
        messageInputBar.sendButton.tintColor = UIColor.bubbleBlue()
        messageInputBar.sendButton.isEnabled = true
        self.addPush2TalkButton()
        //self.inputToolbar.contentView.setNeedsUpdateConstraints()
    }

    // expiring message related functions here to end
    @objc func hourglassButtonTouched(sender: Any?) {
        self.timePickerView = UIPickerView()
        self.timePickerView?.dataSource = self
        self.timePickerView?.delegate = self
        self.timePickerView?.backgroundColor = UIColor(red: 41/255.0, green: 54/255.0, blue: 62/255.0, alpha: 1.0)
        
        self.timeTapGesture = UITapGestureRecognizer(target: self, action: #selector(self.clearTimePicker))
        self.timeTapGesture?.delegate = self
        self.timeTapGesture?.cancelsTouchesInView = false
        self.view.addGestureRecognizer(self.timeTapGesture!)
        
        self.timeTapGesture2 = UITapGestureRecognizer(target: self, action: #selector(self.clearTimePicker))
        self.timeTapGesture2?.delegate = self
        self.timeTapGesture2?.cancelsTouchesInView = false
        self.timePickerView?.addGestureRecognizer(self.timeTapGesture2!)
        
        let strHeader = "Set a time for the message to disappear"
        let lblWidth = self.view.frame.size.width
        if let lblXposition = self.timePickerView?.frame.origin.x, let lblYposition = self.timePickerView?.frame.origin.y {
            let lblHeader = UILabel(frame: CGRectMake(lblXposition, lblYposition, lblWidth, 20))
            lblHeader.text = strHeader
            lblHeader.textAlignment = NSTextAlignment.center
            lblHeader.textColor = UIColor.white
            lblHeader.font = UIFont(name: kFontAwesomeFont, size: 10.0)
            self.timePickerView?.addSubview(lblHeader)
        }
        
        //self.inputToolbar.contentView.rightBarButtonItem = self.sendButton
        
        self.timePickerTextField = UITextField(frame: CGRectZero)
        self.view.addSubview(self.timePickerTextField!)
        self.timePickerTextField?.inputView = self.timePickerView
        self.timePickerTextField?.becomeFirstResponder()
        
        let selrow = self.currentTimeSelectedRow()
        self.timePickerView?.selectRow(selrow, inComponent: 0, animated: true)
    }

    func currentTimeSelectedRow() -> Int {
        if let thread = self.getBuddy(), let etime = thread.expiresIn {
            self.timeOn = true
            if etime  == "2419200" { //IOSM#6
                return 6
            } else if etime == "604800" {
                return 5
            } else if etime == "86400" {
                return 4
            } else if etime == "300" {
                return 3
            } else if etime == "60" {
                return 2
            } else if etime == "15" {
                return 1
            }
        }
        self.timeOn = false
        return 0
    }

    override func setThreadKey(_ key: String?) {
        super.setThreadKey(key)
        self.updateTimeButton()
    }

    // called when initializing view or reentering view (viewWillAppear)
    func updateTimeButton() {
        
        switch self.currentTimeSelectedRow()
        {
            case 1:
                messageInputBar.sendButton.setImage(UIImage(named: "timer_15s_blue", in: GlacierInfo.resourcesBundle, with: nil), for: .normal)
                break
            case 2:
                messageInputBar.sendButton.setImage(UIImage(named: "timer_1m_blue", in: GlacierInfo.resourcesBundle, with: nil), for: .normal)
                break
            case 3:
                messageInputBar.sendButton.setImage(UIImage(named: "timer_5m_blue", in: GlacierInfo.resourcesBundle, with: nil), for: .normal)
                break
            case 4:
                messageInputBar.sendButton.setImage(UIImage(named: "timer_1d_blue", in: GlacierInfo.resourcesBundle, with: nil), for: .normal)
                break
            case 5:
                messageInputBar.sendButton.setImage(UIImage(named: "timer_1w_blue", in: GlacierInfo.resourcesBundle, with: nil), for: .normal)
                break
            case 6: //IOSM#6
                messageInputBar.sendButton.setImage(UIImage(named: "timer_4w_blue", in: GlacierInfo.resourcesBundle, with: nil), for: .normal)
                break
            default:
                messageInputBar.sendButton.image = nil
                break
        }
    }

    // MARK: UIPickerViewDelegate
    public func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }


    public func pickerView(_ pickerView:UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return self.pickerArray.count
    }

    public func pickerView(_ pickerView: UIPickerView, attributedTitleForRow row: Int, forComponent component: Int) -> NSAttributedString? {
        let title = self.pickerArray[row]
        let attString = NSAttributedString(string: title, attributes: [NSAttributedString.Key.foregroundColor: UIColor.white])
        
        return attString;
    }


    public func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        return self.pickerArray[row]
    }


    public func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        guard var thread = self.getBuddy() else { return }
        
        self.timeOn = true
        switch row {
            case 1:
                messageInputBar.sendButton.setImage(UIImage(named: "timer_15s_blue", in: GlacierInfo.resourcesBundle, with: nil), for: .normal)
                thread.expiresIn = "15"
                break
            case 2:
                messageInputBar.sendButton.setImage(UIImage(named: "timer_1m_blue", in: GlacierInfo.resourcesBundle, with: nil), for: .normal)
                thread.expiresIn = "60"
                break
            case 3:
                messageInputBar.sendButton.setImage(UIImage(named: "timer_5m_blue", in: GlacierInfo.resourcesBundle, with: nil), for: .normal)
                thread.expiresIn = "300"
                break
            case 4:
                messageInputBar.sendButton.setImage(UIImage(named: "timer_1d_blue", in: GlacierInfo.resourcesBundle, with: nil), for: .normal)
                thread.expiresIn = "86400"
                break
            case 5:
                messageInputBar.sendButton.setImage(UIImage(named: "timer_1w_blue", in: GlacierInfo.resourcesBundle, with: nil), for: .normal)
                thread.expiresIn = "604800"
                break
            case 6: //IOSM#6
                messageInputBar.sendButton.setImage(UIImage(named: "timer_4w_blue", in: GlacierInfo.resourcesBundle, with: nil), for: .normal)
                thread.expiresIn = "2419200"
                break
            default:
                self.timeOn = false
                messageInputBar.sendButton.image = nil
                thread.expiresIn = nil
                break
        }
        
        self.buddy?.expiresIn = thread.expiresIn
        thread.storeInGRDB()
    }

    // MARK: UIGestureRecognizerDelegate
    public func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer:UIGestureRecognizer) -> Bool {
        return true
    }

    @objc func clearTimePicker(gesture:UITapGestureRecognizer) {
        self.timePickerTextField?.resignFirstResponder()
        self.timePickerTextField?.removeFromSuperview()
        self.timePickerTextField = nil
        if let ttGesture = self.timeTapGesture {
            self.view.removeGestureRecognizer(ttGesture)
        }
        if let ttGesture2 = self.timeTapGesture2 {
            self.timePickerView?.removeGestureRecognizer(ttGesture2)
        }
        self.timeTapGesture = nil
        self.timeTapGesture2 = nil
        self.timePickerView = nil
    }
    
    override open func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == self.timeTapGesture || gestureRecognizer == self.timeTapGesture2 || gestureRecognizer == self.statusTapGestureRecognizer {
            return true
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

extension ChatViewControllerExt : CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        self.lastLoc = locations.last?.coordinate

        if (self.awaitingLocationPermission) {
            self.awaitingLocationPermission = false
            self.doShareLocation()
        }
    }
    
    public func locationManagerDidChangeAuthorization(_ manager:CLLocationManager) {
        let authStatus = manager.authorizationStatus
        if (authStatus == .authorizedAlways || authStatus == .authorizedWhenInUse) {
            //IOSM#26
            self.mapView?.userTrackingMode = .follow
            self.mapView?.showsUserLocation = true
            
            if let last = self.lastLoc, CLLocationCoordinate2DIsValid(last) {
                self.mapView?.camera.centerCoordinate = last
            }
            //if let account = self.getAccount(), account.trackingOn == false {
                self.locationManager.startUpdatingLocation()
            //}
        }
    }
}

extension ChatViewControllerExt : MKMapViewDelegate {
}
