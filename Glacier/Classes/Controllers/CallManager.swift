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
    //func activateAudio(_ activate: Bool)
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

private enum OutgoingRingbackState {
    /// Waiting for the callee's device to ring.
    case idle
    /// The callee is ringing; waiting for CallKit to activate call audio.
    case pending
    case playing
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
    let kCachedRegisteredIdentity = "CachedRegisteredIdentity"
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
    var hasIncomingVoiceCall:Bool = false
    var audioSession:AVAudioSession?
    
    private var isEndingCurrentCall = false
    private var shouldNullifyAfterTerminate = false
    private var callHold: TwilioCall?
    
    var activeCallInvite:CallInvite?
    var activeCall:Call?
    
    var bluetoothAvailable: Bool = false
    var bluetoothEnabled: Bool = false
    var speakerChoice: SpeakerChoice = SpeakerChoice.receiver
    
    public var callToken:String?
    public var deviceToken:Data?
    
    @objc private weak var gcdelegate:GlacierCallDelegateProtocol? = nil
    private weak var webRtcConnectionDelegate:WebRTCConnectionDelegate? = nil
    
    // CallKit components
    let callKitProvider: CXProvider
    let callKitCallController: CXCallController
    //var callKitCompletionHandler: ((Bool)->Swift.Void?)? = nil
    var userInitiatedDisconnect: Bool = false
    
    var callTimeout: DispatchWorkItem?
    var unconnectedAnswerCallAction: CXAnswerCallAction?
    var player: AVAudioPlayer?
    // Outgoing ringback, main thread only (`makeCall` runs there). `ringbackCallId` is the call
    // allowed to ring back, cleared once it is answered or ends; `wakeCommand` ties the
    // wake-command IQ to its call so a late response can't start ringback for another one.
    private var ringbackCallId: String?
    private var ringbackState = OutgoingRingbackState.idle
    private var wakeCommand: (iqId: String, callId: String)?
    var incomingCallHandle:CXHandle?

    private var callObserver: CXCallObserver?
    private var isObservingAudioRouteChanges: Bool = false

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
    /// Maps the server call id carried by VoIP pushes to the CallKit UUID, so a later
    /// call-status push (which carries only the call id) can find its call.
    private var pushCallIdToUuid: [String: UUID] = [:]

    private func callStatusString(_ status: CallStatus?) -> String {
        guard let status else { return "nil" }
        switch status {
        case .disconnected: return "disconnected"
        case .waiting: return "waiting"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .retracted: return "retracted"
        case .acceptedbyother: return "acceptedbyother"
        case .unknown: return "unknown"
        }
    }

    private func logIncomingState(_ context: String, uuid: UUID? = nil, callId: String? = nil) {
        let call = currentCall
        let callUuid = call?.callUuid?.uuidString ?? "nil"
        let callIdValue = call?.callid ?? "nil"
        let status = callStatusString(call?.callstatus)
        let callKitFulfilled = call?.callKitAnswerFulfilled ?? false
        let isVoice = call?.isVoice ?? false
        let audioOnly = call?.audioOnly ?? false
        let incoming = call?.outgoing == false
        let unconnectedAnswer = (unconnectedAnswerCallAction != nil)
        let pendingIncomingCount = pendingIncomingCalls.count
        let pendingAnswerCount = pendingAnswerCallActions.count

        NSLog(
            "*****DBG IncomingState[%@] uuid=%@ callId=%@ curUuid=%@ curCallId=%@ status=%@ incoming=%d isVoice=%d audioOnly=%d awaiting=%d waitingToAnswer=%d pendingIncoming=%d pendingAnswer=%d unconnectedAnswer=%d callKitFulfilled=%d activeInvite=%d receivedRetract=%d isBusy=%d busyTone=%d",
            context,
            uuid?.uuidString ?? "nil",
            callId ?? "nil",
            callUuid,
            callIdValue,
            status,
            incoming ? 1 : 0,
            isVoice ? 1 : 0,
            audioOnly ? 1 : 0,
            awaitingCallResponse ? 1 : 0,
            waitingToAnswerCall ? 1 : 0,
            pendingIncomingCount,
            pendingAnswerCount,
            unconnectedAnswer ? 1 : 0,
            callKitFulfilled ? 1 : 0,
            activeCallInvite != nil ? 1 : 0,
            receivedRetract ? 1 : 0,
            isBusy ? 1 : 0,
            busyTone ? 1 : 0
        )
    }
    
    var retryMessageList: [XMPPElement] = []
    var retryAcceptCallList: [XMPPElement] = []
    var retryRejectCallList: [XMPPElement] = []
    
    private var proxyDetected: Bool = false
    private struct PendingSystemMessage {
        let message: String
        let callerJidString: String
        let user: String
    }
    private var pendingSystemMessages: [PendingSystemMessage] = []
    private enum PendingCallPresentation {
        case video(title: String)
        case voice(contact: PhoneContact)
    }
    private var pendingCallPresentation: PendingCallPresentation?
    
    /**
     * We will create an audio device and manage it's lifecycle in response to CallKit events.
     */
    var tvoaudioDevice: TwilioVoice.DefaultAudioDevice = TwilioVoice.DefaultAudioDevice()
    
    var iceServers:[RTCIceServer] = []
    private var iceServersRefreshDeadline: Date?
    //var iceCandidates:[RTCIceCandidate] = []
    let syncQueue = DispatchQueue(label: "callManager.syncQueue")

    /// Keeps the process alive across incoming-call setup.
    ///
    /// A VoIP-push wake gives us no process assertion of our own. callservicesd holds one
    /// for the reportNewIncomingCall round-trip and releases it the moment that completes
    /// ("Invalidating process assertion ... from completion handler"). It is supposed to
    /// take a second, call-lifetime assertion to cover the rest — but on a wake from
    /// suspension that request has been observed going out for bundle identifier `(null)`
    /// and never taking effect, with no matching "Acquired initial process assertion" line.
    /// We are then suspended ~100ms after reporting: the call cannot ring, callConnect
    /// cannot tick, the answer cannot be handled, and callservicesd kills us when its own
    /// timeout expires. That is the 0xBAADCA11 termination captured on builds 1208 and
    /// 1218 (incidents C13E2380 and 14C935AA), in both of which every thread was parked —
    /// the app was killed for inaction while suspended, not for being slow.
    ///
    /// So hold our own assertion instead of depending on theirs. This deliberately does
    /// NOT change any CallKit timing or fulfilment semantics; it only buys runtime.
    private var callSetupBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Hard ceiling, so a terminal path we failed to hook cannot leak the assertion.
    private var callSetupBackgroundTaskCeiling: DispatchWorkItem?

    /// Idempotent. Safe to call for a call that already holds the assertion.
    private func beginCallSetupBackgroundTask() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.beginCallSetupBackgroundTask() }
            return
        }
        guard callSetupBackgroundTask == .invalid else { return }

        callSetupBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "incomingCallSetup") { [weak self] in
            // iOS is reclaiming the time. Ending here is mandatory — an unended task is
            // itself a termination reason.
            DDLogInfo("***** callSetupBackgroundTask: expired")
            self?.endCallSetupBackgroundTask()
        }
        guard callSetupBackgroundTask != .invalid else {
            DDLogInfo("***** callSetupBackgroundTask: unavailable")
            return
        }

        // Outlast callConnect's 30s window slightly, so in the normal case the window is
        // what ends first and this is only ever the backstop.
        let ceiling = DispatchWorkItem { [weak self] in
            DDLogInfo("***** callSetupBackgroundTask: ceiling reached")
            self?.endCallSetupBackgroundTask()
        }
        callSetupBackgroundTaskCeiling = ceiling
        DispatchQueue.main.asyncAfter(deadline: .now() + 35.0, execute: ceiling)
        DDLogInfo("***** callSetupBackgroundTask: begin")
    }

    /// Idempotent. Safe to call from any terminal path, more than once.
    private func endCallSetupBackgroundTask() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.endCallSetupBackgroundTask() }
            return
        }
        callSetupBackgroundTaskCeiling?.cancel()
        callSetupBackgroundTaskCeiling = nil

        let task = callSetupBackgroundTask
        guard task != .invalid else { return }
        // Clear before ending so a re-entrant call cannot end the same identifier twice.
        callSetupBackgroundTask = .invalid
        DDLogInfo("***** callSetupBackgroundTask: end")
        UIApplication.shared.endBackgroundTask(task)
    }

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
        
        //NotificationCenter.default.addObserver(self, selector: #selector(handleLoginSuccess), name: NSNotification.Name(rawValue: kGlacierProtocolLoginSuccess), object: nil)
        
        callKitProvider.setDelegate(self, queue: nil)
        callObserver = CXCallObserver()
        callObserver?.setDelegate(self, queue: DispatchQueue.main)

        NotificationCenter.default.addObserver(self, selector: #selector(handleApplicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        
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

    @objc private func handleApplicationDidBecomeActive() {
        flushPendingSystemMessagesIfPossible()
        flushPendingCallPresentationIfPossible()
    }

    private func enqueueSystemMessage(_ message: String, callerJidString: String, user: String) {
        pendingSystemMessages.append(PendingSystemMessage(message: message, callerJidString: callerJidString, user: user))
    }

    private func flushPendingSystemMessagesIfPossible() {
        guard let appDelegate = UIApplication.shared.delegate as? GlacierAppDelegate else { return }
        guard appDelegate.isMainInterfaceReady() else { return }

        let pendingMessages = pendingSystemMessages
        pendingSystemMessages.removeAll()
        pendingMessages.forEach { pending in
            appDelegate.addSystemMessage(pending.message, with: pending.callerJidString, with: pending.user)
        }
    }

    private func postIncomingCallSystemMessage(callerJidString: String, user: String) {
        let message = "\(ChatRoomMessage.StringConstants.incomingCall.text) - \(Date().formattedAsShortWeekdayTime())"
        DispatchQueue.main.async {
            if let appDelegate = UIApplication.shared.delegate as? GlacierAppDelegate, appDelegate.isMainInterfaceReady() {
                appDelegate.addSystemMessage(message, with: callerJidString, with: user)
            } else {
                self.enqueueSystemMessage(message, callerJidString: callerJidString, user: user)
            }
        }
    }

    private func enqueuePendingCallPresentation(_ presentation: PendingCallPresentation) {
        pendingCallPresentation = presentation
    }

    private func flushPendingCallPresentationIfPossible() {
        guard let pending = pendingCallPresentation else { return }
        guard let appDelegate = UIApplication.shared.delegate as? GlacierAppDelegate else { return }
        guard appDelegate.isMainInterfaceReady() else { return }

        pendingCallPresentation = nil
        switch pending {
        case .video(let title):
            appDelegate.openVideoCallController(title)
            if let call = self.currentCall, let callVC = appDelegate.callWindow?.rootViewController?.presentedViewController as? VideoCallViewController {
                callVC.doConnectCall(call, with:title)
            }
        case .voice(let contact):
            appDelegate.openPhoneCallController(contact)
        }
    }
    
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

    private func quickCallerName(from caller: String) -> String {
        let trimmed = caller.trimmingCharacters(in: .whitespacesAndNewlines)
        if let atIndex = trimmed.firstIndex(of: "@") {
            return String(trimmed[trimmed.startIndex..<atIndex])
        }
        return trimmed
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

    public func makeCall(_ receivers: [String], name: String, callType:CallType) -> Bool
    {
        if (self.xmppStream?.isConnected == false) {
            self.handleFailedCall(true)
            return false
        }

        GuardianPermissionManager.shared.request(.localNetwork)
        
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
        self.ringbackCallId = call.callid
        self.ringbackState = .idle
        let wakeIqId = self.xmppStream?.generateUUID ?? UUID().uuidString
        self.wakeCommand = (wakeIqId, call.callid ?? "")
        
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
            //let receiverval = XMLElement(name: "value", stringValue: receiver)
            //receiverfield.addChild(receiverval)
            
            for callbuddy in receivers {
                let receiverval = XMLElement(name: "value", stringValue: callbuddy)
                receiverfield.addChild(receiverval)
            }
            //let titlefield = XMLElement(name: "field")
            //titlefield.addAttribute(withName: "var", stringValue: "titlefield")
            //let titlefieldval = XMLElement(name: "value", stringValue: name)
            //titlefield.addChild(titlefieldval)
            
            //let webrtcIdfield = XMLElement(name: "field")
            //roomfield.addAttribute(withName: "var", stringValue: "roomname")
            //let roomval = XMLElement(name: "value", stringValue: self.currentUuid!.uuidString)
            //roomfield.addChild(roomval)
            
            let webrtcfield = XMLElement(name: "field")
            webrtcfield.addAttribute(withName: "var", stringValue: "webrtcId")
            let webrtcval = XMLElement(name: "value", stringValue: self.currentUuid!.uuidString)
            webrtcfield.addChild(webrtcval)
            
            x.addChild(callerfield)
            x.addChild(callerDisplayNameField)
            x.addChild(devicefield)
            x.addChild(receiverfield)
            //from will provide the caller full jid
            
            //x.addChild(roomfield) //use for uuid to match //token
            x.addChild(webrtcfield)
            //x.addChild(titlefield)
            /*if call.isGroup {
                let groupfield = XMLElement(name: "field")
                groupfield.addAttribute(withName: "var", stringValue: "group")
                let groupval = XMLElement(name: "value", stringValue: "true")
                groupfield.addChild(groupval)
                
                x.addChild(groupfield)
            }*/
            
            command.addChild(x)
            let tojid = XMPPJID(string: "p2." + GlacierInfo.defaultHost())
            let iq = XMPPIQ.init(iqType: XMPPIQ.IQType.set, to: tojid, elementID: wakeIqId, child: command)
            iq.addAttribute(withName: "from", stringValue: from!)
            
            self.tracker?.add(iq, target: self, selector: #selector(self.handleMakeCallResponse(_:)), timeout: 15)
            
            self.xmppStream?.send(iq)
        }
        
        return true
    }
    
    /// `iq` is nil on timeout.
    @objc private func handleMakeCallResponse(_ iq: XMPPIQ?) {
        let x = iq?.childElement?.element(forName: "x", xmlns: "jabber:x:data")
        guard x?.elements(forName: "field") != nil, let iqId = iq?.elementID else {
            //handle failed case, alert user
            performCancelCallAction(userInitiated: false)
                
            self.handleFailedCall(false)
            return
        }
        
        // Fallback for callees that never send JMI `ringing` (Android only sends it with
        // "Confirm messages" on): a push went out, so the callee's phone should be ringing.
        DispatchQueue.main.async {
            guard let wakeCommand = self.wakeCommand, wakeCommand.iqId == iqId else { return }
            self.requestOutgoingRingback(callId: wakeCommand.callId)
        }
    }

    /// Ringback tells the caller the callee's device is ringing, so it starts on the callee's JMI
    /// `ringing` (or the wake-command fallback), not when the call is placed. It plays once
    /// CallKit has activated call audio, and at most once per call.
    func requestOutgoingRingback(callId: String) {
        DispatchQueue.main.async {
            guard self.ringbackCallId == callId, self.ringbackState == .idle else { return }
            self.ringbackState = .pending
            self.startOutgoingRingbackIfReady()
        }
    }

    private func startOutgoingRingbackIfReady() {
        guard ringbackState == .pending, ringbackCallId != nil, audioSession != nil,
              let url = Bundle.main.url(forResource: "outboundring", withExtension: "wav") else { return }
        ringbackState = .playing
        playSound(soundUrl: url)
        player?.numberOfLoops = 3
    }

    /// Called when the call is answered, connects, fails, or ends. Leaves other tones alone.
    func stopOutgoingRingback() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stopOutgoingRingback() }
            return
        }
        ringbackCallId = nil
        ringbackState = .idle
        if player?.url?.lastPathComponent == "outboundring.wav" {
            player?.stop()
        }
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
            // DDLogError("***** Unable to format phone number for dialing")
            return
        }

        var updatedContact = contact
        updatedContact.phoneNumber = callto

        let call = TwilioCall()
        call.receiver = callto
        call.calltitle = contact.name
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
    
    @objc private func handleFailedCall(_ networkDown: Bool) {
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
            if GlacierAppDelegate.appDelegate.isGroupChatController {
                GlacierAppDelegate.appDelegate.chatRoomViewController.present(alert, animated: true, completion: nil)
            } else {
                GlacierAppDelegate.appDelegate.chatViewController.present(alert, animated: true, completion: nil)
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
        //let deviceId = UIDevice.current.identifierForVendor?.uuidString
        // DDLogInfo("***** acceptCall, will send proceed")
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
            call.systemMessage = "Received call"
            let appDelegate = UIApplication.shared.delegate as? GlacierAppDelegate
            if let appDelegate, appDelegate.isMainInterfaceReady() {
                GlacierAppDelegate.appDelegate.connectVideoCall(call)
            } else {
                if let calltitle = GlacierAppDelegate.appDelegate.connectVideoCall(call, readyToPresent: false) {
                    self.enqueuePendingCallPresentation(.video(title: calltitle))
                }
            }
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
        
        guard let acct = self.cAccount, let xmpp = GlacierProtocolManager.shared.xmppManager(forChatAccount: acct), let bundle = xmpp.omemoSignalCoordinator?.fetchMyBundle() else {
            DDLogError("sendJmiProceed: OMEMO bundle unavailable, proceed NOT sent for call \(call.callid ?? "?")")
            return
        }
        
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
            
            if let myBareJid = self.xmppStream?.myJID?.bareJID {
                let acceptElement = XMLElement(name: "accept", xmlns: CallManager.JINGLE_MESSAGE)
                acceptElement.addAttribute(withName: "id", stringValue: callid)
                let acceptMessage = XMPPMessage(messageType: .chat, to: myBareJid, child: acceptElement)
                acceptMessage.addAttribute(withName: "from", stringValue: fromjid)
                acceptMessage.addStorageHint(.store)
                self.sendXmppElement(acceptMessage)
            }
        }
    }

    public func rejectCall(_ call: TwilioCall, busy: Bool) {
        //send JmiReject
        self.sendJmiReject(call, busy: busy)
        self.isBusy = false
        DDLogInfo("*** rejectCall isBusy: \(isBusy)")
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
        // DDLogInfo("***** cancelCall")
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
                    // DDLogInfo("***** cancelCall sending Terminate and JMI Finish")
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
        // DDLogDebug("***** sendJmiRetract ")
        
        if let receivers = call.receiver?.components(separatedBy: ","), let call = self.currentCall, let callerjid = call.caller, let callid = call.callid, let acct = self.cAccount, let acctjid = acct.bareJID, let domain = acct.domain {
            DDLogDebug("sendJmiRetract")
            for receiver in receivers {
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
                    // DDLogInfo("***** Not connected, and proxy detected, so not logging in to send XMPP.")
                    return
                }
                // DDLogInfo("***** Not connected, so login to send XMPP.")
                GlacierProtocolManager.shared.loginAccount(acct)
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
                let xmpp = GlacierProtocolManager.shared.xmppManager(forChatAccount: acct),
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
                                // DDLogInfo("***** handleSessionInitAccept sending immediate transportInfo") //: \(transportInfo)")
                                self.sendXmppElement(tiq)
                            }
                        }
                    })
                }
            }
        } else {
            // DDLogInfo("***** in handleSessionInitAccept fail")
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
                let xmpp = GlacierProtocolManager.shared.xmppManager(forChatAccount: acct),
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
                // DDLogInfo("***** jingle with sid \(iqid)")
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
                    // DDLogInfo("***** received session terminate")
                    if let call = self.currentCall {
                        call.callstatus = .disconnected
                        beginTerminateCurrentCall(reason: "remote-session-terminate")
                        //call.webrtcClient?.terminateSession()
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
        
        if message.containsJmiElements {
            let isSelfBare = (message.from?.bareJID != nil && message.to?.bareJID != nil) ?
            message.from?.bareJID.isEqual(to: message.to!.bareJID) ?? false : false
            if isSelfBare, message.element(forName: "accept", xmlnsPrefix: CallManager.JINGLE_MESSAGE) == nil {
                NSLog("*****DBG JMI is coming to me from me but is not an accept message")
                return
            }
            
            if let accept = message.element(forName: "accept", xmlnsPrefix: CallManager.JINGLE_MESSAGE) {
                NSLog("*****DBG JMI is coming to me from me and is an accept message")
                if !isSelfBare {
                    NSLog("*****DBG JMI but not from bare self")
                    return
                }
                if let fromFull = message.from?.full, let myFull = self.xmppStream?.myJID?.full, fromFull == myFull {
                    NSLog("*****DBG JMI but is same as my full address")
                    return
                }
                
                let callid = accept.attributeStringValue(forName: "id") ?? ""
                if let currentCallId = self.currentCall?.callid, !currentCallId.isEmpty, !callid.isEmpty, currentCallId != callid {
                    DDLogInfo("Ignoring JMI accept for non-current callid \(callid)")
                    return
                }
                if !callid.isEmpty {
                    markCallRetracted(callId: callid)
                }
                self.receivedRetract = true
                self.currentCall?.callstatus = .acceptedbyother
                reportCallCancelled()
                DDLogInfo("Received JMI accept message: \(accept)")
            } else if let propose = message.element(forName: "propose", xmlnsPrefix: CallManager.JINGLE_MESSAGE) {
                //DDLogInfo("***** receive propose")
                //syncQueue.sync {
                    let caller = message.fromStr ?? ""
                    let callid = propose.attributeStringValue(forName: "id") ?? ""

                    if self.currentCall?.callid == callid {
                        return // MAM is doubling up
                    }

                    GuardianPermissionManager.shared.request(.localNetwork)

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
                // The callee's device is ringing.
                if let callid = ringing.attributeStringValue(forName: "id") {
                    requestOutgoingRingback(callId: callid)
                }
                DDLogInfo("Received JMI ringing message: \(ringing)")
            } else if let retract = message.element(forName: "retract", xmlnsPrefix: CallManager.JINGLE_MESSAGE) {
                let callid = retract.attributeStringValue(forName: "id") ?? ""
                if !callid.isEmpty {
                    markCallRetracted(callId: callid)
                }
                self.receivedRetract = true
                self.currentCall?.callstatus = .retracted
                reportCallCancelled()
                // DDLogInfo("***** Received JMI retract message: \(retract)")
            } else if let proceed = message.element(forName: "proceed", xmlns: CallManager.JINGLE_MESSAGE), let callid = proceed.attributeStringValue(forName: "id"), let from = message.from, let device = proceed.element(forName: "device"), let deviceId = device.attributeStringValue(forName: "id") {
                if callid == self.currentCall?.callid {
                    stopOutgoingRingback()
                }
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
    public var calltitle:String?
    public var status:String?
    public var systemMessage:String?
    public var callUuid:UUID?
    public var outgoing:Bool = true
    public var isGroup:Bool = false
    public var isCaller:Bool = false 
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
    case acceptedbyother = 5
    case unknown = 6
}

extension CallManager : CXProviderDelegate {

    public func providerDidReset(_ provider: CXProvider) {
        DDLogInfo("Twilio providerDidReset:")
        self.stopOutgoingRingback()

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
        // Call audio is running: the active call keeps us alive now, so stop borrowing
        // background time.
        endCallSetupBackgroundTask()

        if !isObservingAudioRouteChanges {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(audioRouteChange(_:)),
                name: NSNotification.Name(rawValue: AVAudioSession.routeChangeNotification.rawValue),
                object: nil
            )
            isObservingAudioRouteChanges = true
        }
        
        // DDLogInfo("***** didActivateAudioSession:")
        if let curcall = self.currentCall, curcall.isVoice {
            // DDLogInfo("***** didActivateAudioSession isVoice:")
            self.tvoaudioDevice.isEnabled = true
        } else {
            self.audioSession = audioSession
            self.didActivate(audioSession: audioSession)
            // The callee may have started ringing before CallKit handed over call audio.
            self.startOutgoingRingbackIfReady()
        }
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        DDLogInfo("Twilio provider:didDeactivateAudioSession:")
        self.tvoaudioDevice.isEnabled = false
        if let asession = self.audioSession {
            self.didDeactivate(audioSession: asession)
        }
        self.audioSession = nil
        CallManager.configureDefaultAudioSession()
    }

    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        DDLogInfo("Twilio provider:timedOutPerformingAction:")
        if let startAction = action as? CXStartCallAction, startAction.callUUID == currentUuid {
            self.stopOutgoingRingback()
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        DDLogInfo("Twilio provider:performStartCallAction:")

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
                    DDLogInfo("performMakeVoiceCall() successful")
                    self.callKitProvider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
                } else {
                    DDLogInfo("performMakeVoiceCall() failed")
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
        // DDLogInfo("***** CXProvider:performAnswerCallAction: \(action.callUUID)")
        logIncomingState("CXAnswerCallAction start", uuid: action.callUUID)

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
                // DDLogInfo("***** calling timeout")
                self.performTimeout()
            }
            callTimeout = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: callTimeout!)
        }

        action.fulfill()
        logIncomingState("CXAnswerCallAction fulfilled", uuid: action.callUUID)
        self.handleAnswerCall()
        self.gcdelegate?.setStatus("Connecting...")
        self.awaitingCallResponse = false
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        self.stopOutgoingRingback()
        //print("Twilio provider:performEndCallAction: with *** userInitiatedDisconnect: \(userInitiatedDisconnect)")
        // DDLogInfo("***** CXProvider:CXEndCallAction:")
        
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
            self.handleRejectCall()
        }

        self.endedCall = false
        self.hasIncomingVoiceCall = false
        self.awaitingCallResponse = false
        self.waitingToAnswerCall = false
        let hasActiveCall = self.isCallActive()
        if !hasActiveCall || (hasActiveCall && activeCallInvite == nil) {
            //BC.info("call", "CallKit requested currentCall=nil (deferred)")
            if self.isEndingCurrentCall == false {
                //DDLogInfo("***** performEndCallAction: nullifying currentCall immediately")
                self.currentUuid = nil
                self.notificationUuid = nil
                self.currentCall = nil
                self.alternateCall = nil
            }
        }
        self.activeCallInvite = nil
        self.isBusy = false
        self.busyTone = false
        self.receivedRetract = false
        clearPendingCall(uuid: action.callUUID)
        action.fulfill()
        endCallSetupBackgroundTask()
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
        
        // DDLogDebug("***** Configuring default audio session...")
        
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
                if self.currentUuid == uuid {
                    self.stopOutgoingRingback()
                }
                return
            }
            DDLogInfo("StartCallAction transaction request successful")
            
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
        
        let appDelegate = UIApplication.shared.delegate as? GlacierAppDelegate
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
            // DDLogInfo("***** No CallInvite matches the UUID")
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
            // DDLogInfo("***** No contact found for call")
            return
        }
        
        let appDelegate = UIApplication.shared.delegate as? GlacierAppDelegate
        //print("***** performAnswerVoiceCall")
        if let appDelegate, appDelegate.isMainInterfaceReady() {
            appDelegate.openPhoneCallController(contact)//calltitle)
        } else {
            enqueuePendingCallPresentation(.voice(contact: contact))
            return
        }
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
        logIncomingState("handleAnswerCall start")
        
        if let tcall = self.currentCall {
            if tcall.isVoice {
                self.performAnswerVoiceCall()
            } else if GlacierProtocolManager.sharedInstance().isAccountIdConnected(acct.uniqueId) {
                // DDLogInfo("***** handleAnswerCall, with current call and account connected")
                self.acceptCall(tcall)
            } else {
                self.waitingToAnswerCall = true
                // DDLogInfo("***** handleAnswerCall, with current call and account NOT connected")
            }
        } else {
            // DDLogInfo("***** handleAnswerCall, with no current call")
            self.waitingToAnswerCall = true
            var calltitle = self.incomingCallHandle?.value ?? ""
            DispatchQueue.main.async {
                let appDelegate = UIApplication.shared.delegate as? GlacierAppDelegate
                if let appDelegate, appDelegate.isMainInterfaceReady() {
                    appDelegate.openVideoCallController(calltitle)
                } else {
                    self.enqueuePendingCallPresentation(.video(title: calltitle))
                }
                self.gcdelegate?.setStatus("Connecting...")
            }
        }
        logIncomingState("handleAnswerCall end")
    }
    
    func handleBusyCall() {
        if let acct = self.cAccount, let bid = self.busyId {
            if GlacierProtocolManager.sharedInstance().isAccountIdConnected(acct.uniqueId), let bcall = self.alternateCall {
                //let bcall = TwilioCall()
                //bcall.callid = bid
                self.rejectCall(bcall, busy: true)
            } else {
                self.waitingToRespondBusy = true
            }
        }
    }
    
    func handleRejectCall() {
        if let acct = self.cAccount, let tcall = self.currentCall {
            if GlacierProtocolManager.sharedInstance().isAccountIdConnected(acct.uniqueId) {
                self.rejectCall(tcall, busy: false)
            } else {
                self.waitingToRespondReject = true
            }
        }
    }
    
    @objc func handleLoginSuccess() {
        logIncomingState("handleLoginSuccess start")
        if self.waitingToAnswerCall {
            if let tcall = self.currentCall {
                //self.callTimeout?.cancel()
                self.acceptCall(tcall)
            } else {
                // DDLogInfo("***** handleLoginSuccess, still waiting for call info")
                return
            }
        } else if (self.waitingToRespondBusy) {
            handleBusyCall()
        } else if (self.waitingToRespondReject) {
            handleRejectCall()
        }
        self.waitingToAnswerCall = false
        self.waitingToRespondBusy = false
        self.waitingToRespondReject = false
        logIncomingState("handleLoginSuccess end")
    }
    
    func isBluetoothAvailable() -> Bool {
        return self.bluetoothAvailable
    }
    
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
            // DDLogInfo("***** Activating audio session now: \(audioSession)")

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
        DDLogInfo("Deactivating audio session now: \(audioSession)")
        if isObservingAudioRouteChanges {
            NotificationCenter.default.removeObserver(
                self,
                name: NSNotification.Name(rawValue: AVAudioSession.routeChangeNotification.rawValue),
                object: nil
            )
            isObservingAudioRouteChanges = false
        }
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
        pendingCallPresentation = nil
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
        logIncomingState("beginIncomingCallIfReady start", uuid: uuid, callId: callId)
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
            self.lastUuid = uuid
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

            if let user = callerJid?.user {
                self.postIncomingCallSystemMessage(callerJidString: callerJidString, user: user)
            }

            if self.waitingToAnswerCall,
               let answerAction = self.unconnectedAnswerCallAction,
               answerAction.callUUID == uuid {
                // DDLogInfo("***** beginIncomingCallIfReady and was waitingToAnswerCall")
                self.callTimeout?.cancel()
                self.currentCall?.answerCallAction = answerAction
                self.currentCall?.callKitAnswerFulfilled = true
                self.waitingToAnswerCall = false
                self.acceptCall(self.currentCall!)
                self.unconnectedAnswerCallAction = nil
            }
        } else if self.currentCall?.callUuid != uuid {
            // DDLogInfo("***** beginIncomingCallIfReady and already had current call, should be busy?")
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
        logIncomingState("beginIncomingCallIfReady end", uuid: uuid, callId: callId)
    }
    
    //not for use for Twilio voice calls
    public func reportIncomingCallFromNotification(uuid: UUID, callId: String, caller: String, suppressBusy: Bool = false, completion: ((NSError?) -> Void)? = nil) {

        // Before anything else: callservicesd's assertion covers only the report itself,
        // and we are suspended the moment it lets go unless we hold our own.
        beginCallSetupBackgroundTask()

        var inOtherCall = false
        let curcall = self.currentCall
        if let calltest = curcall, calltest.callUuid != uuid {
            inOtherCall = true
        } else {
            self.notificationUuid = uuid.uuidString
        }
        logIncomingState("reportIncomingCallFromNotification start", uuid: uuid, callId: callId)

        let initialName = quickCallerName(from: caller)
        if retractedCallIds.contains(uuid.uuidString) {
            let callHandle = CXHandle(type: .generic, value: initialName)
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

        if !callId.isEmpty {
            pushCallIdToUuid[callId] = uuid
            DispatchQueue.main.asyncAfter(deadline: .now() + 120.0) { [weak self] in
                if self?.pushCallIdToUuid[callId] == uuid {
                    self?.pushCallIdToUuid.removeValue(forKey: callId)
                }
            }
        }

        var pending = ensurePendingCall(uuid: uuid, callId: callId)
        pending.pushCallId = callId
        pending.callerFromPush = caller
        pending.hasVoipPush = true
        pendingIncomingCalls[uuid] = pending
        updateAwaitingCallResponseState()

        let callHandle = CXHandle(type: .generic, value: initialName)
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

        // DDLogInfo("***** reportIncomingCallFromNotification reportNewIncomingCall uuid \(uuid), in other call \(inOtherCall)")
        callKitProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
            if error == nil {
                //DDLogInfo("***** Incoming call successfully reported.")

                // Resolve the full display name from the DB now that CallKit has been notified,
                // then update the call handle if a better name is available.
                DispatchQueue.global(qos: .userInitiated).async {
                    let resolvedName = self.resolveCallerDisplayName(from: caller)
                    if resolvedName != initialName {
                        let updatedHandle = CXHandle(type: .generic, value: resolvedName)
                        let updatedUpdate = CXCallUpdate()
                        updatedUpdate.remoteHandle = updatedHandle
                        self.incomingCallHandle = updatedHandle
                        self.callKitProvider.reportCall(with: uuid, updated: updatedUpdate)
                    }
                }

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
            self.logIncomingState("reportIncomingCallFromNotification completion", uuid: uuid, callId: callId)
            completion?(error as NSError?)
        }

        if (!inOtherCall) {
            schedulePendingTimeout(for: uuid)
        }
    }

    /// PushKit contract safety net. On iOS 13+, every `.voIP` push MUST result in a
    /// `reportNewIncomingCall` before the push handler completes, or the OS terminates the
    /// app with `0xBAADCA11` (and eventually stops delivering VoIP pushes altogether). If a
    /// VoIP push arrives that we cannot turn into a real incoming call (e.g. an unexpected or
    /// malformed payload that fails to parse into a caller/callId/room), we still have to
    /// satisfy the contract: report a placeholder call and immediately end it. This should
    /// essentially never fire in production; it exists purely so a bad payload can't kill the app.
    public func reportPlaceholderCallAndEnd(completion: (() -> Void)? = nil) {
        let uuid = UUID()
        let callUpdate = CXCallUpdate()
        callUpdate.remoteHandle = CXHandle(type: .generic, value: "Call")
        callUpdate.supportsDTMF = false
        callUpdate.supportsHolding = false
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.hasVideo = false
        callKitProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { [weak self] error in
            if let error = error {
                DDLogInfo("reportPlaceholderCallAndEnd failed to report: \(error.localizedDescription)")
            }
            // End it immediately; the contract is satisfied by the report above.
            self?.callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            completion?()
        }
    }

    func handleJMIPropose(uuid: UUID, callId: String, caller: String, callType: CallType) {
        // DDLogInfo("***** handleJMIPropose with uuid \(uuid.uuidString)")
        logIncomingState("handleJMIPropose start", uuid: uuid, callId: callId)
        if retractedCallIds.contains(callId) {
            // DDLogInfo("***** handleJMIPropose returning because call was retracted")
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
        logIncomingState("handleJMIPropose end", uuid: uuid, callId: callId)
    }

    public func reportIncomingCall(uuid: UUID, callId: String, caller: String, isVoice: Bool, completion: ((NSError?) -> Void)? = nil) {
        
        var inCall = false
        var calltitle = caller
        logIncomingState("reportIncomingCall start", uuid: uuid, callId: callId)
        if (self.currentCall == nil) {
            self.currentUuid = uuid
            self.lastUuid = uuid
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
            // DDLogInfo("***** we think we have current call, should be busy?")
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
            
        // DDLogInfo("***** reportIncomingCall reportNewIncomingCall")
        callKitProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
            if error == nil {
                // DDLogInfo("***** Incoming call successfully reported.")
            } else {
                // DDLogInfo("***** Failed to report incoming call successfully: \(String(describing: error?.localizedDescription)).")
            }
            self.logIncomingState("reportIncomingCall completion", uuid: uuid, callId: callId)
            completion?(error as NSError?)
        }
        
        if (!inCall) {
            let task = DispatchWorkItem { self.performTimeout() }
            callTimeout = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: callTimeout!)
        }
    }
    
    func handleJMIPropose(callType: CallType) {
        logIncomingState("handleJMIPropose(callType) start")
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
        logIncomingState("handleJMIPropose(callType) end")
    }
    
    /// Handles a call-status VoIP push: the call identified by `callId` was accepted, rejected,
    /// or busy on another device. Only the matching call is ended, and only while it has not
    /// been answered or connected on this device. The push itself is always satisfied with a
    /// throwaway CallKit report, so it can never collide with (and end) a live call's UUID.
    @objc public func reportMAMCallResponse(callId: String, status: String, completion: ((NSError?) -> Void)? = nil) {
        let resolvedElsewhere = ["accept", "reject", "busy"].contains(status)
        let uuid = pushCallIdToUuid[callId]
            ?? (currentCall?.callid == callId ? currentCall?.callUuid : nil)
            ?? pendingIncomingCalls.first(where: { $0.value.pushCallId == callId || $0.value.jmiCallId == callId })?.key

        if resolvedElsewhere, let uuid {
            if let call = currentCall, call.callUuid == uuid {
                if shouldEndCallForStatus(call, status: status) {
                    if status == "accept" {
                        awaitingCallResponse = false
                    }
                    // Resolved on another device: end locally without sending a reject or
                    // retract that would reach the caller.
                    receivedRetract = true
                    performEndCallAction(uuid: uuid, userInitiated: false)
                }
            } else if let pending = pendingIncomingCalls[uuid] {
                // Still waiting on the JMI propose. Keep a late propose (or MAM replay) from
                // starting it, and end only this call in CallKit, not the current call.
                let resolvedIds = [callId, pending.jmiCallId].compactMap { $0 }
                retractedCallIds.formUnion(resolvedIds)
                DispatchQueue.main.asyncAfter(deadline: .now() + 60.0) { [weak self] in
                    self?.retractedCallIds.subtract(resolvedIds)
                }
                if pending.reportedToCallKit {
                    callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: endedReason(forStatus: status))
                }
                clearPendingCall(uuid: uuid)
            }
        }

        reportPlaceholderCallAndEnd {
            completion?(nil)
        }
    }

    private func shouldEndCallForStatus(_ call: TwilioCall, status: String) -> Bool {
        let answeredOrConnected = call.answerCallAction != nil
            || call.callKitAnswerFulfilled
            || call.callstatus == .connecting
            || call.callstatus == .connected
        guard !answeredOrConnected else { return false }
        if call.outgoing {
            // The callee declined or was busy; an accept means our call is about to connect.
            return status == "reject" || status == "busy"
        }
        return true
    }

    private func endedReason(forStatus status: String) -> CXCallEndedReason {
        switch status {
        case "accept": return .answeredElsewhere
        case "reject": return .declinedElsewhere
        default: return .remoteEnded
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
        logIncomingState("reportCallAccepted(simple) start")
        if let tcall = self.currentCall {
            DispatchQueue.main.async {
                GlacierAppDelegate.appDelegate.connectVideoCall(tcall)
            }
        }
        logIncomingState("reportCallAccepted(simple) end")
    }
    
    @objc public func reportCallAccepted(_ from:String, callid:String, deviceid:String) {
        //might need to match up uuid or something with current call from notification
        logIncomingState("reportCallAccepted start", uuid: self.currentCall?.callUuid, callId: callid)
        if let tcall = self.currentCall { //}, let acct = self.cAccount {
            //set call id?
            self.currentCall?.remoteDeviceId = deviceid
            self.currentCall?.receiver = from
            //createConnectingTimeoutTimer
            self.prepareSessionInitiate(from, callId: callid, deviceId: deviceid)
            
            //this is likely a group call and I don't need to handle it here
            if tcall.status == "inprogress" || tcall.status == "accept", callid == tcall.callid {
                return
            }
            self.currentCall?.status = "accept"
            
            DispatchQueue.main.async {
                GlacierAppDelegate.appDelegate.connectVideoCall(tcall)
            }
        }
        logIncomingState("reportCallAccepted end", uuid: self.currentCall?.callUuid, callId: callid)
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
        logIncomingState("prepareSessionInitiate start", callId: callId)
        self.performBlock(async: true){
            guard let myjid = self.xmppStream?.myJID?.full, let call = self.currentCall, let tojid = XMPPJID(string: to), let webClient = call.webrtcClient else { return }
            
            guard let acct = self.cAccount, let xmpp = GlacierProtocolManager.shared.xmppManager(forChatAccount: acct) else { return }
            
            webClient.offer(completion: { (sdp) in
                // DDLogDebug("***** WebRTC offer completion")
                self.logIncomingState("prepareSessionInitiate offer completion", callId: callId)
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
                            self.logIncomingState("prepareSessionInitiate sent session-initiate", callId: callId)
                            return
                        }
                    }
                }
                
                self.sendJmiRetract(call)
                if let cuid = call.callUuid {
                    self.logIncomingState("prepareSessionInitiate fallback retract", uuid: cuid, callId: callId)
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
            // DDLogInfo("***** prepareSessionAnswer")
            guard let myjid = self.xmppStream?.myJID?.full, let call = self.currentCall, let rid = call.remoteDeviceId else { return }
            
            guard let acct = self.cAccount, let xmpp = GlacierProtocolManager.shared.xmppManager(forChatAccount: acct) else { return }
            
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
        
        var tojidstr = call.receiver
        if call.isCaller == false {
            tojidstr = call.callerFullJID
        }
        
        /*var to = call.caller
        if call.isCaller {
            to = call.receiver
        }*/
        
        guard let tostr = tojidstr, let tojid = XMPPJID(string: tostr), let acct = self.cAccount, let xmpp = GlacierProtocolManager.shared.xmppManager(forChatAccount: acct) else { return }
        
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
        
            guard let acct = self.cAccount, let xmpp = GlacierProtocolManager.shared.xmppManager(forChatAccount: acct) else {
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
        // print("***** processIncomingCandidates")
        
        for mediaType in remoteCandidates.keys {
            let candidateAr = remoteCandidates[mediaType] ?? []
            for candidate in candidateAr {
                //print("***** processIncomingCandidates remote candidate: \(candidate)")
                let rtcCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: 0, sdpMid: mediaType)
                call.webrtcClient?.setRemoteCandidate(rtcCandidate, completion: { (error) in
                    if let error = error {
                        // print("***** processIncomingCandidates \(error)")
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
                    if self.currentCall?.isGroup == true {
                        return
                    }
                    
                    guard let url = Bundle.main.url(forResource: "MarimbaFailed", withExtension: "wav") else { return }
                    playSound(soundUrl: url)
                    performEndCallAction(uuid: uuid, userInitiated: false)
                }
            }
        }
    }
    
    @objc public func reportCallBusy() {
        DDLogDebug("reportCallBusy")
        if (self.busyTone == true) {
            DDLogDebug("reportCallBusy already active with busy Tone")
            return
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
            // DDLogInfo("***** reportCallCancelled no uuid")
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
        logIncomingState("performEndCallAction start", uuid: uuid)
        self.stopOutgoingRingback()
        self.endedCall = true
        clearPendingCall(uuid: uuid)
        if let tcall = self.currentCall, userInitiated, !self.busyTone {
            self.cancelCall(tcall)
        }
        
        if let call = self.currentCall {
            beginTerminateCurrentCall(reason: userInitiated ? "user-endcall" : "endcall", uuid: uuid)
            //call.webrtcClient?.terminateSession()
        }

        // If the call ended without user interaction and never connected,
        // treat it as a missed call so it surfaces in the conversation list
        // and triggers a notification for the receiver.
        if !userInitiated, let missedCall = self.currentCall, missedCall.callstatus == .retracted {
            DispatchQueue.main.async {
                let sysmsg = "\(ChatRoomMessage.StringConstants.missedCall.text) - \(Date().formattedAsShortWeekdayTime())"
                if missedCall.isGroup {
                    if let title = missedCall.calltitle {
                        GlacierAppDelegate.appDelegate.addSystemGroupMessage(sysmsg, with: title)
                    }
                } else if let caller = missedCall.caller, missedCall.outgoing == false {
                    let user = XMPPJID(string: caller)?.user ?? caller
                    GlacierAppDelegate.appDelegate.addSystemMessage(sysmsg, with: caller, with: user)
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
        // DDLogInfo("***** performEndCallAction with \(uuid) and userInitiated \(userInitiated)")
        userInitiatedDisconnect = userInitiated
        
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)

        callKitCallController.request(transaction) { error in
            if let error = error {
                DDLogInfo("EndCallAction transaction request failed: \(error.localizedDescription).")
                self.logIncomingState("performEndCallAction request failed", uuid: uuid)
                return
            }

            DDLogInfo("EndCallAction transaction request successful")
            self.logIncomingState("performEndCallAction request success", uuid: uuid)
        }
    }
    
    private func beginTerminateCurrentCall(reason: String, uuid: UUID? = nil) {
        guard !isEndingCurrentCall else { return }
        guard let call = currentCall, let webrtc = call.webrtcClient else { return }

        isEndingCurrentCall = true

        // Hold strongly so async teardown isn't cut off by currentCall=nil
        callHold = call

        //BC.info("call", "beginTerminateCurrentCall", data: ["reason": reason])

        var finished = false
        func finishOnce() {
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async {
                //BC.info("call", "terminateSession finished → nullify")
                self.performNullifyCallState()
                self.isEndingCurrentCall = false
                self.callHold = nil
            }
        }

        webrtc.terminateSession(reason: reason) {
            finishOnce()
        }

        // Safety timeout so you don't hold forever
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if !finished {
                //BC.info("call", "terminateSession timeout → nullify", data: ["reason": reason])
                finishOnce()
            }
        }
    }

    private func performNullifyCallState() {
        endCallSetupBackgroundTask()

        self.endedCall = false
        self.hasIncomingVoiceCall = false
        self.awaitingCallResponse = false
        self.waitingToAnswerCall = false

        let hasActiveCall = self.isCallActive()
        if !hasActiveCall || (hasActiveCall && activeCallInvite == nil) {
            // DDLogInfo("***** nullifying currentCall (deferred)")
            self.currentUuid = nil
            self.notificationUuid = nil
            self.currentCall = nil
            self.alternateCall = nil
        }

        self.activeCallInvite = nil
        self.isBusy = false
        self.busyTone = false
        self.receivedRetract = false
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

            DDLogInfo("EndCallAction transaction request successful")
        }
    }
    
    func reportCallDisconnected(uuid: UUID, error: Error?) {
        self.stopOutgoingRingback()
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
        //self.currentCall = nil
        //BC.info("call", "reportCallDisconnected was nullify previously while terminating")
        self.alternateCall = nil
        self.activeCall = nil
        self.userInitiatedDisconnect = false
    }
    
    @objc public func reportCallConnected(uuid: UUID?, connectTime: Date) {
        self.stopOutgoingRingback()
        self.stopSound()
        
        self.currentCall?.status = "inprogress"
        
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
                DDLogInfo("SetMutedCallAction transaction request successful")
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
    
    /// The Twilio identity a registration belongs to: the local part of the account JID,
    /// which is what TwilioBackendManager sends as `username` when it mints the voice token.
    var currentTwilioIdentity: String? {
        guard let username = ChatAccountModel.firstAccount()?.username, !username.isEmpty else {
            return nil
        }
        return username.components(separatedBy: "@").first
    }

    /// Forgets which Twilio binding this device holds. Call on sign-out.
    ///
    /// Without this, the guard in `registerWithTwilio()` below sees an unchanged device token
    /// and a binding date under TTL/2 and skips registration entirely - so the *next* account
    /// to sign in on this install never registers, and never receives an incoming call, for up
    /// to 182 days. `callInviteReceived` refreshes the date on every inbound call, so an
    /// actively used device keeps pushing that window out rather than ageing out of it.
    ///
    /// This only forgets the local cache. The binding itself still exists on Twilio's side
    /// until its one-year TTL expires: tearing that down needs
    /// `TwilioVoiceSDK.unregister(accessToken:deviceToken:)` with a live access token, which
    /// sign-out no longer has by the time it gets here, or a server-side binding delete.
    @objc public func clearPushRegistrationCache() {
        UserDefaults.standard.removeObject(forKey: kCachedDeviceToken)
        UserDefaults.standard.removeObject(forKey: kCachedBindingDate)
        UserDefaults.standard.removeObject(forKey: kCachedRegisteredIdentity)
    }

    func registerWithTwilio() {
        guard let accessToken = self.callToken, let deviceToken = self.deviceToken else {
            return
        }
        
        // Identity is part of the condition as a backstop: sign-out clears the cache, but a
        // sign-out that never completes - a crash, a force-quit - would otherwise leave the
        // stale entry in place and silently cost the next account its incoming calls.
        let identity = self.currentTwilioIdentity
        let identityChanged = (UserDefaults.standard.string(forKey: kCachedRegisteredIdentity) != identity)
        
        guard (registrationRequired() || identityChanged || UserDefaults.standard.data(forKey: kCachedDeviceToken) != deviceToken) else {  return  }
        
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
                UserDefaults.standard.set(identity, forKey: self.kCachedRegisteredIdentity)
                    
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
        if let acct = self.cAccount, let xmpp = GlacierProtocolManager.shared.xmppManager(forChatAccount: acct) {
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
              let xmpp = GlacierProtocolManager.shared.xmppManager(forChatAccount: acct) else {
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
        // DDLogInfo("***** Proposing new call via JMI")
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
        DDLogInfo("callInviteReceived:")
        
        /**
         * The TTL of a registration is 1 year. The TTL for registration for this device/identity
         * pair is reset to 1 year whenever a new registration occurs or a push notification is
         * sent to this device/identity pair.
         */
        UserDefaults.standard.set(Date(), forKey: kCachedBindingDate)
        
        let callerInfo: TVOCallerInfo = callInvite.callerInfo
        if let verified: NSNumber = callerInfo.verified {
            if verified.boolValue {
                // DDLogInfo("***** Call invite received from verified caller number!")
            }
        }
        // DDLogInfo("***** Call invite received with uuid \(callInvite.uuid) and sid \(callInvite.callSid)!")
        
        activeCallInvite = callInvite
        if let from = callInvite.from?.replacingOccurrences(of: "client:", with: "") {
            let callId = callInvite.callSid
            let onCall = (self.currentCall != nil)
            self.reportIncomingCall(uuid: callInvite.uuid, callId: callId, caller: from, isVoice: true) { _ in
                if self.activeCall != nil || onCall {
                    // DDLogInfo("***** ending call from callInviteReceived")
                    self.endedCall = true
                    let endCallAction = CXEndCallAction(call: callInvite.uuid)
                    let transaction = CXTransaction(action: endCallAction)

                    self.callKitCallController.request(transaction) { error in
                        self.callKitProvider.reportCall(with: callInvite.uuid, endedAt: Date(), reason: .answeredElsewhere)
                    }
                }
            }
        } else {
            // We have a valid invite but couldn't parse a caller. reportIncomingCall above is our
            // only reportNewIncomingCall for this VoIP push, so if we skip it the push completes
            // unreported and iOS kills us with 0xBAADCA11. Report using the invite's own uuid so
            // the contract is satisfied, then end it immediately.
            DDLogInfo("callInviteReceived with unparseable 'from'; reporting placeholder to satisfy CallKit contract")
            reportPlaceholderCallAndEnd()
        }
    }
    
    public func cancelledCallInviteReceived(cancelledCallInvite: CancelledCallInvite, error: Error) {
        DDLogInfo("cancelledCallInviteCanceled:error:, error: \(error.localizedDescription)")

        if let callUuid = self.currentCall?.callUuid {
            performEndCallAction(uuid: callUuid, userInitiated: false)
            activeCallInvite = nil
        } else {
            // A Twilio VoIP push was delivered as a *cancellation* with no call ever reported
            // (e.g. the ring push was deduped/missed, or we were woken cold just for the cancel).
            // The VoIP-push branch in GlacierAppDelegate set awaitingAsyncCompletion = true and
            // trusted the Twilio SDK to report the call, so the placeholder safety net there did
            // NOT fire. Nothing has called reportNewIncomingCall — iOS 13+ kills the app with
            // 0xBAADCA11 for any VoIP push that completes without a report. Satisfy the contract
            // here by reporting a placeholder call and immediately ending it.
            DDLogInfo("cancelledCallInviteReceived with no currentCall; reporting placeholder to satisfy CallKit contract")
            reportPlaceholderCallAndEnd()
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
            // DDLogInfo("***** New WebRTC ICE state: connected")
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
            // DDLogInfo("***** New WebRTC ICE state: disconnected")
            if call.isCaller == false, call.callstatus == .connecting, call.callKitAnswerFulfilled == false {
                call.answerCallAction?.fail()
            } else {
                self.gcdelegate?.setStatus("Reconnecting...")
            }
            
            break
        case .failed:
            // DDLogInfo("***** New WebRTC ICE state: failed")
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
            DDLogInfo("New WebRTC ICE state: closed")
            break
        case .new:
            DDLogInfo("New WebRTC ICE state: new")
            break
        case .checking:
            DDLogInfo("New WebRTC ICE state: checking")
            break
        case .count:
            DDLogInfo("New WebRTC ICE state: count")
            break
        default:
            DDLogInfo("New WebRTC ICE state: UNKNOWN")
            break
        }
    }
    
    func sendAcks() {
        /*self.performBlock(async: true){
            if let acct = self.cAccount, let xmpp = GlacierProtocolManager.shared.xmppManager(forChatAccount: acct) {
                xmpp.sendAcknowledgments()
            }
        }*/
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
