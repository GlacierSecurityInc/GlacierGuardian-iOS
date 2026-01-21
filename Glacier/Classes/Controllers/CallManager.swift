//
//  CallManager.swift
//  Created by Andy Friedman on 2/10/20.
//  Copyright © 2020 Glacier Security. All rights reserved.

import Foundation
import XMPPFramework
import CallKit
import TwilioVoice
import AVFoundation
import WebRTC

@objc public protocol GlacierCallDelegateProtocol:NSObjectProtocol {
    func holdCall(_ onHold: Bool)
    func muteAudio(_ shouldMute: Bool)
    func disconnectCall(_ userInitiated: Bool)
    func turnOnVideo()
    func isConnected() -> Bool
    func setStatus(_ status:String)
    func setBluetoothEnabled(_ bluetoothEnabled: Bool)
    func handleAudioDenied()
    func handleVideoUpgradeRequest(completion: @escaping (Bool) -> Void) 
}

protocol WebRTCConnectionDelegate:AnyObject {
    func webRTCCallConnected()
    func webRTCCallDisconnected()
    func webRTCCallVideoAdded()
    func webRTCCallVideoRejected()
    func webRTCCallFailed()
    func webRTCCallClosed()
}

@objc public protocol CallStatusDelegateProtocol:NSObjectProtocol {
    func joinStatusUpdated(_ join: Bool)
}

public enum SpeakerChoice : UInt {
    case receiver = 0
    case speaker = 1
    case bluetooth = 2
}

public enum CallType : UInt {
    case audio = 0
    case video = 1
}

/**
 * The purpose of this class is to collect and process server
 * and push info in one place.
 *
 * All public members must be accessed from the main queue.
 */
public class CallManager: XMPPModule {
    private static let shared = CallManager(dispatchQueue: nil)
    
    @objc public static let XMPPCommandNamespace = "http://jabber.org/protocol/commands"
    @objc public static let CallManagerErrorDomain = "CallManagerErrorDomain"
    public static let JINGLE_MESSAGE = "urn:xmpp:jingle-message:0"
    public static let JINGLE_APPS_RTP = "urn:xmpp:jingle:apps:rtp:1"
    public static let JINGLE_TRANSPORT_ICE_UDP = "urn:xmpp:jingle:transports:ice-udp:1"
    public static let JINGLE_APPS_DTLS = "urn:xmpp:jingle:apps:dtls:0"
    public static let JINGLE = "urn:xmpp:jingle:1"
    public static let DLTS_SRTP_VERIFICATION = "http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification"

    let kCachedDeviceToken = "CachedDeviceToken"
    let kCachedBindingDate = "CachedBindingDate"
    let kRegistrationTTLInDays = 365
    
    var tracker:XMPPIDTracker?
    var cAccount:ChatAccountModel?
    var currentCall:TwilioCall?
    var alternateCall:TwilioCall?
    var currentUuid:UUID?
    var lastUuid:UUID?
    var notificationUuid:String?
    var awaitingCallResponse:Bool = false
    @objc var waitingToAnswerCall:Bool = false
    var waitingToRespondBusy:Bool = false
    var waitingToRespondReject:Bool = false
    var isBusy:Bool = false
    var busyTone:Bool = false
    var busyId:String?
    var endedCall:Bool = false
    var receivedRetract:Bool = false
    var callToJoin:String?
    var hasIncomingVoiceCall:Bool = false
    var audioSession:AVAudioSession?
    
    var activeCallInvite:CallInvite?
    var activeCall:Call?
    
    var bluetoothAvailable: Bool = false
    var bluetoothEnabled: Bool = false
    var speakerChoice: SpeakerChoice = SpeakerChoice.receiver
    
    public var callToken:String?
    public var deviceToken:Data?
    
    @objc private weak var gcdelegate:GlacierCallDelegateProtocol? = nil
    @objc private weak var statusDelegate:CallStatusDelegateProtocol? = nil
    private weak var webRtcConnectionDelegate:WebRTCConnectionDelegate? = nil
    
    // CallKit components
    let callKitProvider: CXProvider
    let callKitCallController: CXCallController
    var userInitiatedDisconnect: Bool = false
    
    var callTimeout: DispatchWorkItem?
    var unconnectedAnswerCallAction: CXAnswerCallAction?
    var player: AVAudioPlayer?
    var incomingCallHandle:CXHandle?

    private var callObserver: CXCallObserver?

    private struct PendingIncomingCall {
        var uuid: UUID
        var pushCallId: String?
        var jmiCallId: String?
        var callerFromPush: String?
        var callerFromJmi: String?
        var callType: CallType?
        var hasVoipPush: Bool
        var hasJmiPropose: Bool
        var reportedToCallKit: Bool
        var timeoutWorkItem: DispatchWorkItem?
    }

    private var pendingIncomingCalls: [UUID: PendingIncomingCall] = [:]
    private var pendingAnswerCallActions: [UUID: CXAnswerCallAction] = [:]
    private var retractedCallIds: Set<String> = []
    
    //IOSM#70
    var retryMessageList: [XMPPElement] = []
    var retryAcceptCallList: [XMPPElement] = []
    var retryRejectCallList: [XMPPElement] = []
    
    private var proxyDetected: Bool = false
    
    /**
     * We will create an audio device and manage it's lifecycle in response to CallKit events.
     */
    var tvoaudioDevice: TwilioVoice.DefaultAudioDevice = TwilioVoice.DefaultAudioDevice()
    
    var iceServers:[RTCIceServer] = []
    private var iceServersRefreshDeadline: Date?
    //var iceCandidates:[RTCIceCandidate] = []
    let syncQueue = DispatchQueue(label: "callManager.syncQueue")

    deinit {
        // CallKit has an odd API...must call invalidate or the CXProvider is leaked.
        callKitProvider.invalidate()
        
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private override init(dispatchQueue: DispatchQueue? = nil) {
        self.cAccount = nil
        
        let configuration = CXProviderConfiguration(localizedName: "Glacier")
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        //configuration.ringtoneSound = "MarimbaRingtone.wav"
        configuration.supportsVideo = true
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false;
        if let callKitIcon = UIImage(named: "glacier", in: GlacierInfo.resourcesBundle, compatibleWith: nil) {
            configuration.iconTemplateImageData = callKitIcon.pngData()
        }
        callKitProvider = CXProvider(configuration: configuration)
        callKitCallController = CXCallController()
        
        super.init(dispatchQueue: dispatchQueue)
        
        NotificationCenter.default.addObserver(self, selector: #selector(audioRouteChange(_:)), name: NSNotification.Name(rawValue: AVAudioSession.routeChangeNotification.rawValue), object: nil)
        
        callKitProvider.setDelegate(self, queue: nil)
        callObserver = CXCallObserver()
        callObserver?.setDelegate(self, queue: DispatchQueue.main)
        
        self.tvoaudioDevice.block = {
            do {
                TwilioVoice.DefaultAudioDevice.DefaultAVAudioSessionConfigurationBlock()
                let audioSession = AVAudioSession.sharedInstance()
                
                try audioSession.setMode(.voiceChat)
                try audioSession.overrideOutputAudioPort(AVAudioSession.PortOverride.none)
                
            } catch {
                DDLogError("Twilio audio Fail: \(error.localizedDescription)")
            }
        }
        
        self.audioSession = AVAudioSession.sharedInstance()
        
        TwilioVoiceSDK.audioDevice = self.tvoaudioDevice
        self.tvoaudioDevice.block()
    }
    
    @objc public class func sharedCallManager() -> CallManager {
        return shared
    }
    
    @objc public func setAccount(_ account: ChatAccountModel) {
        self.cAccount = account
    }
    
    @objc public func hasAccount() -> Bool {
        if (self.cAccount != nil) {return true}
        
        return false
    }
    
    @objc public func setGlacierCallDelegate(_ del: GlacierCallDelegateProtocol?) {
        self.gcdelegate = del
    }
    
    func setWebRTCConnectionDelegate(_ del: WebRTCConnectionDelegate?) {
        self.webRtcConnectionDelegate = del
    }
    
    //IOSM-527b
    @objc public func setCallStatusDelegate(_ del: CallStatusDelegateProtocol) {
        self.statusDelegate = del
    }
    
    //ALF IOSM-503
    public func getCallBuddy(_ identity: String) -> ChatBuddyModel? {
        var bud:ChatBuddyModel?
        if let jid = XMPPJID(string: identity), let acct = self.cAccount {
            bud = ChatBuddyModel.fetchBuddyModel(jid: jid, accountUniqueId: acct.uniqueId)
        }
        return bud
    }

    private func normalizeCallerJid(from caller: String) -> XMPPJID? {
        let trimmedCaller = caller.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCaller.contains("@") {
            return XMPPJID(string: trimmedCaller)
        }
        if let account = self.cAccount,
           let buddy = ChatBuddyModel.fetchBuddyFrom(displayName: trimmedCaller, accountUniqueId: account.uniqueId),
           let buddyJid = XMPPJID(string: buddy.username) {
            return buddyJid
        }
        if let domain = self.cAccount?.domain {
            return XMPPJID(string: "\(trimmedCaller)@\(domain)")
        }
        return nil
    }

    private func resolveCallerDisplayName(from caller: String) -> String {
        guard let jid = normalizeCallerJid(from: caller) else { return caller }
        if let account = self.cAccount,
           let buddy = ChatBuddyModel.fetchBuddyModel(jid: jid, accountUniqueId: account.uniqueId) {
            let displayName = buddy.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !displayName.isEmpty {
                return displayName
            }
        }
        return jid.user ?? caller
    }
    
    //IOSM-527
    private func getCallBuddyFromId(_ uniqueid: String) -> ChatBuddyModel? {
        return ChatBuddyModel.getBuddy(uniqueId: uniqueid)
    }
    
    @discardableResult override public func activate(_ xmppStream: XMPPStream) -> Bool {
        if super.activate(xmppStream) {
            self.performBlock {
                self.tracker = XMPPIDTracker.init(stream: xmppStream, dispatchQueue: self.moduleQueue)
            }
        } else {
            return false
        }
        return true
    }
    
    public override func deactivate() {
        self.performBlock {
            self.tracker?.removeAllIDs()
            self.tracker = nil
            self.callTimeout?.cancel()
        }
        gcdelegate = nil
        super.deactivate()
    }
    
    // MARK: Public API
    
    /**
     * <iq from='hag66@shakespeare.lit/pda' id='h7ns81g' to='p2.glaciersec.cc' type='set'>
     *   <command xmlns='http://jabber.org/protocol/commands' action='execute' node='call-user-apns'>
     *     <x xmlns="jabber:x:data" type="submit">
     *       <field var="caller"><value>hag66</value></field>
     *       <field var="callerdevice"><value>152F11D4-9380-43E4-BCDE-B47314752B9B</value></field>
     *       <field var="receiver"><value>joe12@shakespeare.lit</value></field>
     *       <field var="roomname"><value>uih2345</value></field>
     *       <field var="group"><value>false</value></field>
     *     </x>
     *   </command>
     * </iq>
     * Note: caller is a bare/full JID, but receiver is the bare JID of the receiver
     */
    //ALF IOSM-503 changed to receivers and added name/title
    public func makeCall(_ receivers: [String], name: String, callType:CallType) -> Bool
    {
        if (self.xmppStream?.isConnected == false) { //IOSM#70
            self.handleFailedCall(true)
            return false
        }
        
        let call = TwilioCall()
        let iceServers = self.createIceServers()
        let isAudioOnly = (callType == .audio)
        let webClient = WebRTCClient(iceServers: iceServers, audioOnly: isAudioOnly, forceRelay: false)
        webClient.delegate = self
        call.webrtcClient = webClient
        call.receiver = receivers.first
        
        let uuidstr = self.xmppStream?.generateUUID
        let uuid = UUID(uuidString: uuidstr ?? "")
        
        self.currentUuid = uuid
        call.callUuid = uuid
        call.callid = uuidstr ?? ""
        call.isCaller = true
        call.outgoing = true
        call.caller = self.xmppStream?.myJID?.full
        call.callerFullJID = call.caller
        call.callstatus = .waiting
        call.audioOnly = isAudioOnly
        call.calltitle = name// ?? call.receiver?.components(separatedBy: "@")[0]
        self.currentCall = call
        self.userInitiatedDisconnect = false
        
        //call CallKit here before sending to ejabberd
        if let uuid = self.currentUuid {
            performStartCallAction(uuid: uuid, receiver: name) //receiver)
        }
        
        self.sendJmiPropose(audioOnly: isAudioOnly)
        
        let callerJid = self.xmppStream?.myJID?.user ?? self.xmppStream?.myJID?.bare ?? self.xmppStream?.myJID?.full ?? ""
        let callerDisplayName = self.cAccount?.displayName ?? ""
        let deviceId = UIDevice.current.identifierForVendor?.uuidString
        let from = self.xmppStream?.myJID?.full
        
        // This is a public method, so it may be invoked on any thread/queue.
        self.performBlock(async: true){
            
            let command = XMLElement(name: "command", xmlns: CallManager.XMPPCommandNamespace)
            command.addAttribute(withName: "action", stringValue: "execute")
            command.addAttribute(withName: "node", stringValue: "call-user-apns")
            let x = XMLElement(name: "x", xmlns: "jabber:x:data")
            x.addAttribute(withName: "type", stringValue: "submit")
            
            let callerfield = XMLElement(name: "field")
            callerfield.addAttribute(withName: "var", stringValue: "caller")
            let callerval = XMLElement(name: "value", stringValue: callerJid)
            callerfield.addChild(callerval)

            let callerDisplayNameField = XMLElement(name: "field")
            callerDisplayNameField.addAttribute(withName: "var", stringValue: "callerDisplayName")
            let callerDisplayNameValue = XMLElement(name: "value", stringValue: callerDisplayName)
            callerDisplayNameField.addChild(callerDisplayNameValue)
            
            let devicefield = XMLElement(name: "field")
            devicefield.addAttribute(withName: "var", stringValue: "callerdevice")
            let deviceval = XMLElement(name: "value", stringValue: deviceId)
            devicefield.addChild(deviceval)
            
            let receiverfield = XMLElement(name: "field")
            receiverfield.addAttribute(withName: "var", stringValue: "receiver")
            
            for callbuddy in receivers {
                let receiverval = XMLElement(name: "value", stringValue: callbuddy)
                receiverfield.addChild(receiverval)
            }
            
            let webrtcfield = XMLElement(name: "field")
            webrtcfield.addAttribute(withName: "var", stringValue: "webrtcId")
            let webrtcval = XMLElement(name: "value", stringValue: self.currentUuid!.uuidString)
            webrtcfield.addChild(webrtcval)
            
            x.addChild(callerfield)
            x.addChild(callerDisplayNameField)
            x.addChild(devicefield)
            x.addChild(receiverfield)
            //from will provide the caller full jid
            
            x.addChild(webrtcfield)
            
            command.addChild(x)
            let tojid = XMPPJID(string: "p2." + GlacierInfo.defaultHost())
            let iq = XMPPIQ.init(iqType: XMPPIQ.IQType.set, to: tojid, elementID: self.xmppStream?.generateUUID, child: command)
            iq.addAttribute(withName: "from", stringValue: from!)
            
            self.tracker?.add(iq, target: self, selector: #selector(self.handleMakeCallResponse(_:)), timeout: 15)
            
            self.xmppStream?.send(iq)
        }
        
        return true
    }
    
    @objc private func handleMakeCallResponse(_ iq: XMPPIQ) {
        let x = iq.childElement?.element(forName: "x", xmlns: "jabber:x:data")
        guard let fields = x?.elements(forName: "field") else {
            //handle failed case, alert user
            performCancelCallAction(userInitiated: false)
                
            self.handleFailedCall(false)
            return
        }
        
        guard let url = Bundle.main.url(forResource: "outboundring", withExtension: "wav") else { return }
        playSound(soundUrl: url)
        player?.numberOfLoops = 3
    }
    
    func makeVoiceCall(_ receiver: String, name: String) {
        var contact = PhoneContact(name: name, phoneNumber: receiver)
        if let foundContact = TwilioBackendManager.sharedMgr().getMatchingContact(receiver) {
            contact = foundContact
        }
        self.makeVoiceCall(contact)
    }
    
    func makeVoiceCall(_ contact:PhoneContact) {//receiver: String, name: String) {
        guard let callto = CallManager.formatDialString(contact.phoneNumber) else {
            DDLogError("***** Unable to format phone number for dialing")
            return
        }

        var updatedContact = contact
        updatedContact.phoneNumber = callto

        let call = TwilioCall()
        call.receiver = callto
        call.calltitle = contact.name //ALF IOSM-503 and change to receivers above
        call.caller = TwilioBackendManager.sharedMgr().selectedAccount?.grdbRecord?.phoneNumber
        self.currentUuid = UUID.init()
        call.callUuid = self.currentUuid
        call.isVoice = true
        call.isCaller = true
        call.contact = updatedContact
        self.currentCall = call
        
        //call CallKit here before sending to ejabberd
        if let uuid = self.currentUuid {
            performStartCallAction(uuid: uuid, receiver: contact.name) //receiver)
        }
    }
    
    static func cleanPhoneNumber(_ phoneNumber: String) -> String {
        let cleanedPhoneNumber = phoneNumber.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
        return cleanedPhoneNumber
    }

    static func formatDialString(_ phoneNumber: String) -> String? {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        if trimmed.hasPrefix("+") {
            let digitsOnly = trimmed.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            guard digitsOnly.isEmpty == false else { return nil }
            return "+" + digitsOnly
        }

        let digitsOnly = cleanPhoneNumber(trimmed)
        guard digitsOnly.isEmpty == false else { return nil }

        if digitsOnly.count == 10 {
            return "+1" + digitsOnly
        }

        return "+" + digitsOnly
    }
    
    @objc private func handleFailedCall(_ networkDown: Bool) { //IOSM#70
        var name = ""
        if let names = self.currentCall?.receiver?.components(separatedBy: ",") {
            for rec in names {
                name = name + rec.components(separatedBy: "@")[0]
            }
        }
        if (name.count == 0) {
            name = "the other user(s)"
        }
        
        var msg = "Your call could not be connected. Please make sure \(name) has opened Glacier at least once after logging in and if the problem continues contact Glacier Support."
        if (networkDown == true) {
            msg = "Your call could not be connected. Please check your network connection and if the problem continues contact Glacier Support."
        }
        
        //let name = self.currentCall?.receiver?.components(separatedBy: "@")[0]
        //let user = name ?? "the other user(s)"
        let alert = UIAlertController(title: "Call Failed", message: msg, preferredStyle: .alert)
        let cancelAction = UIAlertAction(title: "OK", style: .cancel, handler: nil)
        alert.addAction(cancelAction)
        DispatchQueue.main.async {
            if OTRAppDelegate.appDelegate.isGroupChatController {
                OTRAppDelegate.appDelegate.chatRoomViewController.present(alert, animated: true, completion: nil)
            } else {
                OTRAppDelegate.appDelegate.chatViewController.present(alert, animated: true, completion: nil)
            }
        }
    }
    

    /**
    * <iq from='hag66@shakespeare.lit/pda' id='h7ns81g' to='p2.glaciersec.cc' type='set'>
    *   <command xmlns='http://jabber.org/protocol/commands' action='execute' node='accept-call-apns'>
    *     <x xmlns="jabber:x:data" type="submit">
    *       <field var="callid"><value>237</value></field>
    *       <field var="receiverdevice"><value>152F11D4-9380-43E4-BCDE-B47314752B9B</value></field>
    *     </x>
    *   </command>
    * </iq>
    * Note: caller is a display name, but receiver is the bare JID of the receiver
    */
    public func acceptCall(_ call: TwilioCall) {
        DDLogDebug("***** acceptCall, will send proceed")
        UIDevice.current.isProximityMonitoringEnabled = false
        self.userInitiatedDisconnect = false
        //let callid = call.callid
        //let me = self.cAccount?.displayName
        //self.currentCall = call
        
        //send JmiProceed
        //createConnectingTimeoutTimer()
        self.sendJmiProceed(call)
        
        //openCallStuff
        DispatchQueue.main.async {
            call.systemMessage = "Received call" //ALF IOSM-442
            OTRAppDelegate.appDelegate.conversationViewController.connectVideoCall(call)
            self.gcdelegate?.setStatus("Connecting...")
        }
    }
    
    /*
     <message from='juliet@capulet.example/phone'
              to='romeo@montague.example'
              type='chat'>
       <proceed xmlns='urn:xmpp:jingle-message:0' id='ca3cf894-5325-482f-a412-a6e9f832298d'/>
         <device xmlns='http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification' id='1234' />
       </proceed>
       <store xmlns="urn:xmpp:hints"/>
     </message>
     */
    public func sendJmiProceed(_ call: TwilioCall) {
        guard let callid = call.callid, let callerjid = call.callerFullJID ?? call.caller, let tojid = XMPPJID(string: callerjid) else { return}
        
        guard let acct = self.cAccount, let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: acct), let bundle = xmpp.omemoSignalCoordinator?.fetchMyBundle() else { return }
        
        self.performBlock(async: true){
            guard let fromjid = self.xmppStream?.myJID?.full else { return }
            
            let proceedElement = XMLElement(name: "proceed", xmlns: CallManager.JINGLE_MESSAGE)
            proceedElement.addAttribute(withName: "id", stringValue: callid)
            let device = XMLElement(name: "device", xmlns: CallManager.DLTS_SRTP_VERIFICATION)
            //get my omemo device id
            device.addAttribute(withName: "id", stringValue: String(bundle.deviceId))
            proceedElement.addChild(device)
            let xmppMessage = XMPPMessage(messageType: .chat, to: tojid, child: proceedElement)
            xmppMessage.addAttribute(withName: "from", stringValue: fromjid)
            xmppMessage.addStorageHint(.store)
                    
            //self.tracker?.add(xmppMessage, target: self, selector: #selector(self.handleJmiProposeResponse(_:)), timeout: 15)
                    
            self.sendXmppElement(xmppMessage)
        }
    }

    public func rejectCall(_ call: TwilioCall, busy: Bool) {
        //send JmiReject
        self.sendJmiReject(call, busy: busy)
        self.isBusy = false
        DDLogDebug("*** rejectCall isBusy: \(isBusy)")
    }
    
    /*
     <message from='juliet@capulet.example/phone'
              to='romeo@montague.example'
              type='chat'>
       <reject xmlns='urn:xmpp:jingle-message:0' id='ca3cf894-5325-482f-a412-a6e9f832298d'>
         <reason xmlns="urn:xmpp:jingle:1">
           <busy/>
           <text>Busy</text>
         </reason>
       </reject>
       <store xmlns="urn:xmpp:hints"/>
     </message>
     */
    public func sendJmiReject(_ call: TwilioCall, busy: Bool) {
        if let callerjid = call.callerFullJID ?? call.caller, let tojid = XMPPJID(string: callerjid), let callid = call.callid {
            DDLogDebug("sendJmiReject")
            self.performBlock(async: true){
                guard let fromjid = self.xmppStream?.myJID?.full else { return }
                
                let rejectElement = XMLElement(name: "reject", xmlns: CallManager.JINGLE_MESSAGE)
                rejectElement.addAttribute(withName: "id", stringValue: callid)
                let reason = XMLElement(name: "reason", xmlns: CallManager.JINGLE)
                if busy {
                    let busy = XMLElement(name: "busy")
                    let text = XMLElement(name: "text", stringValue: "Busy")
                    reason.addChild(busy)
                    reason.addChild(text)
                } else {
                    let cancel = XMLElement(name: "decline")
                    let text = XMLElement(name: "text", stringValue: "Decline")
                    reason.addChild(cancel)
                    reason.addChild(text)
                }
                rejectElement.addChild(reason)
                        
                let xmppMessage = XMPPMessage(messageType: .chat, to: tojid, child: rejectElement)
                xmppMessage.addAttribute(withName: "from", stringValue: fromjid)
                xmppMessage.addStorageHint(.store)
                        
                self.sendXmppElement(xmppMessage)
            }
        }
    }
    
    public func cancelCall(_ call: TwilioCall) {
        DDLogDebug("***** cancelCall")
        if call.isVoice == true {
            return
        }
        
        //let callid = call.callid
        //let caller = self.cAccount?.displayName
        var tojidstr = call.receiver
        if call.isCaller == false {
            tojidstr = call.callerFullJID
        }
        
        if call.callstatus == .connected {
            if let to = tojidstr, let tojid = XMPPJID(string: to) {
                let callToCancel = call
                self.performBlock(async: true){
                    DDLogDebug("***** cancelCall sending Terminate and JMI Finish")
                    self.sendSessionTerminate(callToCancel, to:tojid)
                    self.sendJmiFinishWithReason(callToCancel, reason: "User ended")
                }
            }
        } else {
            self.sendJmiRetract(call)
        }
    }
    
    /*
     <message from='romeo@montague.example/orchard'
              to='juliet@capulet.example'
              type='chat'>
       <retract xmlns='urn:xmpp:jingle-message:0' id='ca3cf894-5325-482f-a412-a6e9f832298d'>
         <reason xmlns="urn:xmpp:jingle:1">
           <cancel/>
           <text>Retracted</text>
         </reason>
       </retract>
       <store xmlns="urn:xmpp:hints"/>
     </message>
     */
    public func sendJmiRetract(_ call: TwilioCall) {
        DDLogDebug("***** sendJmiRetract ")
        
        if let receivers = call.receiver?.components(separatedBy: ","), let call = self.currentCall, let callerjid = call.caller, let callid = call.callid, let acct = self.cAccount, let acctjid = acct.bareJID, let domain = acct.domain {
            DDLogDebug("sendJmiRetract")
            for receiver in receivers { //IOSM-503 receivers
                if let tojid = XMPPJID(string: receiver) {
                    self.performBlock(async: true){
                        let retractElement = XMLElement(name: "retract", xmlns: CallManager.JINGLE_MESSAGE)
                        retractElement.addAttribute(withName: "id", stringValue: callid)
                        let reason = XMLElement(name: "reason", xmlns: CallManager.JINGLE)
                        let cancel = XMLElement(name: "cancel")
                        let text = XMLElement(name: "text", stringValue: "Retracted")
                        reason.addChild(cancel)
                        reason.addChild(text)
                        retractElement.addChild(reason)
                        
                        let xmppMessage = XMPPMessage(messageType: .chat, to: tojid, child: retractElement)
                        if let fromjid = self.xmppStream?.myJID?.full {
                            xmppMessage.addAttribute(withName: "from", stringValue: fromjid)
                        }
                        xmppMessage.addStorageHint(.store)
                        
                        self.sendXmppElement(xmppMessage)
                    }
                }
            }
        }
    }
    
    //make sure this is called from asyncBlock
    func sendJmiFinishWithReason(_ call:TwilioCall, reason:String) {
        //DDLogDebug("***** sendJmiFinishWithReason")
        if let callid = call.callid, let fromjid = self.xmppStream?.myJID?.full {
            
            var tojidstr = call.receiver
            if call.isCaller == false {
                tojidstr = call.callerFullJID
            }
            
            //DDLogDebug("sendJmiFinish with reason \(reason)")
            if let to = tojidstr, let tojid = XMPPJID(string: to) {
                //self.performBlock(async: true){
                    let finishElement = XMLElement(name: "finish", xmlns: CallManager.JINGLE_MESSAGE)
                    finishElement.addAttribute(withName: "id", stringValue: callid)
                    let reason = XMLElement(name: "reason", xmlns: CallManager.JINGLE)
                    let success = XMLElement(name: "success")
                    reason.addChild(success)
                    finishElement.addChild(reason)
                        
                    let xmppMessage = XMPPMessage(messageType: .chat, to: tojid, child: finishElement)
                    xmppMessage.addAttribute(withName: "from", stringValue: fromjid)
                        
                    self.sendXmppElement(xmppMessage)
                //}
            }
        }
    }
    
    @objc public func sendXmppElement(_ elem: XMPPElement) {
        if (self.xmppStream?.isConnected == true) {
            self.xmppStream?.send(elem)
        } else {
            self.retryMessageList.append(elem)
            if let acct = self.cAccount {
                if self.proxyDetected {
                    DDLogInfo("***** Not connected, and proxy detected, so not logging in to send XMPP.")
                    return
                }
                DDLogInfo("***** Not connected, so login to send XMPP.")
                OTRProtocolManager.shared.loginAccount(acct)
            }
        }
    }
    
    @objc public func setProxyDetected(_ detected: Bool) {
        proxyDetected = detected
    }
    
    @objc public func handleAuthentication() {
        self.performBlock(async: true){
            if (self.waitingToAnswerCall) {
                let presence = XMPPPresence()
                self.xmppStream?.send(presence)
                self.handleLoginSuccess()
            }
            
            self.retryAcceptCallList.forEach({ (iq) in
                //self.tracker?.add(iq, target: self, selector: #selector(self.handleAcceptCallResponse(_:)), timeout: 15)
                self.xmppStream?.send(iq)
            })
            self.retryAcceptCallList.removeAll()
            
            self.retryRejectCallList.forEach({ (iq) in
                self.xmppStream?.send(iq)
            })
            self.retryRejectCallList.removeAll()
            
            self.retryMessageList.forEach({ (xmppElem) in
                self.xmppStream?.send(xmppElem)
            })
            self.retryMessageList.removeAll()
        }
    }
    
    func handleSessionInitAccept(_ jingle:XMLElement, from:XMPPJID, isInit:Bool) {
        //DDLogInfo("***** in handleSessionInitAccept with Jingle: \(jingle)")
        if let fingerprintEl = JingleUtility.getFingerprintElement(from: jingle), let encrypted = fingerprintEl.omemo_encryptedElement(.conversationsLegacy) {
            
            if self.currentCall?.remoteSDP != nil {
                return
            } //already processed
            
            let deviceId = encrypted.omemo_senderDeviceId()
            guard let acct = self.cAccount,
                let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: acct),
                let keyData = encrypted.omemo_keyData(),
                let iv = encrypted.omemo_iv(),
                  let payload = encrypted.omemo_payload() else {
                return
            }
            
            self.currentCall?.remoteDeviceId = String(deviceId)
            
            if let fingerprint = xmpp.omemoSignalCoordinator?.getDecryptedPayload(keyData, senderDeviceId:deviceId, iv:iv, payload:payload, addressjid:from.bare), let webClient = self.currentCall?.webrtcClient {
                
                if jingle.elements(forName: "content").count > 1 {
                    //decrypt again to keep OMEMO numbering in line
                    let _ = xmpp.omemoSignalCoordinator?.getDecryptedPayload(keyData, senderDeviceId:deviceId, iv:iv, payload:payload, addressjid:from.bare)
                }
                
                self.performBlock(async: true){
                    let sdp = JingleUtility.generateSDP(from: jingle, fingerprint:fingerprint)
                    
                    //handle candidates in initial sdp (our webrtc lib does not like them --> fake transport-info iqs for these) ???
                    
                    //self.syncQueue.sync { //is this really necessary?
                    self.currentCall?.remoteSDP = sdp
                    //print("***** Remote: \(sdp)")
                    //}
                    
                    let sdpType:RTCSdpType = isInit ? .offer : .answer
                    let resultSDP = RTCSessionDescription(type: sdpType, sdp: sdp)
                    
                    webClient.setRemoteSdp(resultSDP, completion: { (error) in
                        if let error = error {
                            return //??
                        } else if isInit {
                            //self.currentCall?.callstatus = .connecting
                            webClient.answer(completion: { (asdp) in
                                self.currentCall?.localSDP = asdp.sdp
                                //print("***** Answer SDP: \(asdp.sdp)")
                                self.prepareSessionAnswer(from, sdp: asdp.sdp)
                            })
                            return
                        }
                        
                        // received session-accept I think
                        self.processIncomingCandidates(nil)
                        
                        self.performBlock(async: true){
                            guard let localSdp = self.currentCall?.localSDP else {
                                return
                            }
                            
                            if let curcall = self.currentCall, let myjid = self.xmppStream?.myJID?.full, let media = curcall.localMedia.first, let ufrag = media.iceUfrag, let pwd = media.icePwd {
                                let transportInfo = JingleUtility.generateTransportInfo(candidates: curcall.iceCandidates, ufrag: ufrag, pwd: pwd, initiator: myjid, responder: from.full, sessionID: curcall.callid!)
                                let eid = self.xmppStream?.generateUUID
                                let tiq = XMPPIQ.init(iqType: XMPPIQ.IQType.set, to: from, elementID: eid, child: transportInfo)
                                tiq.addAttribute(withName: "from", stringValue: myjid)
                                //DDLogInfo("***** handleSessionInitAccept sending immediate transportInfo") //: \(transportInfo)")
                                self.sendXmppElement(tiq)
                            }
                        }
                    })
                }
            }
        } else {
            DDLogInfo("***** in handleSessionInitAccept fail")
        }
    }
    
    func handleContentAdd(_ jingle:XMLElement, from:XMPPJID) {
        //assume this is video?
        if self.currentCall?.remoteSDP == nil || self.currentCall?.audioOnly == false {
            self.sendCancelIQ(from)
            //self.sendContentReject(from)
            return
        } //should be already processed, or already should have video
        
        gcdelegate?.handleVideoUpgradeRequest(completion: { accepted in
            if accepted {
                self.processContentUpgrade(jingle, from:from, isInit:true)
            } else {
                self.sendContentReject(from)
            }
        })
    }
    
    func sendCancelIQ(_ to:XMPPJID) {
        guard let call = self.currentCall, let callId = call.callid else { return }
                
        let errorElement = XMLElement(name: "error")
        errorElement.addAttribute(withName: "type", stringValue: "cancel")
        let reason = XMLElement(name: "media-error", xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas")
        errorElement.addChild(reason)
        let iq = XMPPIQ.init(iqType: XMPPIQ.IQType.set, to: to, elementID: callId, child: errorElement)
        self.sendXmppElement(iq)
    }
    
    func processContentUpgrade(_ jingle:XMLElement, from:XMPPJID, isInit:Bool) {
        if let fingerprintEl = JingleUtility.getFingerprintElement(from: jingle), let encrypted = fingerprintEl.omemo_encryptedElement(.conversationsLegacy) {
            
            let deviceId = encrypted.omemo_senderDeviceId()
            guard let acct = self.cAccount,
                let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: acct),
                let keyData = encrypted.omemo_keyData(),
                let iv = encrypted.omemo_iv(),
                  let payload = encrypted.omemo_payload() else {
                self.sendCancelIQ(from)
                return
            }
            
            if let fingerprint = xmpp.omemoSignalCoordinator?.getDecryptedPayload(keyData, senderDeviceId:deviceId, iv:iv, payload:payload, addressjid:from.bare), let webClient = self.currentCall?.webrtcClient, let curCall = self.currentCall {
                
                if jingle.elements(forName: "content").count > 1 {
                    //decrypt again to keep OMEMO numbering in line
                    let _ = xmpp.omemoSignalCoordinator?.getDecryptedPayload(keyData, senderDeviceId:deviceId, iv:iv, payload:payload, addressjid:from.bare)
                }
                
                self.performBlock(async: true){
                    guard let remoteSdp = curCall.remoteSDP else {
                        self.sendCancelIQ(from)
                        return
                    }
                    let fullOrigSdp = webClient.peerConnection.remoteDescription
                    
                    if isInit == true {
                        self.gcdelegate?.turnOnVideo()
                    }
                    
                    let remoteAddedSdp = JingleUtility.generateSDP(from: jingle, fingerprint:fingerprint)
                    let remoteAddedMedia = JingleUtility.parseSDP(remoteAddedSdp)
                    let remoteMedia = JingleUtility.parseSDP(remoteSdp)
                    var fullMedia: [MediaDescription] = []
                    for var media in remoteMedia {
                        media.setup = remoteAddedMedia.first?.setup ?? media.setup
                        fullMedia.append(media)
                    }
                    fullMedia.append(contentsOf: remoteAddedMedia)
                    
                    let newJingle = JingleUtility.generateJingle(from: fullMedia, fingerprint: fingerprint)
                    let newSdp = JingleUtility.generateSDP(from: newJingle, fingerprint: fingerprint)
                    
                    self.currentCall?.remoteSDP = newSdp
                    //print("***** Remote: \(sdp)")
                    
                    let sessionType: RTCSdpType = isInit ? .offer : .answer
                    let resultSDP = RTCSessionDescription(type: sessionType, sdp: newSdp)
                    //print("***** processContentUpgrade 4 with sdp \(newSdp)")
                    
                    webClient.setRemoteSdp(resultSDP, completion: { (error) in
                        if isInit == false {
                            return
                        }
                        
                        if error != nil {
                            //self.sendCancelIQ(from)
                            self.sendContentReject(from)
                            if let origSdp = fullOrigSdp {
                                webClient.setRemoteSdp(origSdp, completion: { (error) in })
                            }
                            return
                        }
                        
                        self.sendVideoUpgradeResponse(from)
                    })
                }
            }
        }
    }
    
    //this is receiving after attempted upgrade, so we turn off video again
    //func handleContentReject(_ jingle:XMLElement, from:XMPPJID) {
        //self.processContentUpgrade(jingle, from: from, isInit: false)
    //}
    
    func handleContentAccept(_ jingle:XMLElement, from:XMPPJID) {
        self.processContentUpgrade(jingle, from: from, isInit: false)
    }
    
    func handleTransportInfo(_ jingle:XMLElement, from:XMPPJID) {
        //print("***** handleTransportInfo")
        self.performBlock(async: true){
            let sdpCandidates = JingleUtility.generateSDPCandidates(from: jingle)
            if let curcall = self.currentCall {
                //syncQueue this?
                for (key, newCandidates) in sdpCandidates {
                    if var existingCandidates = curcall.remoteIceCandidates[key] {
                        existingCandidates.append(contentsOf: newCandidates)
                        curcall.remoteIceCandidates[key] = existingCandidates
                    } else {
                        curcall.remoteIceCandidates[key] = newCandidates
                    }
                }
                
                if curcall.localSDP != nil && curcall.remoteSDP != nil {
                    //handle single
                    self.processIncomingCandidates(sdpCandidates)
                }  //otherwise wait and send when those are filled
                //This doesn't make sense...process when I receive them
                //send after I have both?
            }
        }
    }
}

extension CallManager: XMPPStreamDelegate {
    public func xmppStream(_ sender: XMPPStream, didReceive iq: XMPPIQ)  -> Bool {
        var result = false
        //IOSM-455 added error type
        if let type = iq.type, type == XMPPIQ.IQType.result.rawValue || type == XMPPIQ.IQType.error.rawValue {
            self.performBlock(async: true){
                result = self.tracker?.invoke(for: iq, with: iq) ?? false
            }
            if let type = iq.type, type == XMPPIQ.IQType.error.rawValue, let error = iq.element(forName: "error"), error.attributeStringValue(forName: "type") == "cancel", let notacc = iq.element(forName: "media-error", xmlnsPrefix: "urn:ietf:params:xml:ns:xmpp-stanzas") {
                //cancel the previous action? currently only possible during upgrade I think
                self.currentCall?.audioOnly = true
                self.webRtcConnectionDelegate?.webRTCCallVideoRejected()
            }
        } else if let type = iq.type, type == XMPPIQ.IQType.set.rawValue, let jingle = iq.element(forName: "jingle", xmlnsPrefix: CallManager.JINGLE), let from = iq.from {
            
            if let iqid = jingle.attributeStringValue(forName: "sid"), let call = self.currentCall, iqid == call.callid {
                DDLogDebug("***** jingle with sid \(iqid)")
                if jingle.attributeStringValue(forName: "action") == "session-initiate" {
                    //DDLogInfo("***** received session initiate about to call handleSessionInitAccept")
                    //check if this is related to current existing call or drop it
                    self.handleSessionInitAccept(jingle, from: from, isInit: true)
                } else if jingle.attributeStringValue(forName: "action") == "session-accept" {
                    //DDLogInfo("***** received session accept about to call handleSessionInitAccept")
                    self.handleSessionInitAccept(jingle, from: from, isInit: false)
                } else if jingle.attributeStringValue(forName: "action") == "transport-info" {
                    self.handleTransportInfo(jingle, from: from)
                } else if jingle.attributeStringValue(forName: "action") == "content-add" {
                    self.handleContentAdd(jingle, from: from)
                } else if jingle.attributeStringValue(forName: "action") == "content-accept" {
                    self.handleContentAccept(jingle, from: from)
                } else if jingle.attributeStringValue(forName: "action") == "content-reject" {
                    self.currentCall?.audioOnly = true
                    self.webRtcConnectionDelegate?.webRTCCallVideoRejected()
                } else if jingle.attributeStringValue(forName: "action") == "session-terminate" {
                    self.endedCall = true
                    DDLogDebug("***** received session terminate")
                    if let call = self.currentCall {
                        call.callstatus = .disconnected
                        call.webrtcClient?.terminateSession()
                        if let uuid = call.callUuid {
                            self.doDisconnect(uuid)
                        }
                    }
                }
            }
            
            //for now act like there are no errors and just respond
            //need to handle errors later. Maybe return error from the handlers if needed
            let iqid = iq.elementID ?? ""
            let iq = XMPPIQ.init(iqType: XMPPIQ.IQType.result, to: from, elementID: iqid)
            if let myjid = self.xmppStream?.myJID?.full {
                iq.addAttribute(withName: "from", stringValue: myjid)
            }
            self.sendXmppElement(iq)
            result = true
        }
        return result
    }
    
    //ALF IOSM-437
    public func xmppStream(_ sender: XMPPStream, didReceive message: XMPPMessage) {
        guard !message.containsGroupChatElements,
            // We handle carbons elsewhere via XMPPMessageCarbonsDelegate
            !message.isMessageCarbon,
            // We handle MAM elsewhere as well
            message.mamResult == nil,
            // OMEMO messages cannot be processed here
            !message.omemo_hasEncryptedElement(.conversationsLegacy),
            !message.isMessageWithBody else {
            return
        }
        
        if message.containsCallElements {
            if let callupdate = message.element(forName: "x", xmlns: "jabber:x:callupdate"), let callstatus = callupdate.attributeStringValue(forName: "callstatus"), let callid = callupdate.attributeStringValue(forName: "callid"), let from = message.from {
                if (callstatus == "accept") {
                    reportCallAccepted(from.bare, callid: callid, deviceid: "")
                } else if (callstatus == "reject") {
                    reportCallRejected(from, callid: callid)
                } else if (callstatus == "cancel") {
                    self.currentCall?.callstatus = .retracted
                    reportCallCancelled()
                } else if (callstatus == "busy") {
                    reportCallBusy()
                } else if (callstatus == "joincall") {
                    //let calltitle = callupdate.attributeStringValue(forName: "calltitle")
                    //reportCallJoinRequest(callid: callid, calltitle: calltitle)
                } else if (callstatus == "endcall") {
                    //reportCallEnded()
                }
            }
        } else if message.containsJmiElements {
            if let from = message.from?.bareJID, let to = message.to?.bareJID, from.isEqual(to: to) {
                return
            }
            
            if let propose = message.element(forName: "propose", xmlnsPrefix: CallManager.JINGLE_MESSAGE) {
                //DDLogInfo("***** receive propose")
                //syncQueue.sync {
                    let caller = message.fromStr ?? ""
                    let callid = propose.attributeStringValue(forName: "id") ?? ""
                        
                    if self.currentCall?.callid == callid {
                        return // MAM is doubling up
                    }
                    
                    var callType:CallType = .audio
                    if self.hasVideoDescription(in: propose) {
                        callType = .video
                    }
                    
                    if let uuid = UUID(uuidString: callid) {
                        self.handleJMIPropose(uuid: uuid, callId: callid, caller: caller, callType:callType)
                    }
                //}
                DDLogInfo("Received JMI propose message: \(propose)")
            } else if let ringing = message.element(forName: "ringing", xmlnsPrefix: CallManager.JINGLE_MESSAGE) {
                //shows call was received on other side?
                DDLogInfo("Received JMI ringing message: \(ringing)")
            } else if let retract = message.element(forName: "retract", xmlnsPrefix: CallManager.JINGLE_MESSAGE) {
                let callid = retract.attributeStringValue(forName: "id") ?? ""
                if !callid.isEmpty {
                    markCallRetracted(callId: callid)
                }
                self.receivedRetract = true
                self.currentCall?.callstatus = .retracted
                reportCallCancelled()
                DDLogInfo("***** Received JMI retract message: \(retract)")
            } else if let proceed = message.element(forName: "proceed", xmlns: CallManager.JINGLE_MESSAGE), let callid = proceed.attributeStringValue(forName: "id"), let from = message.from, let device = proceed.element(forName: "device"), let deviceId = device.attributeStringValue(forName: "id") {
                reportCallAccepted(from.full, callid: callid, deviceid: deviceId)
                DDLogInfo("Received JMI proceed message: \(proceed)")
            } else if let reject = message.element(forName: "reject", xmlnsPrefix: CallManager.JINGLE_MESSAGE), let from = message.from, let callid = reject.attributeStringValue(forName: "id") {
                if let reason = reject.element(forName: "reason"), let _ = reason.element(forName: "busy") {
                    reportCallBusy()
                } else {
                    reportCallRejected(from, callid: callid)
                }
                DDLogInfo("Received JMI reject message: \(reject)")
            } else if let finish = message.element(forName: "finish", xmlnsPrefix: CallManager.JINGLE_MESSAGE) {
                let callid = finish.attributeStringValue(forName: "id") ?? ""
                if let uuid = UUID(uuidString: callid) {
                    performEndCallAction(uuid: uuid, userInitiated: false)
                }
                DDLogInfo("Received JMI finish message: \(finish)")
            }
        }
    }
    
    func hasVideoDescription(in proposeElement: XMLElement) -> Bool {
        // Look for <description> children
        let descriptions = proposeElement.elements(forLocalName: "description", uri: CallManager.JINGLE_APPS_RTP)
        
        for desc in descriptions {
            // Check the 'media' attribute
            if let mediaType = desc.attributeStringValue(forName: "media"),
               mediaType.lowercased() == "video" {
                return true
            }
        }
        
        return false
    }
}

public class TwilioCall:AnyObject {
    public var caller:String?
    public var callerFullJID:String?
    public var receiver:String?
    public var roomname:String?
    public var token:String?
    public var callid:String?
    public var calltitle:String? //ALF IOSM-503
    public var status:String?
    public var systemMessage:String?
    public var callUuid:UUID?
    public var outgoing:Bool = true
    public var isGroup:Bool = false //IOSM-545
    public var isCaller:Bool = false //IOSM-527b
    public var isVoice:Bool = false
    public var audioOnly:Bool = false
    var contact:PhoneContact?
    var webrtcClient:WebRTCClient?
    var localSDP:String?
    var localMedia:[MediaDescription] = []
    var remoteSDP:String?
    var remoteDeviceId:String?
    var iceCandidates:[String:[IceCandidate]] = [:]
    var remoteIceCandidates:[String:[String]] = [:]
    var callstatus:CallStatus = .disconnected
    var answerCallAction: CXAnswerCallAction?
    var callKitAnswerFulfilled: Bool = false
}

public enum CallStatus : Int {
    case disconnected = 0
    case waiting = 1
    case connecting = 2
    case connected = 3
    case retracted = 4
    case unknown = 5
}

extension CallManager : CXProviderDelegate {

    public func providerDidReset(_ provider: CXProvider) {
        DDLogInfo("Twilio providerDidReset:")

        // AudioDevice is enabled by default
        // The Phone code has this as false. why?
        self.tvoaudioDevice.isEnabled = false
        
        //room?.disconnect()
        gcdelegate?.disconnectCall(false)
    }

    public func providerDidBegin(_ provider: CXProvider) {
        DDLogInfo("Twilio providerDidBegin")
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        DDLogInfo("***** didActivateAudioSession:")
        if let curcall = self.currentCall, curcall.isVoice {
            //DDLogInfo("***** didActivateAudioSession isVoice:")
            self.tvoaudioDevice.isEnabled = true
        } else {
            self.audioSession = audioSession
            self.didActivate(audioSession: audioSession)
        }
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        //DDLogInfo("Twilio provider:didDeactivateAudioSession:")
        self.tvoaudioDevice.isEnabled = false
        if let asession = self.audioSession {
            self.didDeactivate(audioSession: asession)
        }
        self.audioSession = nil
        CallManager.configureDefaultAudioSession()
    }

    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        //DDLogInfo("Twilio provider:timedOutPerformingAction:")
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        //DDLogInfo("Twilio provider:performStartCallAction:")

        /*
         * Configure the audio session, but do not start call audio here, since it must be done once
         * the audio session has been activated by the system after having its priority elevated.
         */

        callKitProvider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        
        if self.currentCall?.isVoice == true {
            
            var callContact = self.currentCall?.contact
            if callContact == nil, let name = self.currentCall?.calltitle, let receiver = self.currentCall?.receiver  {
                callContact = PhoneContact(name: name, phoneNumber: receiver)
            }
            
            guard let contact = callContact else {
                return
            }
            
            performMakeVoiceCall(uuid: action.callUUID, contact: contact) { success in
                if success {
                    DDLogDebug("performMakeVoiceCall() successful")
                    self.callKitProvider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
                } else {
                    DDLogDebug("performMakeVoiceCall() failed")
                }
            }
        } else {
            if self.checkAudioPermissions() == false {
                self.currentCall?.webrtcClient?.configureAudioSession()
            }
        }
        
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        DDLogDebug("***** CXProvider:performAnswerCallAction: \(action.callUUID)")

        /*
         * Configure the audio session, but do not start call audio here, since it must be done once
         * the audio session has been activated by the system after having its priority elevated.
         */
        self.callTimeout?.cancel()
        
        if self.currentCall != nil {
            self.currentCall?.callstatus = .connecting
            self.currentCall?.answerCallAction = action
            self.currentCall?.callKitAnswerFulfilled = true
        } else {
            pendingAnswerCallActions[action.callUUID] = action
            self.waitingToAnswerCall = true
            self.unconnectedAnswerCallAction = action
            let task = DispatchWorkItem {
                //DDLogInfo("***** calling timeout")
                self.performTimeout()
            }
            callTimeout = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: callTimeout!)
        }

        action.fulfill()
        self.handleAnswerCall()
        self.gcdelegate?.setStatus("Connecting...")
        self.awaitingCallResponse = false
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        //print("Twilio provider:performEndCallAction: with *** userInitiatedDisconnect: \(userInitiatedDisconnect)")
        //DDLogInfo("***** CXProvider:CXEndCallAction:")
        
        self.callTimeout?.cancel()
        
        if isBusy, hasIncomingVoiceCall == false {
            self.handleBusyCall()
            action.fulfill()
            //DDLogInfo("***** CXProvider:CXEndCallAction: returning early")
            return
        }
        
        if let invite = activeCallInvite {
            invite.reject()
        } else if !userInitiatedDisconnect {
            //DDLogInfo("***** CXProvider:CXEndCallAction: !userInitiatedDisconnect")
            gcdelegate?.disconnectCall(false)
            if self.endedCall == false, let call = self.currentCall, !self.busyTone, self.receivedRetract == false {
                //DDLogInfo("***** CXProvider:CXEndCallAction: about to cancelCall")
                self.cancelCall(call)
            }
        } else if let call = activeCall {
            //print("***** performEndCallAction: with activeCall")
            call.disconnect()
            gcdelegate?.disconnectCall(false)
        }
        
        if let currentCall = self.currentCall,
           currentCall.callUuid == action.callUUID,
           currentCall.callstatus == .waiting,
           self.receivedRetract == false {
            //DDLogInfo("***** CXProvider:CXEndCallAction: awaitingCallResponse")
            self.handleRejectCall() //IOSM-515 derivative
        }

        self.endedCall = false
        self.hasIncomingVoiceCall = false
        self.awaitingCallResponse = false
        self.waitingToAnswerCall = false
        let hasActiveCall = self.isCallActive()
        if !hasActiveCall || (hasActiveCall && activeCallInvite == nil) {
            //DDLogInfo("***** performEndCallAction: nullifying currentCall")
            self.currentUuid = nil
            self.notificationUuid = nil
            self.currentCall = nil
            self.alternateCall = nil
        }
        self.activeCallInvite = nil
        self.isBusy = false
        self.busyTone = false
        self.receivedRetract = false
        clearPendingCall(uuid: action.callUUID)
        action.fulfill()
        //DDLogInfo("***** CXProvider:CXEndCallAction: end")
    }
    
    func finalizeVoiceCall() {
        if let uuid = self.activeCall?.uuid {
            callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        }
        self.activeCallInvite = nil
        self.activeCall = nil
        
        if let url = Bundle.main.url(forResource: "MarimbaBlink", withExtension: "wav") {
            self.playSound(soundUrl: url)
        }
        self.performSpeakerAction(selection: SpeakerChoice.bluetooth)
        self.setGlacierCallDelegate(nil)
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        DDLogInfo("Twilio provider:performSetMutedCallAction:")
        
        gcdelegate?.muteAudio(action.isMuted)
        
        /*if let call = activeCalls[action.callUUID.uuidString] {
            call.isMuted = action.isMuted
            action.fulfill()
        } else {
            action.fail()
        }*/
        
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        DDLogInfo("Twilio provider:performSetHeldCallAction:")

        let cxObserver = callKitCallController.callObserver
        let calls = cxObserver.calls

        guard let call = calls.first(where:{$0.uuid == action.callUUID}) else {
            action.fail()
            return
        }

        if call.isOnHold {
            gcdelegate?.holdCall(false)
        } else {
            gcdelegate?.holdCall(true)
        }
        
        /*if let call = activeCalls[action.callUUID.uuidString] {
            call.isOnHold = action.isOnHold

            /** Explicitly enable the TVOAudioDevice.
            * This is workaround for an iOS issue where the `provider(_:didActivate:)` method is not called
            * when un-holding a VoIP call after an ended PSTN call.
            */ https://developer.apple.com/forums/thread/694836
            if !call.isOnHold {
                audioDevice.isEnabled = true
                activeCall = call
            }

            toggleUIState(isEnabled: true, showCallControl: true)

            action.fulfill()
        } else {
            action.fail()
        }*/
        
        action.fulfill()
    }
}

extension CallManager {
    
    static func configureDefaultAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        
        DDLogDebug("***** Configuring default audio session...")
        
        var options: AVAudioSession.CategoryOptions = []
        options.insert(.mixWithOthers)

        do {
            try audioSession.setPreferredSampleRate(24000)
            try audioSession.setPreferredIOBufferDuration(0.2)
            try audioSession.setCategory(.playback, mode: .default, options: options)
        } catch {
            DDLogError("Failed to configure audio session: \(error)")
        }

        do {
            try audioSession.setActive(true, options: [])
        } catch {
            DDLogError("Error activating audio session: \(error)")
        }

        DDLogVerbose("Current audio route: \(audioSession.currentRoute)")
    }

    func performStartCallAction(uuid: UUID, receiver: String?) {
        let callHandle = CXHandle(type: .generic, value: receiver ?? "")
        let startCallAction = CXStartCallAction(call: uuid, handle: callHandle)
        
        startCallAction.isVideo = false
        
        let transaction = CXTransaction(action: startCallAction)
        
        callKitCallController.request(transaction)  { error in
            if let error = error {
                DDLogError("StartCallAction transaction request failed: \(error.localizedDescription)")
                return
            }
            //DDLogInfo("StartCallAction transaction request successful")
            
            /*let callUpdate = CXCallUpdate()
            callUpdate.remoteHandle = callHandle
            callUpdate.supportsDTMF = true
            callUpdate.supportsHolding = true
            callUpdate.supportsGrouping = false
            callUpdate.supportsUngrouping = false
            callUpdate.hasVideo = false
            self.callKitProvider.reportCall(with: uuid, updated: callUpdate)*/
        }
    }
    
    func performMakeVoiceCall(uuid: UUID, contact: PhoneContact, completionHandler: @escaping (Bool) -> Void) {
        guard let accessToken = self.callToken else {
            return
        }
        
        let appDelegate = UIApplication.shared.delegate as? OTRAppDelegate
        //print("***** performMakeVoiceCall with \(client ?? "")")
        appDelegate?.openPhoneCallController(contact)//client ?? "")
        if let callVC = appDelegate?.callWindow?.rootViewController?.presentedViewController as? VoiceCallViewController, let tcall = self.currentCall {
            //print("***** UUID tcall: \(tcall.callUuid)")
            
            let connectOptions = ConnectOptions(accessToken: accessToken) { builder in
                builder.params = [callVC.CALL_TO: self.currentCall?.receiver ?? "",
                                  callVC.CALL_FROM: self.currentCall?.caller ?? ""]
                builder.uuid = uuid
            }
            
            callVC.callKitCompletionCallback = completionHandler
            let call = TwilioVoiceSDK.connect(options: connectOptions, delegate: callVC)
            activeCall = call
            
            //self.reportCallConnected(uuid: tcall.callUuid, connectTime: Date())
            callVC.setConnectedCall(tcall, activeCall:call, with:self.currentCall?.calltitle ?? "")
        }
    }
    
    func performAnswerVoiceCall() {
        //at this point open VoiceCallViewController? Instantiate it and make it the delegate
        //call appDelegate to open the UI
        //set UI as the delegate
        
        guard let callInvite = activeCallInvite else {
            //DDLogInfo("***** No CallInvite matches the UUID")
            return
        }
        
        let acceptOptions = AcceptOptions(callInvite: callInvite) { builder in
            builder.uuid = callInvite.uuid
        }
        
        var callContact = self.currentCall?.contact
        if callContact == nil {
            var contact = PhoneContact(name: "Unknown", phoneNumber: "Unknown")
            var contactnum = contact.phoneNumber
            if let tcall = self.currentCall, let from = tcall.caller {
                contactnum = from
                contact.name = tcall.calltitle ?? from
                contact.phoneNumber = from
            } else if let from = callInvite.from {
                contactnum = from
                contact.name = from
                contact.phoneNumber = from
            }
            
            if let foundContact = TwilioBackendManager.sharedMgr().getMatchingContact(contactnum) {
                contact = foundContact
            }
            callContact = contact
        }
        
        guard let contact = callContact else {
            DDLogInfo("***** No contact found for call")
            return
        }
        
        let appDelegate = UIApplication.shared.delegate as? OTRAppDelegate
        //print("***** performAnswerVoiceCall")
        appDelegate?.openPhoneCallController(contact)//calltitle)
        if let callVC = appDelegate?.callWindow?.rootViewController?.presentedViewController as? VoiceCallViewController, let tcall = self.currentCall {
            //print("***** UUID tcall: \(tcall.callUuid)")
            let call = callInvite.accept(options: acceptOptions, delegate: callVC)
            activeCall = call
            self.reportCallConnected(uuid: tcall.callUuid, connectTime: Date())
            callVC.setConnectedCall(tcall, activeCall:call, with:contact.name)
        }
        
        activeCallInvite = nil
    }
    
    func dialedDigit(_ digit: String) {
        if let curCall = self.activeCall {
            curCall.sendDigits(digit)
            //print("**** dialed digit: \(digit)")
        }
    }
    
    func handleAnswerCall() {
        guard let acct = self.cAccount else { return }
        
        if let tcall = self.currentCall {
            if tcall.isVoice {
                self.performAnswerVoiceCall()
            } else if OTRProtocolManager.sharedInstance().isAccountIdConnected(acct.uniqueId) {
                //DDLogInfo("***** handleAnswerCall, with current call and account connected")
                self.acceptCall(tcall)
            } else {
                self.waitingToAnswerCall = true
                //DDLogInfo("***** handleAnswerCall, with current call and account NOT connected")
            }
        } else {
            //DDLogInfo("***** handleAnswerCall, with no current call")
            self.waitingToAnswerCall = true
            var calltitle = self.incomingCallHandle?.value ?? ""
            DispatchQueue.main.async {
                let appDelegate = UIApplication.shared.delegate as? OTRAppDelegate
                appDelegate?.openVideoCallController(calltitle)
                self.gcdelegate?.setStatus("Connecting...")
            }
        }
    }
    
    func handleBusyCall() { //IOSM-515
        if let acct = self.cAccount, let bid = self.busyId {
            if OTRProtocolManager.sharedInstance().isAccountIdConnected(acct.uniqueId), let bcall = self.alternateCall {
                //let bcall = TwilioCall()
                //bcall.callid = bid
                self.rejectCall(bcall, busy: true)
            } else {
                self.waitingToRespondBusy = true
            }
        }
    }
    
    func handleRejectCall() { //IOSM-515
        if let acct = self.cAccount, let tcall = self.currentCall {
            if OTRProtocolManager.sharedInstance().isAccountIdConnected(acct.uniqueId) {
                self.rejectCall(tcall, busy: false)
            } else {
                self.waitingToRespondReject = true
            }
        }
    }
    
    @objc func handleLoginSuccess() {
        if self.waitingToAnswerCall {
            if let tcall = self.currentCall {
                //self.callTimeout?.cancel()
                self.acceptCall(tcall)
            } else {
                //DDLogInfo("***** handleLoginSuccess, still waiting for call info")
                return
            }
        } else if (self.waitingToRespondBusy) { //IOSM-515
            handleBusyCall()
        } else if (self.waitingToRespondReject) { //IOSM-515 derivative
            handleRejectCall()
        }
        self.waitingToAnswerCall = false
        self.waitingToRespondBusy = false
        self.waitingToRespondReject = false
    }
    
    func isBluetoothAvailable() -> Bool {
        return self.bluetoothAvailable
    }
    
    //ALF IOSM-451
    @objc func audioRouteChange(_ notification:Notification) {
        //if (IPAD)
        //    return;
        //var headphonesConnected = false
        
        let session = AVAudioSession.sharedInstance()
        let newRoute = session.currentRoute
        if (newRoute.outputs.count > 0) {
            let route = newRoute.outputs[0].portType
            if ((route == AVAudioSession.Port.bluetoothA2DP || route == AVAudioSession.Port.bluetoothHFP)) {
                if (!bluetoothAvailable) {
                    bluetoothAvailable = true
                    gcdelegate?.setBluetoothEnabled(bluetoothAvailable)
                }
            } else {
                if (bluetoothAvailable) {
                    bluetoothAvailable = false
                    gcdelegate?.setBluetoothEnabled(bluetoothAvailable)
                }
            }
        }
    }
    
    func didActivate(audioSession: AVAudioSession)
    {
        let rtcaudioSession = RTCAudioSession.sharedInstance()
        do {
            DDLogDebug("***** Activating audio session now: \(audioSession)")

            rtcaudioSession.lockForConfiguration()

            let options: AVAudioSession.CategoryOptions = [
                .allowBluetooth,
                .allowBluetoothA2DP,
                .interruptSpokenAudioAndMixWithOthers,
                .allowAirPlay
            ]

            try rtcaudioSession.setCategory(.playAndRecord, with: options)

        } catch {
            DDLogError("Failed to configure AVAudioSession category: \(error)")
        }

        do {
            try rtcaudioSession.setPreferredSampleRate(24000)
            try rtcaudioSession.setPreferredIOBufferDuration(0.2)
            try rtcaudioSession.setMode(.voiceChat)
            try rtcaudioSession.setActive(true)
            try self.applyPreferredAudioRoute(audioSession)
        } catch {
            DDLogError("Failed to configure AVAudioSession mode: \(error)")
        }

        rtcaudioSession.audioSessionDidActivate(audioSession)
        rtcaudioSession.isAudioEnabled = true
        rtcaudioSession.unlockForConfiguration()
    }

    func didDeactivate(audioSession:AVAudioSession){
        DDLogDebug("Deactivating audio session now: \(audioSession)")
        RTCAudioSession.sharedInstance().lockForConfiguration()
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        RTCAudioSession.sharedInstance().unlockForConfiguration()
    }

    private func applyPreferredAudioRoute(_ audioSession: AVAudioSession) throws {
        switch speakerChoice {
        case .speaker:
            try audioSession.overrideOutputAudioPort(.speaker)
        case .receiver:
            try audioSession.overrideOutputAudioPort(.none)
        case .bluetooth:
            if let bluetoothInput = audioSession.availableInputs?.first(where: { input in
                return input.portType == .bluetoothHFP
                    || input.portType == .bluetoothLE
                    || input.portType == .bluetoothA2DP
            }) {
                try audioSession.setPreferredInput(bluetoothInput)
            }
        }
    }
    
    //ALF IOSM-437
    @objc func isRinging() -> Bool {
        if (self.awaitingCallResponse) {
            return true
        }
        return false
    }

    private func updateAwaitingCallResponseState() {
        let hasPendingJmi = !pendingIncomingCalls.isEmpty || self.currentCall?.callstatus == .waiting
        let hasVoiceRinging = activeCallInvite != nil || (self.currentCall?.isVoice == true && self.awaitingCallResponse)
        self.awaitingCallResponse = hasPendingJmi || hasVoiceRinging
    }

    private func schedulePendingTimeout(for uuid: UUID) {
        guard var pending = pendingIncomingCalls[uuid] else { return }
        pending.timeoutWorkItem?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard let existing = self.pendingIncomingCalls[uuid] else { return }
            if existing.reportedToCallKit {
                self.performEndCallAction(uuid: uuid, userInitiated: false)
            } else {
                self.clearPendingCall(uuid: uuid)
            }
        }
        pending.timeoutWorkItem = task
        pendingIncomingCalls[uuid] = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: task)
    }

    private func clearPendingCall(uuid: UUID) {
        if var pending = pendingIncomingCalls[uuid] {
            pending.timeoutWorkItem?.cancel()
            pendingIncomingCalls.removeValue(forKey: uuid)
        }
        pendingAnswerCallActions.removeValue(forKey: uuid)
        updateAwaitingCallResponseState()
    }

    private func markCallRetracted(callId: String) {
        retractedCallIds.insert(callId)
        guard let uuid = UUID(uuidString: callId) else { return }
        if let pending = pendingIncomingCalls[uuid] {
            if pending.reportedToCallKit {
                performEndCallAction(uuid: uuid, userInitiated: false)
            } else {
                pendingIncomingCalls[uuid] = pending
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60.0) { [weak self] in
            self?.retractedCallIds.remove(callId)
        }
    }

    private func ensurePendingCall(uuid: UUID, callId: String) -> PendingIncomingCall {
        if var pending = pendingIncomingCalls[uuid] {
            if UUID(uuidString: callId) != nil {
                pending.jmiCallId = callId
            } else if !callId.isEmpty {
                pending.pushCallId = callId
            }
            pendingIncomingCalls[uuid] = pending
            return pending
        }
        let pending = PendingIncomingCall(uuid: uuid, pushCallId: nil, jmiCallId: nil, callerFromPush: nil, callerFromJmi: nil, callType: nil, hasVoipPush: false, hasJmiPropose: false, reportedToCallKit: false, timeoutWorkItem: nil)
        pendingIncomingCalls[uuid] = pending
        schedulePendingTimeout(for: uuid)
        return pending
    }

    private func beginIncomingCallIfReady(uuid: UUID) {
        guard let pending = pendingIncomingCalls[uuid] else { return }
        guard pending.hasVoipPush, pending.hasJmiPropose else { return }
        let callId = pending.jmiCallId ?? ""
        guard !callId.isEmpty else { return }
        guard retractedCallIds.contains(callId) == false else {
            clearPendingCall(uuid: uuid)
            return
        }

        if let action = pendingAnswerCallActions[uuid] {
            pendingAnswerCallActions.removeValue(forKey: uuid)
            self.unconnectedAnswerCallAction = action
            self.waitingToAnswerCall = true
        }

        let caller = pending.callerFromJmi ?? pending.callerFromPush ?? ""
        let callerJid = normalizeCallerJid(from: caller)
        let callerJidString = callerJid?.bare ?? caller
        let displayCaller = resolveCallerDisplayName(from: caller)
        if (self.currentCall == nil) {
            self.currentUuid = uuid
            self.lastUuid = uuid //IOSM-569
            let call = TwilioCall()
            call.callid = callId
            call.caller = callerJidString
            call.callerFullJID = caller
            call.callUuid = uuid
            call.isVoice = false
            call.outgoing = false
            call.isCaller = false

            call.calltitle = displayCaller

            self.currentCall = call
            self.handleJMIPropose(callType: pending.callType ?? .audio)

            DispatchQueue.main.async {
                if let user = callerJid?.user {
                    let sysmsg = "\(ChatRoomMessage.StringConstants.incomingCall.text) - \(Date().formattedAsShortWeekdayTime())"
                    OTRAppDelegate.appDelegate.conversationViewController.addSystemMessage(sysmsg, with: callerJidString, with: user)
                }
            }

            if self.waitingToAnswerCall,
               let answerAction = self.unconnectedAnswerCallAction,
               answerAction.callUUID == uuid {
                //DDLogInfo("***** beginIncomingCallIfReady and was waitingToAnswerCall")
                self.callTimeout?.cancel()
                self.currentCall?.answerCallAction = answerAction
                self.currentCall?.callKitAnswerFulfilled = true
                self.waitingToAnswerCall = false
                self.acceptCall(self.currentCall!)
                self.unconnectedAnswerCallAction = nil
            }
        } else if self.currentCall?.callUuid != uuid {
            //DDLogInfo("***** beginIncomingCallIfReady and already had current call, should be busy?")
            let call = TwilioCall()
            call.callid = callId
            call.caller = callerJidString
            call.callerFullJID = caller
            call.callUuid = uuid
            call.isVoice = false
            call.outgoing = false
            call.isCaller = false
            self.alternateCall = call
        }

        clearPendingCall(uuid: uuid)
    }
    
    //not for use for Twilio voice calls
    public func reportIncomingCallFromNotification(uuid: UUID, callId: String, caller: String, suppressBusy: Bool = false, completion: ((NSError?) -> Void)? = nil) {

        var inOtherCall = false
        let curcall = self.currentCall
        if let calltest = curcall, calltest.callUuid != uuid {
            inOtherCall = true
        } else {
            self.notificationUuid = uuid.uuidString
        }

        let displayCaller = resolveCallerDisplayName(from: caller)
        if retractedCallIds.contains(uuid.uuidString) {
            let callHandle = CXHandle(type: .generic, value: displayCaller)
            let callUpdate = CXCallUpdate()
            callUpdate.remoteHandle = callHandle
            callUpdate.supportsDTMF = false
            callUpdate.supportsHolding = false
            callUpdate.supportsGrouping = false
            callUpdate.supportsUngrouping = false
            callUpdate.hasVideo = false
            self.incomingCallHandle = callHandle
            callKitProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { _ in
                self.performEndCallAction(uuid: uuid, userInitiated: false)
                completion?(nil)
            }
            return
        }

        var pending = ensurePendingCall(uuid: uuid, callId: callId)
        pending.pushCallId = callId
        pending.callerFromPush = caller
        pending.hasVoipPush = true
        pendingIncomingCalls[uuid] = pending
        updateAwaitingCallResponseState()
        
        let callHandle = CXHandle(type: .generic, value: displayCaller)
        let callUpdate = CXCallUpdate()
        callUpdate.remoteHandle = callHandle
        callUpdate.supportsDTMF = false
        callUpdate.supportsHolding = false
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.hasVideo = false
        self.incomingCallHandle = callHandle
        
        if curcall != nil, curcall?.audioOnly == false {
            callUpdate.hasVideo = true
        }
            
        //DDLogInfo("***** reportIncomingCallFromNotification reportNewIncomingCall uuid \(uuid), in other call \(inOtherCall)")
        callKitProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
            if error == nil {
                //DDLogInfo("***** Incoming call successfully reported.")
                
                if inOtherCall && !suppressBusy {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.handleBusy(uuid: uuid, busyId: callId, isVoice: false)
                    }
                }
            } else {
                DDLogInfo("Failed to report incoming call successfully: \(String(describing: error?.localizedDescription)).")
            }
            if var updated = self.pendingIncomingCalls[uuid] {
                updated.reportedToCallKit = true
                self.pendingIncomingCalls[uuid] = updated
                let retracted = self.retractedCallIds.contains(updated.jmiCallId ?? "") || self.retractedCallIds.contains(uuid.uuidString)
                if retracted {
                    self.performEndCallAction(uuid: uuid, userInitiated: false)
                } else {
                    self.beginIncomingCallIfReady(uuid: uuid)
                }
            }
            completion?(error as NSError?)
        }

        if (!inOtherCall) {
            schedulePendingTimeout(for: uuid)
        }
    }
    
    func handleJMIPropose(uuid: UUID, callId: String, caller: String, callType: CallType) {
        //DDLogInfo("***** handleJMIPropose with uuid \(uuid.uuidString)")
        if retractedCallIds.contains(callId) {
            DDLogInfo("***** handleJMIPropose returning because call was retracted")
            return
        }

        var pending = ensurePendingCall(uuid: uuid, callId: callId)
        pending.jmiCallId = callId
        pending.callerFromJmi = caller
        pending.callType = callType
        pending.hasJmiPropose = true
        pendingIncomingCalls[uuid] = pending
        updateAwaitingCallResponseState()
        beginIncomingCallIfReady(uuid: uuid)
    }

    public func reportIncomingCall(uuid: UUID, callId: String, caller: String, isVoice: Bool, completion: ((NSError?) -> Void)? = nil) {
        
        var inCall = false
        var calltitle = caller
        if (self.currentCall == nil) {
            self.currentUuid = uuid
            self.lastUuid = uuid //IOSM-569
            let call = TwilioCall()
            call.callid = callId
            call.caller = caller
            call.callUuid = uuid
            call.isVoice = isVoice
            call.outgoing = false
            call.isCaller = false
            
            //print("***** reportIncomingCall about to getMAtchingContact for \(caller)")
            if isVoice, let contact = TwilioBackendManager.sharedMgr().getMatchingContact(caller) {
                call.calltitle = contact.name
                call.contact = contact
            }
            calltitle = call.calltitle ?? caller
            
            self.currentCall = call
            self.awaitingCallResponse = true
            
        } else { //call exists
            //DDLogInfo("***** we think we have current call, should be busy?")
            inCall = true
        }
            
        let callHandle = CXHandle(type: .generic, value: calltitle)
            
        let callUpdate = CXCallUpdate()
        callUpdate.remoteHandle = callHandle
        callUpdate.supportsDTMF = isVoice
        callUpdate.supportsHolding = isVoice
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.hasVideo = false
            
        //DDLogInfo("***** reportIncomingCall reportNewIncomingCall")
        callKitProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
            if error == nil {
                DDLogInfo("***** Incoming call successfully reported.")
            } else {
                DDLogInfo("***** Failed to report incoming call successfully: \(String(describing: error?.localizedDescription)).")
            }
                
            completion?(error as NSError?)
        }
        
        if (!inCall) {
            let task = DispatchWorkItem { self.performTimeout() }
            callTimeout = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: callTimeout!)
        }
    }
    
    func handleJMIPropose(callType: CallType) {
        self.currentCall?.callstatus = .waiting
        let iceServers = self.createIceServers()
        let audioOnly = (callType == .audio)
        self.currentCall?.audioOnly = audioOnly
        
        if audioOnly == false {
            if let _ = self.getNewUnconnectedCall(), let curcall = self.currentCall, let uuid = curcall.callUuid, let title = curcall.calltitle {
                DispatchQueue.main.async {
                    let callHandle = CXHandle(type: .generic, value: title)
                    let callUpdate = CXCallUpdate()
                    callUpdate.remoteHandle = callHandle
                    callUpdate.supportsDTMF = false
                    callUpdate.supportsHolding = false
                    callUpdate.supportsGrouping = false
                    callUpdate.supportsUngrouping = false
                    callUpdate.hasVideo = true
                    self.callKitProvider.reportCall(with: uuid, updated: callUpdate)
                }
            }
        }
        
        let webClient = WebRTCClient(iceServers: iceServers, audioOnly: audioOnly, forceRelay: false)
        webClient.delegate = self
        self.currentCall?.webrtcClient = webClient
            
        //For jingle call we need to send ringing response. Needs to be logged in
        self.sendJmiRinging()
    }
    
    //IOSM-569
    @objc public func reportMAMCallResponse(callId: String, status: String, completion: ((NSError?) -> Void)? = nil) {
        
        let caller = self.currentCall?.caller ?? "caller"
        let lastuuid = self.lastUuid ?? UUID()
        let uuid = self.currentCall?.callUuid ?? lastuuid
        
        let callHandle = CXHandle(type: .generic, value: caller)
        

        let callUpdate = CXCallUpdate()
        callUpdate.remoteHandle = callHandle
        callUpdate.supportsDTMF = false
        callUpdate.supportsHolding = false
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.hasVideo = false
        //DDLogInfo("***** reportNewIncomingCall Report MAM Call Response")

        callKitProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
            if status == "accept" {
                self.awaitingCallResponse = false
            }
            
            if error == nil {
                DDLogInfo("Incoming call successfully reported.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.performEndCallAction(uuid: uuid, userInitiated: false)
                }
            } else {
                DDLogInfo("Failed to report incoming call successfully: \(String(describing: error?.localizedDescription)).")
                self.performEndCallAction(uuid: uuid, userInitiated: false)
            }
            
            completion?(error as NSError?)
        }
    }
    
    private func performTimeout() {
        if (self.awaitingCallResponse || self.waitingToAnswerCall) {
            if !pendingAnswerCallActions.isEmpty {
                let pendingActions = pendingAnswerCallActions
                pendingAnswerCallActions.removeAll()
                for (uuid, action) in pendingActions {
                    action.fail()
                    performEndCallAction(uuid: uuid, userInitiated: false)
                }
            } else if let callAction = self.unconnectedAnswerCallAction {
                callAction.fail()
                //alert user
            }
            
            if let uuid = self.currentUuid {
                self.performEndCallAction(uuid: uuid, userInitiated: false)
            }
            self.unconnectedAnswerCallAction = nil
        }
    }
    
    @objc public func reportCallAccepted() {
        //might need to match up uuid or something with current call from notification
        if let tcall = self.currentCall {
            DispatchQueue.main.async {
                OTRAppDelegate.appDelegate.conversationViewController.connectVideoCall(tcall)
            }
        }
    }
    
    //ALF IOSM-503
    @objc public func reportCallAccepted(_ from:String, callid:String, deviceid:String) {
        //might need to match up uuid or something with current call from notification
        if let tcall = self.currentCall { //}, let acct = self.cAccount {
            //set call id?
            self.currentCall?.remoteDeviceId = deviceid
            self.currentCall?.receiver = from
            //createConnectingTimeoutTimer
            self.prepareSessionInitiate(from, callId: callid, deviceId: deviceid)
            
            //ALF IOSM-503 check if this particular call is already in progress. If so
            //this is likely a group call and I don't need to handle it here
            if tcall.status == "inprogress" || tcall.status == "accept", callid == tcall.callid {
                return
            }
            self.currentCall?.status = "accept"
            
            DispatchQueue.main.async {
                OTRAppDelegate.appDelegate.conversationViewController.connectVideoCall(tcall)
            }
        }
    }
    
    /*
     <iq from='romeo@montague.example/orchard'
         id='ih28sx61'
         to='juliet@capulet.example/phone'
         type='set'>
     <jingle xmlns='urn:xmpp:jingle:1'
               action='session-initiate'
               initiator='romeo@montague.example/orchard'
               sid='ca3cf894-5325-482f-a412-a6e9f832298d'>
         <content creator='initiator' name='voice'>
           <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>
             <payload-type id='96' name='speex' clockrate='16000'/>
             <payload-type id='97' name='speex' clockrate='8000'/>
             ...
     */
    private func prepareSessionInitiate(_ to:String, callId:String, deviceId:String) {
        //offerSDP
        self.performBlock(async: true){
            guard let myjid = self.xmppStream?.myJID?.full, let call = self.currentCall, let tojid = XMPPJID(string: to), let webClient = call.webrtcClient else { return }
            
            guard let acct = self.cAccount, let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: acct) else { return }
            
            webClient.offer(completion: { (sdp) in
                //DDLogDebug("***** WebRTC offer completion")
                //print("***** Offer SDP: \(sdp.sdp)")
                self.currentCall?.localSDP = sdp.sdp
                
                if let bundle = xmpp.omemoSignalCoordinator?.fetchMyBundle() {
                    let mediaDescriptions = JingleUtility.parseSDP(sdp.sdp)
                    self.currentCall?.localMedia = mediaDescriptions
                    if mediaDescriptions.count > 0, let media = mediaDescriptions.first, let fingerprint = media.fingerprint {
                        //let senderDeviceId = NSNumber(value: bundle.deviceId)
                        if let encryptedElement = xmpp.omemoSignalCoordinator?.getPayloadForCall(fingerprint, buddyjid: tojid.bare, deviceId: deviceId, senderDeviceId: bundle.deviceId) {
                            var encryptedVideoElement:XMLElement?
                            if mediaDescriptions.count > 1 {
                                encryptedVideoElement = xmpp.omemoSignalCoordinator?.getPayloadForCall(fingerprint, buddyjid: tojid.bare, deviceId: deviceId, senderDeviceId: bundle.deviceId)
                            }
                            
                            let jingleElement = JingleUtility.generateJingle(from: sdp.sdp, jingleType:.sessioninitiate, initiator: myjid, responder:nil, sessionID: callId, encryptedAudioElement: encryptedElement, encryptedVideoElement: encryptedVideoElement)
                            //print("***** \(jingleElement)")
                            //print("***** LocalSdp: \(localSDP)")
                            
                            let iq = XMPPIQ.init(iqType: XMPPIQ.IQType.set, to: tojid, elementID: callId, child: jingleElement)
                            iq.addAttribute(withName: "from", stringValue: myjid)
                            self.currentCall?.callstatus = .connecting
                            self.sendXmppElement(iq)
                            return
                        }
                    }
                }
                
                self.sendJmiRetract(call)
                if let cuid = call.callUuid {
                    self.performEndCallAction(uuid: cuid, userInitiated: false)
                }
            })
        }
    }
    
    /*
     <jingle xmlns='urn:xmpp:jingle:1'
               action='session-accept'
               initiator='romeo@montague.lit/orchard'
               responder='juliet@capulet.lit/balcony'
               sid='a73sjjvkla37jfea'>
     */
    private func prepareSessionAnswer(_ to:XMPPJID, sdp:String) {
        self.performBlock(async: true){
            //DDLogInfo("***** prepareSessionAnswer")
            guard let myjid = self.xmppStream?.myJID?.full, let call = self.currentCall, let rid = call.remoteDeviceId else { return }
            
            guard let acct = self.cAccount, let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: acct) else { return }
            
            if let bundle = xmpp.omemoSignalCoordinator?.fetchMyBundle() {
                let mediaDescriptions = JingleUtility.parseSDP(sdp)
                self.currentCall?.localMedia = mediaDescriptions
                if mediaDescriptions.count > 0, let media = mediaDescriptions.first, let fingerprint = media.fingerprint {
                    //let senderDeviceId = NSNumber(value: bundle.deviceId)
                    //need remote deviceId, should be in initiate? or previous messaging?
                    
                    //NEED TO RUN GET PAYLOAD FOR CALL TWICE IF WE HAVE VIDEO AND AUDIO
                    
                    if let encryptedElement = xmpp.omemoSignalCoordinator?.getPayloadForCall(fingerprint, buddyjid: to.bare, deviceId: rid, senderDeviceId: bundle.deviceId), let callid = call.callid {
                        var encryptedVideoElement:XMLElement?
                        if mediaDescriptions.count > 1 {
                            encryptedVideoElement = xmpp.omemoSignalCoordinator?.getPayloadForCall(fingerprint, buddyjid: to.bare, deviceId: rid, senderDeviceId: bundle.deviceId)
                        }
                        
                        let jingleElement = JingleUtility.generateJingle(from: sdp, jingleType:.sessionanswer, initiator: to.full, responder: myjid, sessionID: callid, encryptedAudioElement: encryptedElement, encryptedVideoElement: encryptedVideoElement)
                        //print("***** \(jingleElement)")
                        
                        let iq = XMPPIQ.init(iqType: XMPPIQ.IQType.set, to: to, elementID: callid, child: jingleElement)
                        iq.addAttribute(withName: "from", stringValue: myjid)
                        self.sendXmppElement(iq)
                        
                        self.processIncomingCandidates(nil)
                        
                        if let ufrag = media.iceUfrag, let pwd = media.icePwd, call.iceCandidates.count > 0 {
                            
                            let transportInfo = JingleUtility.generateTransportInfo(candidates: call.iceCandidates, ufrag: ufrag, pwd: pwd, initiator: to.full, responder: myjid, sessionID: callid)
                            let tiq = XMPPIQ.init(iqType: XMPPIQ.IQType.set, to: to, elementID: callid, child: transportInfo)
                            tiq.addAttribute(withName: "from", stringValue: myjid)
                            //DDLogInfo("***** prepareSessionAnswer sending transportInfo: \(transportInfo)")
                            self.sendXmppElement(tiq)
                        }
                        return
                    }
                }
            }
            
            self.sendJmiReject(call, busy: false)
            if let cuid = call.callUuid {
                self.performEndCallAction(uuid: cuid, userInitiated: false)
            }
        }
    }
    
    func sendVideoUpgradeOffer() {
        guard let call = self.currentCall, let deviceId = call.remoteDeviceId, let callId = call.callid, let webClient = call.webrtcClient else { return }
        
        var to = call.caller
        if call.isCaller {
            to = call.receiver
        }
        
        guard let tostr = to, let tojid = XMPPJID(string: tostr), let acct = self.cAccount, let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: acct) else { return }
        
        self.performBlock(async: true){
            webClient.upgradeToVideoOffer(isCaller: call.isCaller, completion: { (sdp) in
                DDLogDebug("WebRTC upgrade to video offer completion")
                //print("***** SDP received for upgrade offer: \(sdp.sdp)")
                self.currentCall?.localSDP = sdp.sdp
                
                if let bundle = xmpp.omemoSignalCoordinator?.fetchMyBundle() {
                    let mediaDescriptions = JingleUtility.parseSDP(sdp.sdp)
                    self.currentCall?.localMedia = mediaDescriptions
                    if mediaDescriptions.count > 0, let media = mediaDescriptions.first, let fingerprint = media.fingerprint {
                        
                        //let senderDeviceId = NSNumber(value: bundle.deviceId)
                        if let encryptedElement = xmpp.omemoSignalCoordinator?.getPayloadForCall(fingerprint, buddyjid: tojid.bare, deviceId: deviceId, senderDeviceId: bundle.deviceId), let myjid = self.xmppStream?.myJID?.full {
                            var encryptedVideoElement:XMLElement?
                            if mediaDescriptions.count > 1 {
                                encryptedVideoElement = xmpp.omemoSignalCoordinator?.getPayloadForCall(fingerprint, buddyjid: tojid.bare, deviceId: deviceId, senderDeviceId: bundle.deviceId)
                            }
                            
                            //No need for local media I think, just remove audio content
                            let jingleElement = JingleUtility.generateJingle(from: sdp.sdp, jingleType:.contentadd, initiator: myjid, responder:nil, sessionID: callId, encryptedAudioElement: encryptedElement, encryptedVideoElement: encryptedVideoElement)
                            //print("***** \(jingleElement)")
                            //print("***** Local: \(localSDP)")
                            
                            let iq = XMPPIQ.init(iqType: XMPPIQ.IQType.set, to: tojid, elementID: callId, child: jingleElement)
                            iq.addAttribute(withName: "from", stringValue: myjid)
                            //self.currentCall?.callstatus = .connecting
                            self.sendXmppElement(iq)
                            return
                            
                            //maybe set a flag that I'm waiting for content accept
                        }
                    }
                }
            })
        }
    }
    
    func sendContentReject(_ to:XMPPJID) {
        self.performBlock(async: true){
            guard let myjid = self.xmppStream?.myJID?.full, let call = self.currentCall, let callId = call.callid else {
                return
            }
            
            let jingleElement = JingleUtility.generateContentReject(initiator: myjid, sessionID: callId)
            
            let iq = XMPPIQ.init(iqType: XMPPIQ.IQType.set, to: to, elementID: callId, child: jingleElement)
            iq.addAttribute(withName: "from", stringValue: myjid)
            self.sendXmppElement(iq)
        }
    }
    
    func sendVideoUpgradeResponse(_ to:XMPPJID) {
        self.performBlock(async: true){
            guard let myjid = self.xmppStream?.myJID?.full, let call = self.currentCall, let deviceId = call.remoteDeviceId, let callId = call.callid, let webClient = call.webrtcClient else {
                return
            }
        
            guard let acct = self.cAccount, let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: acct) else {
                return
            }
            
            //do the receommnded
        
            webClient.upgradeToVideoAnswer(isCaller: call.isCaller, completion: { (sdp) in
                DDLogDebug("WebRTC upgrade to video answer completion")
                //print("***** SDP received after upgrade answer: \(sdp.sdp)")
                let realsdp = sdp.sdp
                self.currentCall?.localSDP = realsdp
                self.currentCall?.audioOnly = false
                
                if let bundle = xmpp.omemoSignalCoordinator?.fetchMyBundle() {
                    let mediaDescriptions = JingleUtility.parseSDP(realsdp)
                    self.currentCall?.localMedia = mediaDescriptions
                    if mediaDescriptions.count > 0, let media = mediaDescriptions.first, let fingerprint = media.fingerprint {
                        //let senderDeviceId = NSNumber(value: bundle.deviceId)
                        if let encryptedElement = xmpp.omemoSignalCoordinator?.getPayloadForCall(fingerprint, buddyjid: to.bare, deviceId: deviceId, senderDeviceId: bundle.deviceId) {
                            var encryptedVideoElement:XMLElement?
                            if mediaDescriptions.count > 1 {
                                encryptedVideoElement = xmpp.omemoSignalCoordinator?.getPayloadForCall(fingerprint, buddyjid: to.bare, deviceId: deviceId, senderDeviceId: bundle.deviceId)
                            }
                            
                            //No need for local media I think, just remove audio content
                            let jingleElement = JingleUtility.generateJingle(from: sdp.sdp, jingleType:.contentaccept, initiator: myjid, responder:nil, sessionID: callId, encryptedAudioElement: encryptedElement, encryptedVideoElement: encryptedVideoElement)
                            //print("***** sendVideoUpgradeResponse \(jingleElement)")
                            //print("***** sendVideoUpgradeResponse Local: \(realsdp)")
                            
                            let iq = XMPPIQ.init(iqType: XMPPIQ.IQType.set, to: to, elementID: callId, child: jingleElement)
                            iq.addAttribute(withName: "from", stringValue: myjid)
                            //self.currentCall?.callstatus = .connecting
                            self.sendXmppElement(iq)
                            //start video?
                            return
                            
                        }
                    }
                }
            })
        }
    }
    
    /*
     <iq from='juliet@capulet.lit/balcony'
         id='ws71bf94'
         to='romeo@montague.lit/orchard'
         type='set'>
       <jingle xmlns='urn:xmpp:jingle:1'
               action='session-terminate'
               initiator='romeo@montague.lit/orchard'
               sid='a73sjjvkla37jfea'>
         <reason>
           <success/>
           <text>Sorry, gotta go!</text>
         </reason>
       </jingle>
     </iq>
     */
    func sendSessionTerminate(_ call:TwilioCall, to:XMPPJID) {
        //make sure this is called from asyncBlock
        //self.performBlock(async: true){
        guard let myjid = self.xmppStream?.myJID?.full, let callid = call.callid else {
            //DDLogInfo("***** sendSessionTerminate but returning early")
            return
        }
        
        /*var initiator = myjid
        if call.isCaller == false {
            initiator = to.full
        }*/
        
        //DDLogDebug("***** sendSessionTerminate")
        
        let jingleElement = XMLElement(name: "jingle", xmlns: JingleUtility.JINGLE)
        jingleElement.addAttribute(withName: "action", stringValue: "session-terminate")
        //jingleElement.addAttribute(withName: "initiator", stringValue: initiator)
        jingleElement.addAttribute(withName: "sid", stringValue: callid)
            
        let reason = XMLElement(name: "reason")
        let success = XMLElement(name: "success")
        let text = XMLElement(name: "text", stringValue: "Ended call")
        reason.addChild(success)
        reason.addChild(text)
        jingleElement.addChild(reason)
            
        let iq = XMPPIQ.init(iqType: XMPPIQ.IQType.set, to: to, elementID: self.xmppStream?.generateUUID, child: jingleElement)
        iq.addAttribute(withName: "from", stringValue: myjid)
        self.currentCall?.callstatus = .disconnected
        self.sendXmppElement(iq)
        //DDLogInfo("***** sendSessionTerminate done")
        //}
    }
    
    func processIncomingCandidates(_ candidates: [String: [String]]?) {
        guard let call = self.currentCall, let remoteCandidates = (candidates ?? self.currentCall?.remoteIceCandidates) else {
            return
        }
        //print("***** processIncomingCandidates")
        
        for mediaType in remoteCandidates.keys {
            let candidateAr = remoteCandidates[mediaType] ?? []
            for candidate in candidateAr {
                //print("***** processIncomingCandidates remote candidate: \(candidate)")
                let rtcCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: 0, sdpMid: mediaType)
                call.webrtcClient?.setRemoteCandidate(rtcCandidate, completion: { (error) in
                    if let error = error {
                        print("***** processIncomingCandidates \(error)")
                        //handle error
                    } else {
                        //success
                    }
                })
            }
        }
    }
        
    
    @objc public func reportCallRejected(_ from:XMPPJID, callid:String) {
        // if in room, no reason to close call here.
        // handles the case of a second phone also waiting
        if let tdel = gcdelegate {
            if (!tdel.isConnected()) {
                if let uuid = self.currentUuid {
                    //IOSM-545 if group call just let caller hang up if needed
                    if self.currentCall?.isGroup == true {
                        /*if let title = self.currentCall?.calltitle { //IOSM-527b
                            sendJoinMessage(from, callid: callid, calltitle: title)
                        }*/
                        return
                    }
                    
                    guard let url = Bundle.main.url(forResource: "MarimbaFailed", withExtension: "wav") else { return }
                    playSound(soundUrl: url)
                    performEndCallAction(uuid: uuid, userInitiated: false)
                }
            } else if self.currentCall?.isGroup == true, let title = self.currentCall?.calltitle {
                //sendJoinMessage(from, callid: callid, calltitle: title) //IOSM-527b
            }
        }
    }
    
    //IOSM-527b
    private func sendJoinMessage(_ to:XMPPJID, callid:String, calltitle:String) {
        self.performBlock(async: true){
            let updateElement = XMLElement(name: "x", xmlns: "jabber:x:callupdate")
            updateElement.addAttribute(withName: "callstatus", stringValue: "joincall")
            updateElement.addAttribute(withName: "callid", stringValue: callid)
            updateElement.addAttribute(withName: "calltitle", stringValue: calltitle)
        
            let xmppMessage = XMPPMessage(messageType: nil, to: to, elementID: UUID().uuidString, child: updateElement)
        
            self.xmppStream?.send(xmppMessage)
        }
    }
    
    @objc public func reportCallBusy() {
        DDLogDebug("reportCallBusy")
        if (self.busyTone == true) {
            //DDLogDebug("reportCallBusy already active with busy Tone")
            return //busy already in progress
        }
        
        guard let soundUrl = Bundle.main.url(forResource: "BusySignal", withExtension: "mp3") else { return }
        do {
            player = try AVAudioPlayer(contentsOf: soundUrl, fileTypeHint: AVFileType.mp3.rawValue)
            player?.numberOfLoops = 2
        } catch _ {
            return // if it doesn't exist, don't play it
        }

        guard let player = player else { return }

        player.play()
        self.busyTone = true
        gcdelegate?.setStatus("Busy")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if let uuid = self.currentUuid, self.busyTone {
                self.performEndCallAction(uuid: uuid, userInitiated: false) //not actually true but needed here
            }
        }
    }
    
    func playSound(soundUrl: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: soundUrl, fileTypeHint: AVFileType.wav.rawValue)
        } catch _ {
            return // if it doesn't exist, don't play it
        }

        guard let player = player else { return }

        player.play()
    }
    
    func stopSound() {
        self.busyTone = false
        guard let player = player else { return }
        player.stop()
    }
    
    @objc public func reportCallCancelled() {
        if let uuid = self.currentUuid {
            performEndCallAction(uuid: uuid, userInitiated: false)
        } else {
            //no uuid so just cancel everything?
            //DDLogInfo("***** reportCallCancelled no uuid")
        }
    }
    
    //IOSM-527b (next 4)
    @objc public func reportCallEnded() { //non call originators
        callToJoin = nil
        self.statusDelegate?.joinStatusUpdated(false)
        //if whatever, change join call to missed call?
    }
    
    @objc public func reportCallJoinRequest(callid:String, calltitle:String) { //non call originators, should have call details
        callToJoin = calltitle
        self.statusDelegate?.joinStatusUpdated(true)
    }
    
    @objc public func getCallToJoin() -> String? { //non call originators
        return callToJoin
    }
    
    func performSendJoinAction(callid:String, calltitle:String) { //call originator
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { //if still connected after 3 seconds
            if let curcall = self.currentCall, curcall.isCaller {
                //send join message. but to who? Original group or only one person? Much easier to send to group.
                if let names = self.currentCall?.receiver?.components(separatedBy: ",") {
                    for rec in names {
                        if let jid = XMPPJID(string: rec) {
                            self.sendJoinMessage(jid, callid: callid, calltitle: calltitle)
                        }
                    }
                }
            }
        }
    }
    
    func performCancelCallAction(userInitiated: Bool) {
        if let uuid = self.currentUuid {
            if let tcall = self.currentCall {
                if (userInitiated && !self.busyTone) { 
                    self.cancelCall(tcall)
                }
            }
            performEndCallAction(uuid: uuid, userInitiated: userInitiated)
        }
    }

    func performEndCallAction(uuid: UUID, userInitiated: Bool) {
        self.endedCall = true
        clearPendingCall(uuid: uuid)
        if let tcall = self.currentCall, userInitiated, !self.busyTone {
            self.cancelCall(tcall)
        }

        // If the call ended without user interaction and never connected,
        // treat it as a missed call so it surfaces in the conversation list
        // and triggers a notification for the receiver.
        if !userInitiated, let missedCall = self.currentCall, missedCall.callstatus == .retracted {
            DispatchQueue.main.async {
                let sysmsg = "\(ChatRoomMessage.StringConstants.missedCall.text) - \(Date().formattedAsShortWeekdayTime())"
                if missedCall.isGroup {
                    if let title = missedCall.calltitle {
                        OTRAppDelegate.appDelegate.conversationViewController.addSystemGroupMessage(sysmsg, with: title)
                    }
                } else if let caller = missedCall.caller, missedCall.outgoing == false {
                    let user = XMPPJID(string: caller)?.user ?? caller
                    OTRAppDelegate.appDelegate.conversationViewController.addSystemMessage(sysmsg, with: caller, with: user)
                }
            }
        }

        let isVoice = self.currentCall?.isVoice ?? false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.stopSound()
            if isVoice {
                TwilioBackendManager.sharedMgr().queryCallHistory(4)
            }
        }
        //DDLogInfo("***** performEndCallAction with \(uuid) and userInitiated \(userInitiated)")
        userInitiatedDisconnect = userInitiated
        
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)

        callKitCallController.request(transaction) { error in
            if let error = error {
                DDLogInfo("EndCallAction transaction request failed: \(error.localizedDescription).")
                return
            }

            //DDLogInfo("EndCallAction transaction request successful")
        }
    }
    
    func handleBusy(uuid: UUID, busyId: String, isVoice: Bool) {
        self.isBusy = true
        self.busyId = busyId
        self.hasIncomingVoiceCall = isVoice
        self.endedCall = true
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)

        callKitCallController.request(transaction) { error in
            if let error = error {
                DDLogInfo("EndCallAction transaction request failed: \(error.localizedDescription).")
                return
            }

            //DDLogInfo("EndCallAction transaction request successful")
        }
    }
    
    func reportCallDisconnected(uuid: UUID, error: Error?) {
        //ALF IOSM-515
        self.isBusy = false
        self.busyTone = false
        
        if !userInitiatedDisconnect { //}, let error = error {
            var reason = CXCallEndedReason.remoteEnded

            if error != nil {
                reason = .failed
            }

            self.callKitProvider.reportCall(with: uuid, endedAt: nil, reason: reason)
        }
        
        self.awaitingCallResponse = false
        self.waitingToAnswerCall = false
        self.currentUuid = nil
        self.notificationUuid = nil
        self.currentCall = nil
        self.alternateCall = nil
        self.activeCall = nil
        self.userInitiatedDisconnect = false
    }
    
    @objc public func reportCallConnected(uuid: UUID?, connectTime: Date) {
        self.stopSound()
        
        self.currentCall?.status = "inprogress" //ALF IOSM-503
        
        let cxObserver = callKitCallController.callObserver
        let calls = cxObserver.calls
        if let call = calls.first(where:{$0.uuid == uuid}) {
            if call.isOutgoing {
                if let calluuid = uuid {
                    self.callKitProvider.reportOutgoingCall(with: calluuid, connectedAt: connectTime)
                } else if let myuuid = self.currentUuid {
                    self.callKitProvider.reportOutgoingCall(with: myuuid, connectedAt: connectTime)
                }
            }
        }
        
        checkAudioPermissions()
    }
    
    @objc public func checkAudioPermissions() -> Bool {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .denied:
            gcdelegate?.handleAudioDenied()
            return true
        case .undetermined:
            gcdelegate?.handleAudioDenied()
            return true
        case .granted: break
        default:
            break
        }
        
        return false
    }
    
    // true means it still needs authorization
    @objc public func checkVideoPermissions() -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            return true
        }
        
        return false
    }
    
    @objc public func performMuteAction(uuid: UUID, isMuted: Bool) {
        let muteAction = CXSetMutedCallAction(call: uuid, muted: isMuted)
        let transaction = CXTransaction(action: muteAction)

        callKitCallController.request(transaction)  { error in
            DispatchQueue.main.async {
                if let error = error {
                    DDLogError("SetMutedCallAction transaction request failed: \(error.localizedDescription)")
                    return
                }
                //DDLogInfo("SetMutedCallAction transaction request successful")
            }
        }
    }
    
    @objc public func performSpeakerAction(isSelected: Bool) {
        if let curcall = self.currentCall, let webClient = curcall.webrtcClient, curcall.isVoice == false {
            if isSelected {
                webClient.turnSpeakerOn()
            } else {
                webClient.turnSpeakerOff()
            }
            return
        }
        
        speakerChoice = isSelected ? .speaker : .receiver
        //self.tvoaudioDevice.block = {
            do {
                let audioSession = AVAudioSession.sharedInstance()
                
                if(isSelected) {
                    try audioSession.setMode(.videoChat)
                    if (self.bluetoothAvailable) {
                        try audioSession.overrideOutputAudioPort(AVAudioSession.PortOverride.speaker)
                    }
                } else {
                    try audioSession.setMode(.voiceChat)
                    try audioSession.overrideOutputAudioPort(AVAudioSession.PortOverride.none)
                }
            } catch {
                DDLogInfo("Fail: \(error.localizedDescription)")
            }
        //}
        
        //self.tvoaudioDevice.block()
    }
    
    public func performSpeakerAction(selection: SpeakerChoice) {
        
        let session = AVAudioSession.sharedInstance()
        speakerChoice = selection

        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try session.setPreferredSampleRate(24000)
            try session.setPreferredIOBufferDuration(0.2)
            try session.setActive(true)

            if session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) {
                // Speaker is currently on → turn it off
                try session.overrideOutputAudioPort(.none)
                //speakerButton.setTitle("Speaker Off", for: .normal)
            } else {
                // Speaker is off → turn it on
                try session.overrideOutputAudioPort(.speaker)
                //speakerButton.setTitle("Speaker On", for: .normal)
            }
        } catch {
            print("Failed to toggle speaker: \(error)")
        }
    }
    
    public func isSpeakerMode() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        let currentRoute = audioSession.currentRoute
        let volume = audioSession.outputVolume
                
        // Check if the output route is using the speaker
        for output in currentRoute.outputs {
            if output.portType == .builtInSpeaker {
                return true
            }
        }
        
        return false
    }
    
    @objc public func performVideoAction() {
        if self.currentCall?.audioOnly == true {
            return //won't do upgrade from the CallKit screen
        }
        
        DDLogInfo("Set Video On")
        gcdelegate?.turnOnVideo()
    }
}

extension CallManager {
    
    func tokenReceived(_ token: String) {
        self.callToken = token
        self.registerWithTwilio()
    }
    
    func credentialsUpdated(_ token: Data) {
        self.deviceToken = token
        self.registerWithTwilio()
    }
    
    func registerWithTwilio() {
        guard let accessToken = self.callToken, let deviceToken = self.deviceToken else {
            return
        }
        
        guard (registrationRequired() || UserDefaults.standard.data(forKey: kCachedDeviceToken) != deviceToken) else {  return  }
        
        /*
        * Perform registration if a new device token is detected.
        */
        TwilioVoiceSDK.register(accessToken: accessToken, deviceToken: deviceToken) { error in
            if let error = error {
                DDLogInfo("An error occurred while registering: \(error.localizedDescription)")
            } else {
                DDLogInfo("Successfully registered for VoIP push notifications.")
                    
                // Save the device token after successfully registered.
                UserDefaults.standard.set(deviceToken, forKey: self.kCachedDeviceToken)
                    
                /**
                * The TTL of a registration is 1 year. The TTL for registration for this device/identity
                * pair is reset to 1 year whenever a new registration occurs or a push notification is
                * sent to this device/identity pair.
                */
                UserDefaults.standard.set(Date(), forKey: self.kCachedBindingDate)
            }
        }
    }
    
    /**
    * The TTL of a voip registration is 1 year. The TTL for registration for this device/identity pair is reset to
    * 1 year whenever a new registration occurs or a push notification is sent to this device/identity pair.
    * This method checks if binding exists in UserDefaults, and if half of TTL has been passed then the method
    * will return true, else false.
    */
    func registrationRequired() -> Bool {
        guard
            let lastBindingCreated = UserDefaults.standard.object(forKey: kCachedBindingDate)
        else { return true }
            
        let date = Date()
        var components = DateComponents()
        components.setValue(kRegistrationTTLInDays/2, for: .day)
        let expirationDate = Calendar.current.date(byAdding: components, to: lastBindingCreated as! Date)!

        if expirationDate.compare(date) == ComparisonResult.orderedDescending {
            return false
        }
        return true;
    }
    
    func incomingCallReceived(callInfo: [AnyHashable : Any]) {
        // The Voice SDK will use main queue to invoke `cancelledCallInviteReceived:error:` when delegate queue is not passed
        TwilioVoiceSDK.handleNotification(callInfo, delegate: self, delegateQueue: nil)
    }
    
    func createIceServers() -> [RTCIceServer] {
        let now = Date()
        if let deadline = iceServersRefreshDeadline, now >= deadline {
            iceServers.removeAll()
            iceServersRefreshDeadline = nil
            refreshExternalServices()
        }
        
        if !iceServers.isEmpty,
           iceServersRefreshDeadline == nil || now < (iceServersRefreshDeadline ?? now) {
            return iceServers
        }
        
        //webrtc stuff
        struct RelayKey: Hashable {
            let type: String
            let host: String
            let port: String
            let username: String
            let password: String
        }

        struct RelayEntry {
            var udpUrls: [String]
            var tcpUrls: [String]
            let username: String
            let password: String
        }

        enum IceServerItem {
            case relay(RelayKey)
            case server(RTCIceServer)
        }

        func isLikelyIPAddress(_ host: String) -> Bool {
            if host.contains(":") {
                return true
            }
            let parts = host.split(separator: ".")
            guard parts.count == 4 else {
                return false
            }
            return parts.allSatisfy { part in
                guard let value = Int(part) else {
                    return false
                }
                return value >= 0 && value <= 255
            }
        }

        func preferredTurnsHost(_ host: String, attrs: [AnyHashable: Any]) -> String {
            guard isLikelyIPAddress(host) else {
                return host
            }
            let preferredKeys = ["hostname", "name", "fqdn", "domain"]
            for key in preferredKeys {
                if let value = attrs[key] as? String, !value.isEmpty {
                    return value
                }
            }
            return host
        }

        func formattedHost(_ host: String) -> String {
            if host.contains(":") && !host.hasPrefix("[") && !host.hasSuffix("]") {
                return "[\(host)]"
            }
            return host
        }

        func hostPortString(host: String, port: String) -> String {
            let portComponent = port.isEmpty ? "" : ":\(port)"
            return "\(formattedHost(host))\(portComponent)"
        }

        var servers:[RTCIceServer] = []
        var refreshDeadline: Date?
        var sawExpiredService = false
        var relayEntries: [RelayKey: RelayEntry] = [:]
        var items: [IceServerItem] = []
        if let acct = self.cAccount, let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: acct) {
            if let ext = xmpp.serverCheck.serverCapabilities.discoveredExternalServices {
                for svc in ext {
                    let service = svc as XMLElement
                    let attrs = service.attributesAsDictionary as? [AnyHashable: Any] ?? [:]
                    let host = attrs["host"] as? String ?? ""
                    let type = (attrs["type"] as? String ?? "stun").lowercased()
                    let port = attrs["port"] as? String ?? ""
                    let transport = (attrs["transport"] as? String ?? "").lowercased()
                    let username = attrs["username"] as? String ?? ""
                    let password = attrs["password"] as? String ?? ""
                    let expires = attrs["expires"] as? String
                    
                    if let expires = expires,
                       let expiryDate = parseExternalServiceExpiry(expires, now: now) {
                        if expiryDate <= now {
                            sawExpiredService = true
                            continue
                        }
                        if refreshDeadline == nil || expiryDate < (refreshDeadline ?? expiryDate) {
                            refreshDeadline = expiryDate
                        }
                    }

                    if transport == "tcp" && type != "turns" {
                        continue
                    }
                    
                    if type == "turn" || type == "turns" {
                        let resolvedHost = type == "turns" ? preferredTurnsHost(host, attrs: attrs) : host
                        let relayKey = RelayKey(type: type, host: resolvedHost, port: port, username: username, password: password)
                        if relayEntries[relayKey] == nil {
                            relayEntries[relayKey] = RelayEntry(udpUrls: [], tcpUrls: [], username: username, password: password)
                            items.append(.relay(relayKey))
                        }
                        if type == "turn" {
                            let transportValue = transport.isEmpty ? "udp" : transport
                            let url = "turn:\(hostPortString(host: resolvedHost, port: port))?transport=\(transportValue)"
                            relayEntries[relayKey]?.udpUrls.append(url)
                        } else {
                            let url = "turns:\(hostPortString(host: resolvedHost, port: port))?transport=tcp"
                            relayEntries[relayKey]?.tcpUrls.append(url)
                        }
                        continue
                    }

                    let urlstrs = ["\(type):\(hostPortString(host: host, port: port))"]
                    let rtcServer = RTCIceServer(urlStrings: urlstrs, username: username, credential: password)
                    items.append(.server(rtcServer))
                }
            }
        }
        if sawExpiredService {
            refreshExternalServices()
        }

        for item in items {
            switch item {
            case .server(let rtcServer):
                servers.append(rtcServer)
            case .relay(let key):
                guard let entry = relayEntries[key] else {
                    continue
                }
                let urlStrings = entry.udpUrls + entry.tcpUrls
                if key.type == "turns" {
                    let rtcServer = RTCIceServer(urlStrings: urlStrings, username: entry.username, credential: entry.password, tlsCertPolicy: .insecureNoCheck)
                    servers.append(rtcServer)
                } else {
                    let rtcServer = RTCIceServer(urlStrings: urlStrings, username: entry.username, credential: entry.password)
                    servers.append(rtcServer)
                }
            }
        }
        
        iceServers = servers
        iceServersRefreshDeadline = refreshDeadline
        
        return servers
    }

    private func refreshExternalServices() {
        guard let acct = cAccount,
              let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: acct) else {
            return
        }
        xmpp.serverCheck.serverCapabilities.discoverExternalServices()
    }
    
    private func parseExternalServiceExpiry(_ expires: String, now: Date) -> Date? {
        if let seconds = TimeInterval(expires) {
            return now.addingTimeInterval(seconds)
        }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: expires)
    }
    
    /*
     <message from='romeo@montague.example/orchard'
              to='juliet@capulet.example'
              type='chat'>
       <propose xmlns='urn:xmpp:jingle-message:0' id='ca3cf894-5325-482f-a412-a6e9f832298d'>
         <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'/>
       </propose>
       <store xmlns="urn:xmpp:hints"/>
     </message>
     */
    func sendJmiPropose(audioOnly:Bool) {
        //DDLogInfo("***** Proposing new call via JMI")
        if let call = self.currentCall, let callid = call.callid, let receiver = call.receiver, let tojid = XMPPJID(string: receiver), let fromjid = self.xmppStream?.myJID?.full {
            let proposeElement = XMLElement(name: "propose", xmlns: CallManager.JINGLE_MESSAGE)
            proposeElement.addAttribute(withName: "id", stringValue: callid)
            let audioDesc = XMLElement(name: "description", xmlns: CallManager.JINGLE_APPS_RTP)
            audioDesc.addAttribute(withName: "media", stringValue: "audio")
            proposeElement.addChild(audioDesc)
            if audioOnly == false {
                let videoDesc = XMLElement(name: "description", xmlns: CallManager.JINGLE_APPS_RTP)
                videoDesc.addAttribute(withName: "media", stringValue: "video")
                proposeElement.addChild(videoDesc)
            }
            
            let xmppMessage = XMPPMessage(messageType: .chat, to: tojid, elementID: callid, child: proposeElement)
            xmppMessage.addAttribute(withName: "from", stringValue: fromjid)
            xmppMessage.addStorageHint(.store)
            
            self.xmppStream?.send(xmppMessage)
        }
    }
    
    /*
     <message from='juliet@capulet.example/phone'
              to='romeo@montague.example'
              type='chat'>
       <ringing xmlns='urn:xmpp:jingle-message:0' id='ca3cf894-5325-482f-a412-a6e9f832298d'/>
       <store xmlns="urn:xmpp:hints"/>
     </message>
     */
    public func sendJmiRinging() {
        guard let call = self.currentCall, let callid = call.callid, let callerjid = call.callerFullJID ?? call.caller, let tojid = XMPPJID(string: callerjid) else { return}
        
        self.performBlock(async: true){
            let ringingElement = XMLElement(name: "ringing", xmlns: CallManager.JINGLE_MESSAGE)
            ringingElement.addAttribute(withName: "id", stringValue: callid)
            let xmppMessage = XMPPMessage(messageType: .chat, to: tojid, child: ringingElement)
            if let fromjid = self.xmppStream?.myJID?.full {
                xmppMessage.addAttribute(withName: "from", stringValue: fromjid)
            }
            xmppMessage.addStorageHint(.store)
                    
            self.sendXmppElement(xmppMessage)
        }
    }
}

extension CallManager: NotificationDelegate {
    public func callInviteReceived(callInvite: CallInvite) {
        DDLogDebug("callInviteReceived:")
        
        /**
         * The TTL of a registration is 1 year. The TTL for registration for this device/identity
         * pair is reset to 1 year whenever a new registration occurs or a push notification is
         * sent to this device/identity pair.
         */
        UserDefaults.standard.set(Date(), forKey: kCachedBindingDate)
        
        let callerInfo: TVOCallerInfo = callInvite.callerInfo
        if let verified: NSNumber = callerInfo.verified {
            if verified.boolValue {
                DDLogInfo("***** Call invite received from verified caller number!")
            }
        }
        //DDLogInfo("***** Call invite received with uuid \(callInvite.uuid) and sid \(callInvite.callSid)!")
        
        activeCallInvite = callInvite
        if let from = callInvite.from?.replacingOccurrences(of: "client:", with: "") {
            let callId = callInvite.callSid
            let onCall = (self.currentCall != nil)
            self.reportIncomingCall(uuid: callInvite.uuid, callId: callId, caller: from, isVoice: true) { _ in
                if self.activeCall != nil || onCall {
                    //DDLogInfo("***** ending call from callInviteReceived")
                    self.endedCall = true
                    let endCallAction = CXEndCallAction(call: callInvite.uuid)
                    let transaction = CXTransaction(action: endCallAction)

                    self.callKitCallController.request(transaction) { error in
                        self.callKitProvider.reportCall(with: callInvite.uuid, endedAt: Date(), reason: .answeredElsewhere)
                    }
                }
            }
        }
    }
    
    public func cancelledCallInviteReceived(cancelledCallInvite: CancelledCallInvite, error: Error) {
        DDLogInfo("cancelledCallInviteCanceled:error:, error: \(error.localizedDescription)")
        
        if let callUuid = self.currentCall?.callUuid {
            performEndCallAction(uuid: callUuid, userInitiated: false)
            activeCallInvite = nil
        }
    }
}

extension CallManager: CXCallObserverDelegate {
    public func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        //
    }
    
    // Method to check if there's any active call
    func isCallActive() -> Bool {
        guard let calls = callObserver?.calls else { return false }
        for call in calls {
            if call.hasConnected && !call.hasEnded {
                return true // Call is active
            }
        }
        return false // No active call
    }
    
    func getNewUnconnectedCall() -> CXCall? {
        guard let calls = callObserver?.calls else { return nil }
        for call in calls {
            if !call.hasConnected && !call.hasEnded {
                return call // Call is active
            }
        }
        return nil // No unconnected call
    }
}

extension CallManager: WebRTCClientDelegate {
    func webRTCClient(_ client: WebRTCClient, didDiscoverLocalCandidate candidate: RTCIceCandidate) {
        guard let call = self.currentCall else { return }
                
        if let sdpMid = candidate.sdpMid, let iceCandidate = JingleUtility.parseIceCandidate(candidate.sdp) {
            //print("***** didDiscoverLocalCandidate with mid \(sdpMid) and SDP: \(candidate.sdp)")
            self.syncQueue.sync {
                if var candidates = self.currentCall?.iceCandidates[sdpMid] {
                    candidates.append(iceCandidate)
                    call.iceCandidates[sdpMid] = candidates
                } else {
                    call.iceCandidates[sdpMid] = [iceCandidate]
                }
            }
            
            if call.localSDP == nil || call.remoteSDP == nil {
                return
            }
            
            self.performBlock(async: true){
                guard let myjid = self.xmppStream?.myJID?.full, let media = call.localMedia.first, let ufrag = media.iceUfrag, let pwd = media.icePwd, let callid = call.callid else { return }
                
                var tojidstr = call.receiver
                var initiator = myjid
                var responder = tojidstr
                if call.isCaller == false {
                    tojidstr = call.callerFullJID
                    initiator = tojidstr ?? ""
                    responder = myjid
                }
                let tojid = XMPPJID(string: tojidstr!)
                    
                let transportInfo = JingleUtility.generateTransportInfo(candidates: [sdpMid:[iceCandidate]], ufrag: ufrag, pwd: pwd, initiator: initiator, responder: responder, sessionID: callid)
                let iq = XMPPIQ.init(iqType: XMPPIQ.IQType.set, to: tojid, elementID: self.xmppStream?.generateUUID, child: transportInfo)
                iq.addAttribute(withName: "from", stringValue: myjid)
                //DDLogInfo("***** didDiscoverLocalCandidate sending: \(transportInfo)")
                self.sendXmppElement(iq)
            }
        }
    }
    
    func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState) {
        guard let call = self.currentCall, let uuid = call.callUuid else { return }
        //if call.status == .finished { return}
        
        DDLogDebug("New RTCIceConnectionState \(state)")
        //we *always* want to cancel the running iceRestart timer once the state changes
        //if(self.cancelWaitUntilIceRestart != nil)
            
        switch(state) {
        case .connected, .completed:
            DDLogDebug("***** New WebRTC ICE state: connected")
            self.callTimeout?.cancel()
            self.currentCall?.callstatus = .connected
            self.stopSound()
            
            if call.isCaller == false {
                DDLogInfo("Informing CallKit of successful connection of incoming call...")
                if call.callKitAnswerFulfilled == false {
                    call.answerCallAction?.fulfill(withDateConnected: Date())
                    call.callKitAnswerFulfilled = true
                }
            } else { //otherwise the call was outgoing - we are connected now
                DDLogInfo("Informing CallKit of successful connection of outgoing call...")
                self.callKitProvider.reportOutgoingCall(with: uuid, connectedAt: Date())
                self.checkAudioPermissions()
            }
            self.sendAcks()
            self.notificationUuid = nil
            
            self.webRtcConnectionDelegate?.webRTCCallConnected()
            break
        case .disconnected:
            DDLogDebug("***** New WebRTC ICE state: disconnected")
            if call.isCaller == false, call.callstatus == .connecting, call.callKitAnswerFulfilled == false {
                call.answerCallAction?.fail()
            } else {
                self.gcdelegate?.setStatus("Reconnecting...")
            }
            
            break
        case .failed:
            DDLogDebug("***** New WebRTC ICE state: failed")
            self.callTimeout?.cancel()
            if call.isCaller == false, call.callstatus == .connecting, call.callKitAnswerFulfilled == false {
                call.answerCallAction?.fail()
            }
            if let uid = call.callUuid {
                self.doDisconnect(uid)
            } else {
                self.webRtcConnectionDelegate?.webRTCCallFailed()
            }
            break
        //all following states can be ignored
        case .closed:
            self.webRtcConnectionDelegate?.webRTCCallClosed()
            DDLogDebug("New WebRTC ICE state: closed")
            break
        case .new:
            //DDLogInfo("New WebRTC ICE state: new")
            break
        case .checking:
            //DDLogInfo("New WebRTC ICE state: checking")
            break
        case .count:
            //DDLogInfo("New WebRTC ICE state: count")
            break
        default:
            //DDLogInfo("New WebRTC ICE state: UNKNOWN")
            break
        }
    }
    
    func sendAcks() {
        self.performBlock(async: true){
            if let acct = self.cAccount, let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: acct) {
                xmpp.sendAcknowledgments()
            }
        }
    }
    
    func doDisconnect(_ uuid:UUID) {
        self.performEndCallAction(uuid: uuid, userInitiated: false)
        self.reportCallDisconnected(uuid: uuid, error: nil)
        self.webRtcConnectionDelegate?.webRTCCallDisconnected()
        self.sendAcks()
    }
    
    func webRTCClient(_ client: WebRTCClient, didReceiveData data: Data) {
        //
    }
    
    func webRTCClient(_ client: WebRTCClient, didAddVideo video: Bool) {
        if video == true {
            self.webRtcConnectionDelegate?.webRTCCallVideoAdded()
        }
    }
}
