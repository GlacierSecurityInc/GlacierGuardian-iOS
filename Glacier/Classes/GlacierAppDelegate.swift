//
//  GlacierAppDelegate.swift
//  ChatSecureCore
//
//  Created by Chris Ballinger on 12/5/17.
//  Copyright © 2017 Chris Ballinger. All rights reserved.
//

import Foundation
import UserNotifications
import CocoaLumberjack
import PushKit
import MBProgressHUD
import GRDB
import Amplify
//import AWSAPIPlugin
import AWSCognitoAuthPlugin
//import AWSS3StoragePlugin
import MetricKit
import os.log
//import Sentry
import IOSSecuritySuite

public extension GlacierAppDelegate {
    /// Starts the Amplify/Cognito bring-up for this launch.
    ///
    /// Two things must be in place before the session check can run, and in a
    /// background launch on a locked phone neither is ready at didFinishLaunching:
    ///  * protected data — the Cognito credential store lives in the keychain;
    ///  * an open database — deciding whether a failed session should prompt reads
    ///    the account table.
    /// Whichever arrives last kicks the work off; `amplifySessionChecked` keeps the
    /// session check to a single run for the life of the process.
    @objc func setupAmplify() {
        guard !self.blockAmplifyForProxyIfNeeded() else { return }

        if UIApplication.shared.isProtectedDataAvailable {
            self.amplifyProtectedDataReady = true
            self.startAmplifyBringUpIfReady()
            return
        }

        os_log("setupAmplify: protected data unavailable at launch, waiting for unlock",
               log: .auth, type: .info)

        // Deliberately one-shot. This observer used to be left installed for the
        // life of the process, so the entire bring-up re-ran on *every* unlock and
        // could re-present the login prompt hours into a session.
        guard self.protectedDataObserver == nil else { return }
        self.protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if let observer = self.protectedDataObserver {
                NotificationCenter.default.removeObserver(observer)
                self.protectedDataObserver = nil
            }
            os_log("setupAmplify: protected data became available", log: .auth, type: .info)
            self.amplifyProtectedDataReady = true
            self.startAmplifyBringUpIfReady()
        }
    }

    /// Called from `whenDatabaseReady:` once the GRDB stack is open.
    @objc func amplifyDatabaseDidBecomeReady() {
        self.amplifyDatabaseReady = true
        self.startAmplifyBringUpIfReady()
    }

    private func startAmplifyBringUpIfReady() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.startAmplifyBringUpIfReady() }
            return
        }
        guard self.amplifyProtectedDataReady else { return }
        guard !self.blockAmplifyForProxyIfNeeded() else { return }

        // Configuring only needs the keychain, and other callers (GlacierAPIHeaders)
        // depend on it, so it must not sit behind the database.
        self.configureAmplifyIfNeeded()

        // The prompt decision reads the account table, so wait for the database. If
        // the database never opens we simply never prompt, which is the safe way to
        // fail.
        guard self.amplifyDatabaseReady, !self.amplifySessionChecked else { return }
        self.amplifySessionChecked = true
        Task { await self.tryFetchSession() }
    }
    
    private func blockAmplifyForProxyIfNeeded() -> Bool {
        let proxied = IOSSecuritySuite.amIProxied()
        if proxied {
            let alreadyDetected = self.isProxyDetected()
            self.setProxyDetected(true)
            if !alreadyDetected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    NotificationCenter.default.post(
                        name: SecurityCenter.didCheckCompromised,
                        object: self,
                        userInfo: ["compromised": true, "detail": "proxied"]
                    )
                }
            }
        }
        return proxied || self.isProxyDetected()
    }
    
    @objc static var isTestFlight: Bool {
        guard let url = Bundle.main.appStoreReceiptURL else { return true }
        // TestFlight and StoreKit sandbox receipts end with "sandboxReceipt"
        return url.lastPathComponent == "sandboxReceipt" ||
                url.path.contains("sandboxReceipt")
    }

    private func tryFetchSession() async {
        guard !blockAmplifyForProxyIfNeeded() else { return }

        let state = await AWSAcctManager.sharedMgr().resolveAuthSessionState()

        switch state {
        case .signedIn:
            os_log("session check: signed in", log: .auth, type: .info)
            return

        case .indeterminate:
            // Network trouble, an unreadable keychain, or a plugin that was not
            // ready yet. Staying quiet is the only correct move: a working session
            // must never be discarded on a guess.
            os_log("session check: indeterminate, not prompting", log: .auth, type: .info)
            return

        case .noSession, .tokensInvalid:
            break
        }

        guard self.conversationViewController.getFirstAccount() != nil else {
            os_log("session check: no session and no account, leaving it to onboarding",
                   log: .auth, type: .info)
            return
        }

        // Tokens that went stale under the user (a rotated App Client ID, an
        // expired refresh token) get an explanation first; a plain signed-out
        // state just needs the password.
        let explains = (state == .tokensInvalid)
        os_log("session check: re-auth required (explains=%{public}@)",
               log: .auth, type: .default, explains ? "yes" : "no")
        await MainActor.run { self.requestReauthPrompt(explains: explains) }
    }

    /// Shows the re-auth prompt, but only when there is a foreground UI to show it
    /// in. During a background launch the conversation controller lives in a scene
    /// with no window context, so presenting there is either dropped outright or —
    /// worse — leaves an alert queued that the user walks into hours later.
    private func requestReauthPrompt(explains: Bool, required: Bool = false) {
        guard UIApplication.shared.applicationState == .active, self.isMainInterfaceReady() else {
            os_log("re-auth prompt deferred: app is not foreground yet", log: .auth, type: .info)
            // A required prompt already waiting must not be downgraded by a later
            // dismissable one.
            self.reauthPromptExplains = explains || self.reauthPromptRequired
            self.reauthPromptRequired = required || self.reauthPromptRequired
            self.reauthPromptPending = true
            return
        }
        self.reauthPromptPending = false
        self.reauthPromptRequired = false
        self.showReauthUI(explains: explains, required: required)
    }

    /// Called by the XMPP manager when a credential refresh finds the Cognito session
    /// gone. On a JWT-only server that leaves messaging and calls dead until the user
    /// signs in, so unlike the launch-time prompt this one cannot be dismissed.
    @objc func requireReauthForXMPP() {
        os_log("XMPP auth needs a Cognito sign-in; requiring re-auth", log: .auth, type: .default)
        self.requestReauthPrompt(explains: true, required: true)
    }

    private func showReauthUI(explains: Bool, required: Bool = false) {
        if required {
            self.conversationViewController.setExplainedReauthController(required: true)
        } else if explains {
            self.conversationViewController.setExplainedReauthController()
        } else {
            self.conversationViewController.setWelcomeController(true)
        }
    }

    /// Called from `applicationDidBecomeActive:` to flush a prompt that was
    /// deferred because the app was still in the background.
    @objc func presentPendingReauthPromptIfNeeded() {
        guard self.reauthPromptPending else { return }
        guard self.isMainInterfaceReady() else { return }
        guard self.conversationViewController.getFirstAccount() != nil else {
            self.reauthPromptPending = false
            self.reauthPromptRequired = false
            return
        }
        os_log("presenting deferred re-auth prompt", log: .auth, type: .default)
        let required = self.reauthPromptRequired
        self.reauthPromptPending = false
        self.reauthPromptRequired = false
        self.showReauthUI(explains: self.reauthPromptExplains, required: required)
    }

    private func configureAmplifyIfNeeded() {//async {
        guard !self.amplifyIsConfigured else { return }
        guard !self.isProxyDetected() else { return }

        do {
            Amplify.Logging.logLevel = .error
            //try Amplify.add(plugin: AWSAPIPlugin())
            try Amplify.add(plugin: AWSCognitoAuthPlugin())
            //try Amplify.add(plugin: AWSS3StoragePlugin())
            try Amplify.configure()
            self.amplifyIsConfigured = true
            os_log("Amplify configured successfully", log: .auth, type: .info)
        } catch {
            os_log("Failed to initialize Amplify: %{public}@",
                   log: .auth, type: .error, String(describing: error))
        }
    }
    
    /// gets the last user interaction date, or current date if app is activate
    @objc static func getLastInteractionDate(_ block: @escaping (_ lastInteractionDate: Date?)->(), completionQueue: DispatchQueue? = nil) {
        DispatchQueue.main.async {
            var date: Date? = nil
            if Application.shared.applicationState == .active {
                date = Date()
            } else {
                date = self.lastInteractionDate
            }
            if let completionQueue = completionQueue {
                completionQueue.async {
                    block(date)
                }
            } else {
                block(date)
            }
        }
    }
    
    @objc static func setLastInteractionDate(_ date: Date) {
        DispatchQueue.main.async {
            self.lastInteractionDate = date
        }
    }

    /// @warn only access this from main queue
    private static var lastInteractionDate: Date? = nil

    @objc func uploadMetricKitHangsIfNeeded() {
        guard UIApplication.shared.applicationState == .active else { return }
        guard GlacierAppDelegate.isTestFlight else { return }

        let hangFiles = HangStore.shared.loadAll()
        guard !hangFiles.isEmpty else { return }

        let rooms = ChatRoomModel.allXMPPRooms()
        guard let room = rooms.first(where: { $0.threadName.localizedCaseInsensitiveContains("GlacierHangs") && $0.joined }) else {
            return
        }
        guard let accountId = room.accountUniqueId,
              GlacierProtocolManager.sharedInstance().isAccountIdConnected(accountId),
              let account = ChatAccountModel.getXMPPAccount(uniqueId: accountId),
              let xmppManager = GlacierProtocolManager.shared.xmppManager(forChatAccount: account) else {
            return
        }

        let fileTransferManager = xmppManager.fileTransferManager
        hangFiles.forEach { file in
            fileTransferManager.uploadAttachment(file: file, mucname: room.threadName, hudprogress: nil) { _, error in
                guard error == nil else { return }
                HangStore.shared.delete(file)
            }
        }
    }
}

@objcMembers
final class MetricKitDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitDiagnostics()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.yourcompany.yourapp",
                                category: "MetricKit")

    private override init() {
        super.init()
    }

    /// Call this once during app startup (after the process launches).
    func start() {
        MXMetricManager.shared.add(self)
        logger.info("MetricKit subscriber added")
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }

    // MARK: - Diagnostics (crash / hang / cpu / disk write)

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            guard let hangs = payload.hangDiagnostics, !hangs.isEmpty else { continue }

            for hang in hangs {
                // Duration and stack are the most useful pieces.
                let duration = hang.hangDuration.converted(to: .seconds).value
                let callStack = hang.callStackTree.jsonRepresentation()  // Data

                logger.error("MXHangDiagnostic duration=\(duration, privacy: .public)s payloadStart=\(payload.timeStampBegin)")

                // Persist locally and/or upload with your telemetry on next launch.
                // Example: write to a file, or serialize JSON and send to your backend.
                saveHang(duration: duration,
                         payloadBegin: payload.timeStampBegin,
                         payloadEnd: payload.timeStampEnd,
                         callStackJSON: callStack)
            }
        }
    }

    // (Optional) Daily metrics, not required for hangs:
    func didReceive(_ payloads: [MXMetricPayload]) {
        // Can ignore or use for broader perf tracking.
    }

    private func saveHang(duration: TimeInterval,
                          payloadBegin: Date,
                          payloadEnd: Date,
                          callStackJSON: Data) {
        let record = HangRecord(
            id: UUID().uuidString,
            createdAt: Date(),
            hangDurationSeconds: duration,
            payloadBegin: payloadBegin,
            payloadEnd: payloadEnd,
            callStackTreeJSONBase64: callStackJSON.base64EncodedString(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model,
            breadcrumbs: []
        )
        HangStore.shared.save(record)
    }
}

struct HangRecord: Codable {
    let id: String
    let createdAt: Date

    let hangDurationSeconds: Double
    let payloadBegin: Date
    let payloadEnd: Date

    /// JSON from MXCallStackTree.jsonRepresentation()
    /// Stored as base64 to keep the record Codable + single-file.
    let callStackTreeJSONBase64: String

    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let deviceModel: String

    /// Optional: your own recent breadcrumbs/signposts
    let breadcrumbs: [String]
}

final class HangStore {
    static let shared = HangStore()

    private let dirURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MetricKitHangs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func save(_ record: HangRecord) {
        let url = dirURL.appendingPathComponent("\(record.id).json")
        do {
            let data = try JSONEncoder().encode(record)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Don’t crash; best-effort logging only
        }
        prune(maxFiles: 20) // keep last N
    }

    func loadAll() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil)) ?? []
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func prune(maxFiles: Int) {
        let files = loadAll().sorted { $0.lastPathComponent > $1.lastPathComponent }
        if files.count > maxFiles {
            for url in files.suffix(from: maxFiles) { delete(url) }
        }
    }
}

public extension GlacierAppDelegate {
    
    /// Returns key/collection of visible thread, or nil if not visible or unset
    @objc static func visibleThread(_ block: @escaping (_ tkey: String?, _ tcollection: String?)->(), completionQueue: DispatchQueue? = nil) {
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState == .active else {
                block(nil, nil)
                return
            }
            
            var prekey:String?
            var precoll:String?
            
            let chatVC = GlacierAppDelegate.appDelegate.chatViewController
            let roomVC = GlacierAppDelegate.appDelegate.chatRoomViewController
            if chatVC.isViewLoaded, chatVC.view.window != nil {
                prekey = chatVC.threadKey
                precoll = ChatBuddyModel.collection()
            } else if roomVC.isViewLoaded, roomVC.view.window != nil {
                prekey = roomVC.threadKey
                precoll = ChatRoomModel.collection()
            }
            
            guard let key = prekey, let collection = precoll else {
                block(nil, nil)
                return
            }
            
            if let completionQueue = completionQueue {
                completionQueue.async {
                    block(key, collection)
                }
            } else {
                block(key, collection)
            }
        }
    }
    
    @objc static func visibleSMSThread(_ block: @escaping (_ tkey: String?)->(), completionQueue: DispatchQueue? = nil) {
        DispatchQueue.main.async {
            let smsMessagesVC = GlacierAppDelegate.appDelegate.smsMessagesViewController
            let collection = SMSChatConversationModel.collection()
            guard smsMessagesVC.isViewLoaded,
                  smsMessagesVC.view.window != nil,
                  let key = smsMessagesVC.conversation?.uniqueId else {
                    block(nil)
                    return
            }
            
            if let completionQueue = completionQueue {
                completionQueue.async {
                    block(key)
                }
            } else {
                block(key)
            }
        }
    }
    
    
    @objc func unreadMessageCount(completion: @escaping (Int) -> Void) {
        var count:Int = 0
        
        DBManager.sharedDB().grdbStorage.asyncRead(block: { transaction in
            do {
                count = try ChatRoomMessage
                    .filter(Column("read") == false)
                    .fetchCount(transaction.database)
            } catch {
                DDLogDebug("AppDelegate.unreadMessageCount with error: \(error)")
            }
            
            do {
                let lastCount = try ChatMessage
                    .filter(Column("read") == false)
                    .fetchCount(transaction.database)
                count = count+lastCount
            } catch {
                DDLogDebug("AppDelegate.unreadMessageCount with error: \(error)")
            }
        }, completion: {
            completion(count)
        })
    }
    
    @objc func markAllRead() {
        let conversationsVC = GlacierAppDelegate.appDelegate.conversationViewController
        let hud = MBProgressHUD.showAdded(to: conversationsVC.view, animated: true)
        
        let singleMessagesToMarkAsRead: [ChatMessageModel] = ChatMessageModel.getUnreadMessages()
        let roomMessagesToMarkAsRead: [ChatRoomMessageModel] = ChatRoomMessageModel.getUnreadMessages()
            
        var singleConversationsForReadReceipts = [String: ChatMessageModel]()
        var roomConversationsForReadReceipts = [String: ChatRoomMessageModel]()
        var threads:Set<String> = []
            
        singleMessagesToMarkAsRead.forEach({ (message) in
            if let message = message.copyMessage() as? ChatMessageModel {
                message.grdbRecord?.read = true
                message.grdbRecord?.readDate = Date()
                message.save()
                
                if let threadid = message.grdbRecord?.buddyUniqueId {
                    threads.insert(threadid)
                }
                
                if message.isMarkable, message.grdbRecord?.type == ChatMessageType.incoming.rawValue {
                    singleConversationsForReadReceipts[message.threadId] = message
                }
            }
        })
        roomMessagesToMarkAsRead.forEach({ (message) in
            if let message = message.copyMessage() as? ChatRoomMessageModel {
                message.grdbRecord?.read = true
                message.grdbRecord?.messageReadDate = Date()
                message.save()
                
                if let threadid = message.grdbRecord?.roomUniqueId {
                    threads.insert(threadid)
                }
                
                if let roomjid = message.grdbRecord?.roomJid, message.isMarkable == true {
                    roomConversationsForReadReceipts[roomjid] = message
                }
            }
        })
            
        if let account = ChatAccountModel.firstAccount(), let xmpp = GlacierProtocolManager.shared.xmppManager(forChatAccount:account) {
            for message in singleConversationsForReadReceipts.values {
                if let buddyUniqueId = message.grdbRecord?.buddyUniqueId,
                   let buddy = ChatBuddyModel.getBuddy(uniqueId: buddyUniqueId),
                   let chatThread = ChatThread.getChatThread(threadId: buddy.chatThreadId),
                   chatThread.isReadReceiptsOn {
                    xmpp.sendReadReceipt(message)
                }
            }
            
            for message in roomConversationsForReadReceipts.values {
                if let roomJid = message.roomJID,
                   let xmppJid = XMPPJID(string: roomJid),
                   let chatRoom = ChatRoomModel.getXMPPRoom(roomJid: xmppJid),
                   let chatThread = ChatThread.getChatThread(threadId: chatRoom.chatThreadId),
                   chatThread.isReadReceiptsOn {
                    xmpp.sendReadReceipt(message)
                }
            }
        }
        
        for threadid in threads {
            ChatThread.touch(uniqueId: threadid)
        }
            
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            //NotificationCenter.default.post(name: Notification.Name(rawValue: "ReloadDataNotificationName"), object: self, userInfo:nil)
                
            hud.hide(animated: true)
            hud.removeFromSuperview()
        }
    }
    
    @objc func enterThread(key: String, collection: String) {
        //currently won't get past here if room doesn't exist
        let revisedCollection = collection.replacingOccurrences(of: "GlacierNotifications", with: "Glacier") 
        if revisedCollection == ChatRoomModel.collection() {
            if let room = ChatRoom.getRoom(uniqueId: key) {
                self.splitViewCoordinator.enterConversationWithRoom(room, sender: self)
            }
        } else {
            if let buddy = ChatBuddy.getBuddy(uniqueId: key) {
                self.splitViewCoordinator.enterConversationWithBuddy(buddy, sender: self)
            }
        }
    }
    
    @objc func enterSMSThread(key: String, collection: String) {
        if let smsthread = SMSChatConversationModel.getConversation(with: key) {
            //should probably also switch to account
            //self.smsSplitViewCoordinator.enterSMSWithThread(smsthread, sender: self)
            
            //switch accounts if needed on incoming notification touch
            if TwilioBackendManager.sharedMgr().selectedAccount?.grdbRecord?.phoneNumber == smsthread.grdbRecord?.localNumber {
                //do nothing
            } else if let num = smsthread.grdbRecord?.localNumber {
                if let acct = TwilioBackendManager.sharedMgr().currentAccounts.first(where: {$0.grdbRecord?.phoneNumber == num}) {
                    TwilioBackendManager.sharedMgr().selectedAccount = acct
                }
            }
            
            self.smsSplitViewCoordinator.enterSMSWithThread(smsthread, sender: self)
        }
    }
    
    func openVideoCallController(_ nameTitle:String) {
        let scene = activeWindowScene()
        if let scene = scene {
            if self.callWindow == nil || self.callWindow?.windowScene != scene {
                self.callWindow = UIWindow(windowScene: scene)
            }
        } else if self.callWindow == nil {
            self.callWindow = UIWindow(frame: UIScreen.main.bounds)
        }
        
        if self.callWindow?.rootViewController == nil {
            let screenSize = UIScreen.main.bounds.size
            self.callWindow?.frame = CGRectMake(0, 0, screenSize.width, screenSize.height)
            
            let storyboard = UIStoryboard(name: "VideoCall", bundle: GlacierInfo.resourcesBundle)
            if let callVC = storyboard.instantiateViewController(withIdentifier: "VideoCallVC") as? VideoCallViewController, let account = ChatAccountModel.firstAccount(), let xmpp = GlacierProtocolManager.shared.xmppManager(forChatAccount:account) {
                xmpp.callManager.setGlacierCallDelegate(callVC)
                xmpp.callManager.setWebRTCConnectionDelegate(callVC)
                callVC.setCallManager(xmpp.callManager)
                callVC.setNameTitle(nameTitle)
                callVC.modalPresentationStyle = .overCurrentContext
                
                self.callWindow?.rootViewController = UIViewController()
                self.callWindow?.makeKeyAndVisible()
                
                self.callWindow?.rootViewController?.present(callVC, animated: true)
            }
        }
        
        if isGroupChatController {
            chatRoomViewController.enablePhoneButton(false)
        } else {
            chatViewController.enablePhoneButton(false)
        }
    }
    
    internal func openPhoneCallController(_ callContact:PhoneContact) {//nameTitle:String) {
        //do title here? Related to incoming call number/name/contact
        let scene = activeWindowScene()
        if let scene = scene {
            if self.callWindow == nil || self.callWindow?.windowScene != scene {
                self.callWindow = UIWindow(windowScene: scene)
            }
        } else if self.callWindow == nil {
            self.callWindow = UIWindow(frame: UIScreen.main.bounds)
        }
        
        if (self.callWindow?.rootViewController == nil) {
            let screenSize = UIScreen.main.bounds.size
            self.callWindow?.frame = CGRectMake(0, 0, screenSize.width, screenSize.height)
            
            let storyboard = UIStoryboard(name: "PhoneCall", bundle: GlacierInfo.resourcesBundle)
            if let callVC = storyboard.instantiateViewController(withIdentifier: "PhoneCallVC") as? VoiceCallViewController, let account = ChatAccountModel.firstAccount(), let xmpp = GlacierProtocolManager.shared.xmppManager(forChatAccount:account) {
                xmpp.callManager.setGlacierCallDelegate(callVC)
                callVC.setCallManager(xmpp.callManager)
                //callVC.setNameTitle(nameTitle)
                callVC.setContact(callContact)
                callVC.modalPresentationStyle = .overCurrentContext
                
                self.callWindow?.rootViewController = UIViewController()
                self.callWindow?.makeKeyAndVisible()
                
                self.callWindow?.rootViewController?.present(callVC, animated: true)
            }
        }
    }
    
    @discardableResult
    func connectVideoCall(_ call:TwilioCall, readyToPresent:Bool = true) -> String? {
        guard isMainInterfaceReady(), let account = self.getFirstAccount() else { return nil }
        
        //if its a group it should probably be handled by the group, not individually?
        //if call currently connected and open don't need to do anything here
        var calltitle = call.calltitle
        var buddy:ChatBuddyModel?
        if calltitle == nil {
            var jid = XMPPJID(string: call.caller!)
            if (call.outgoing) {
                //NSArray *receivers = [call.receiver componentsSeparatedByString:@","];
                jid = XMPPJID(string: call.receiver!)
            }
            buddy = ChatBuddyModel.fetchBuddyModel(jid: jid!, accountUniqueId: account.uniqueId)
            if (buddy != nil) {
                calltitle = buddy?.displayName
            }
        }
        
        guard let calltitle = calltitle else { return nil }
        
        if readyToPresent == true {
            self.openVideoCallController(calltitle)
            if let callVC = self.callWindow?.rootViewController?.presentedViewController as? VideoCallViewController {
                callVC.doConnectCall(call, with:calltitle)
            }
        }
        
        if let csysMessage = call.systemMessage {
            DispatchQueue.global().async {
                var thread:ChatThreadModel?
                var message:MessageProtocol?
                
                if let buddy = buddy {
                    thread = ChatThreadModel.getChatThread(uniqueId: buddy.uniqueId)
                    message = buddy.outgoingMessage(text: csysMessage)
                } else {
                    let after = "conference.\(account.domain!)"
                    //let groupname = calltitle.suffix(calltitle.count-1)
                    let groupjid = "\(calltitle)@\(after)"
                    let databaseRoomKey = ChatRoomModel.createUniqueId(account.uniqueId, jid: groupjid)
                    if let room = ChatRoomModel.getXMPPRoom(uniqueId: databaseRoomKey) {
                        thread = ChatThreadModel.getChatThread(uniqueId: room.uniqueId)
                        message = room.outgoingMessage(text: csysMessage)
                    }
                }
                 
                if let thread = thread, let message = message {
                    message.messageSecurity = .plaintext
                    
                    if let systemMsg = message as? OutgoingChatMessage {
                        systemMsg.grdbRecord?.systemUpdate = true
                        systemMsg.grdbRecord?.dateSent = Date()
                        systemMsg.grdbRecord?.readDate = Date()
                        systemMsg.grdbRecord?.originalText = csysMessage
                        systemMsg.save(withThread: thread)
                    } else if let systemMsg = message as? ChatRoomMessageModel {
                        systemMsg.grdbRecord?.state = ChatRoomMessageState.sent.rawValue
                        systemMsg.grdbRecord?.systemUpdate = true
                        systemMsg.grdbRecord?.originalText = csysMessage
                        systemMsg.save(withThread: thread)
                    }
                    //thread.saveThread()
                }
            }
        }
        
        return calltitle
    }

    private func activeWindowScene() -> UIWindowScene? {
        if let scene = self.window?.windowScene {
            return scene
        }
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene,
               scene.activationState != .unattached {
                return windowScene
            }
        }
        return nil
    }

    func addSystemMessage(_ message:String, with callerJid:String, with username:String) {

        let str = "\(message) from \(username)"
        if message.starts(with: ChatRoomMessage.StringConstants.incomingCall.text) == false {
            UIApplication.shared.showLocalNotificationWith(identifier: nil, body: str, badge: 0, userInfo: nil, recurring: false)
        }

        // Hold a background task across the async DB write so iOS can't suspend us
        // mid-transaction (which would trigger 0xDEAD10CC from the held SQLCipher
        // lock). Both the message insert and the chatThread row bump happen inside
        // a single asyncWrite — its completion fires after the transaction commits
        // and the lock is released, so it is safe to end the bgTask there.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "addSystemMessage") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        DispatchQueue.global().async {
            guard let account = self.getFirstAccount(), let jid = XMPPJID(string: callerJid), let buddy = ChatBuddyModel.fetchBuddyModel(jid: jid, accountUniqueId: account.uniqueId), let systemMsg = buddy.outgoingMessage(text: message) as? OutgoingChatMessage else {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
                return
            }

            systemMsg.messageSecurity = .plaintext
            systemMsg.grdbRecord?.systemUpdate = true
            systemMsg.grdbRecord?.dateSent = Date()
            systemMsg.grdbRecord?.readDate = Date()
            systemMsg.grdbRecord?.originalText = message

            // Save the message AND bump the thread row's messageDate in one
            // transaction so the conversation list re-sorts. The two-write
            // pattern via ChatThread.update is unsafe here because its second
            // write fires after the bgTask ends, and iOS often suspends us
            // before it runs when a call ends in the background.
            let threadUniqueId = buddy.uniqueId
            let acctId = account.accountId
            DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                systemMsg.grdbRecord?.grdbSave(transaction: transaction)
                do {
                    var threadRec = try ChatThread
                        .filter(Column("uniqueId") == threadUniqueId)
                        .fetchOne(transaction.database)

                    // Create the one-on-one thread if the caller has no existing
                    // conversation yet (e.g. right after a fresh login). Mirrors the
                    // create-if-missing branch in MessageStorage.getThread so an
                    // incoming call surfaces a thread the same way a first incoming
                    // message does. Done inside this same transaction so the message
                    // insert and the new thread row commit atomically under the held
                    // SQLCipher lock.
                    if threadRec == nil {
                        var newThread = ChatThread(uniqueId: threadUniqueId)
                        newThread.messageDate = systemMsg.messageDate
                        newThread.isGroupThread = false
                        newThread.lastMessageId = systemMsg.uid
                        newThread.accountUniqueId = acctId
                        newThread.modified = Date()
                        newThread.grdbSave(transaction: transaction)
                        threadRec = try ChatThread
                            .filter(Column("uniqueId") == threadUniqueId)
                            .fetchOne(transaction.database)
                    }

                    if var threadRec = threadRec {
                        threadRec.messageDate = systemMsg.messageDate
                        threadRec.lastMessageId = systemMsg.uid
                        threadRec.modified = Date()
                        threadRec.grdbSave(transaction: transaction)

                        // Link the buddy to the (possibly new) thread row so
                        // buddy.chatThread resolves, consistent with
                        // MessageStorage.getThread.
                        if buddy.chatThreadId == -1, let ctid = threadRec.id, var bud = buddy.grdbRecord {
                            bud.chatThreadId = ctid
                            try bud.update(transaction.database, columns: [Column("chatThreadId")])
                        }
                    }
                } catch {
                    DDLogError("addSystemMessage thread update error: \(error)")
                }
            }, completion: {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            })
        }
    }

    func addSystemGroupMessage(_ messagetext:String, with groupTitle:String) {
        guard isMainInterfaceReady(), let xacct = self.getFirstAccount() else { return }

        let str = "\(messagetext) from \(groupTitle)"
        UIApplication.shared.showLocalNotificationWith(identifier: nil, body: str, badge: 0, userInfo: nil, recurring: false)

        let after = "conference.\(xacct.domain!)"
        let groupjid = "\(groupTitle)@\(after)"
        let databaseRoomKey = ChatRoomModel.createUniqueId(xacct.uniqueId, jid: groupjid)

        // See addSystemMessage for the rationale: the message insert and the
        // chatThread row bump must happen in one asyncWrite so the SQLCipher
        // lock is released before the bgTask ends and so the conversation list
        // re-sorts even when the call ends in the background.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "addSystemGroupMessage") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        if let room = ChatRoomModel.getXMPPRoom(uniqueId: databaseRoomKey), let systemMsg = room.outgoingMessage(text: messagetext) as? ChatRoomMessageModel, let _ = ChatThreadModel.getChatThread(uniqueId: databaseRoomKey) {
            systemMsg.messageSecurity = .plaintext
            systemMsg.grdbRecord?.state = ChatRoomMessageState.sent.rawValue
            systemMsg.grdbRecord?.systemUpdate = true
            systemMsg.grdbRecord?.originalText = messagetext

            DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                systemMsg.grdbRecord?.grdbSave(transaction: transaction)
                do {
                    if var threadRec = try ChatThread
                        .filter(Column("uniqueId") == databaseRoomKey)
                        .fetchOne(transaction.database) {
                        threadRec.messageDate = systemMsg.messageDate
                        threadRec.lastMessageId = systemMsg.uid
                        threadRec.modified = Date()
                        threadRec.grdbSave(transaction: transaction)
                    }
                } catch {
                    DDLogError("addSystemGroupMessage thread update error: \(error)")
                }
            }, completion: {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            })
        } else {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }
    
    func getFirstAccount() -> ChatAccountModel? {
        if let acct = conversationViewController.getFirstAccount() {
            return acct
        }
        
        var firstacct:ChatAccountModel?
        let accounts = ChatAccountModel.allXMPPAccounts()
        if accounts.count >= 1 {
            firstacct = accounts.first
        }
        
        return firstacct
    }
}

extension GlacierAppDelegate: SecurityUpdateDel {
    // mark SecurityUpdateDelegate Methods
    public func securityInfoUpdated(_ success:Bool) {
        self.secInfoUpdated(success)
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension GlacierAppDelegate: UNUserNotificationCenterDelegate {
    
    private func extractNotificationType(notification: UNNotification) -> NotificationType? {
        let userInfo = notification.request.content.userInfo
        if let rawNotificationType = userInfo[kGlacierNotificationType] as? String {
            return NotificationType(rawValue: rawNotificationType)
        } else if userInfo[kNotificationTwilioType] is String { //we use the key here for NotificationType also, not the value
            return NotificationType(rawValue: kNotificationTwilioType)
        } else {
            return nil
        }
    }

    private func extractThreadInformation(notification: UNNotification) -> (key: String, collection: String)? {
        let userInfo = notification.request.content.userInfo
        if let threadKey = userInfo[kGlacierNotificationThreadKey] as? String,
            let threadCollection = userInfo[kGlacierNotificationThreadCollection] as? String {
            return (threadKey, threadCollection)
        }
        return nil
    }
    
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        
        /*if GlacierAppDelegate.isTestFlight == true {
            let crumb = Breadcrumb(level: .info, category: "push")
            crumb.message = "Push notification tapped"
            NSLog("*****DBG %@", crumb.message ?? "")
            SentrySDK.addBreadcrumb(crumb)
        }*/
        
        guard let notificationType = extractNotificationType(notification: response.notification) else {
            completionHandler()
            return
        }
        
        let appd = GlacierAppDelegate.appDelegate
        switch notificationType {
        case .subscriptionRequest:
            splitViewCoordinator.showConversationsViewController()
        case .connectionError:
            break
        case .chatMessage, .approvedBuddy:
            appd.window?.rootViewController = appd.splitViewCoordinator.splitViewController
            if let threadInfo = extractThreadInformation(notification: response.notification) {
                enterThread(key: threadInfo.key, collection: threadInfo.collection)
            }
            break
        case .smsMessage:
            //switch to SMS tab and go to conversation check above too if on SMS tab
            if appd.smsEnabled == false {
                appd.setSMSEnabled(true)
            }
            appd.window?.rootViewController = appd.smsSplitViewCoordinator.splitViewController
            TwilioBackendManager.sharedMgr().handleNotification(notification: response.notification)
            if let threadInfo = extractThreadInformation(notification: response.notification) {
                enterSMSThread(key: threadInfo.key, collection: threadInfo.collection)
            }
            break
        case .voicemail:
            appd.window?.rootViewController = appd.dialerViewController
            //self.navigationController!.viewControllers.first
            if let dialer = appd.dialerViewController.viewControllers.first as? DialerViewController { dialer.vmButtonPressed()
            }
            break
        }
        
        completionHandler()
    }
    
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard let notificationType = extractNotificationType(notification: notification) else {
            // unknown notification type, so let's show one just in case?
            completionHandler([.badge, .sound, .banner, .list])
            return
        }
        
        switch notificationType {
        case .subscriptionRequest:
            completionHandler([.badge, .sound, .banner, .list])
        case .approvedBuddy:
            completionHandler([.badge, .sound, .banner, .list])
        case .connectionError:
            completionHandler([.badge, .sound, .banner, .list])
        case .smsMessage:
            if let (key, _) = extractThreadInformation(notification: notification) {
                GlacierAppDelegate.visibleSMSThread({ (tkey) in
                    if key == tkey {
                        completionHandler([])
                    } else {
                        completionHandler([.badge, .sound, .banner, .list])
                    }
                })
            }
        case .voicemail:
            completionHandler([.badge, .sound, .banner, .list])
        case .chatMessage:
            if !self.doubleDone {
                return;
            }
            
            // Show chat notification while user is using the app, if they aren't already looking at it
            if let (key, _) = extractThreadInformation(notification: notification) {
                GlacierAppDelegate.visibleThread({ (tkey, _) in
                    if key == tkey {
                        completionHandler([])
                    } else {
                        completionHandler([.badge, .sound, .banner, .list])
                    } 
                })
            }
        }
    }
}

extension GlacierAppDelegate: PKPushRegistryDelegate {
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        if type == .voIP {
            self.handleVoipPushToken(pushCredentials.token)
        }
    }
    
    @objc public func handleVoipPushToken(_ token: Data) {
        //let tokString = token.toHexString()
        GlacierProtocolManager.pushController.setVoipToken(token)
        CallManager.sharedCallManager().credentialsUpdated(token)
    }
    
    open func pushRegistry(_ registry: PKPushRegistry,
                              didReceiveIncomingPushWith payload: PKPushPayload,
                              for type: PKPushType,
                              completion: @escaping () -> Void) {
        /*if GlacierAppDelegate.isTestFlight == true {
            let crumb = Breadcrumb(level: .info, category: "push")
            crumb.message = "VoIP Push received"
            NSLog("*****DBG %@", crumb.message ?? "")
            SentrySDK.addBreadcrumb(crumb)
        }*/
        
        var completionCalled = false
        let completeOnce: () -> Void = {
            if completionCalled {
                return
            }
            completionCalled = true
            completion()
        }

        guard type == .voIP else {
            completeOnce()
            return
        }

        var awaitingAsyncCompletion = false

        if type == .voIP {
            //if UIApplication.shared.applicationState == .background {
            //AND NOT TWILIO key:twi_message_type, twilio.voice.call
            let userInfo = payload.dictionaryPayload
            
            if let jsonData = try? JSONSerialization.data(withJSONObject: userInfo, options: [.prettyPrinted]),
                let jsonString = String(data: jsonData, encoding: .utf8) {
                // DDLogInfo("***** Received VoIP push payload:\n\(jsonString)")
            } else {
                // DDLogInfo("***** Received VoIP push payload (raw): \(userInfo)")
            }
            
            //print("***** userInfo: \(userInfo)")
            
            var twilioVoiceCall = false
            if let type = userInfo[kNotificationTwilioType] as? String, type == kNotificationTwilioVoiceCall {
                twilioVoiceCall = true
            }
            
            if let caller = userInfo[kNotificationCallerKey] as? String, let callId = userInfo[kNotificationCallIdKey] as? NSNumber, let uuidstr = userInfo[kNotificationRoomnameKey] as? String, let uuid = UUID(uuidString: uuidstr) {

                // DDLogInfo("***** didReceiveIncomingPushWith \(uuidstr)")
                let isDuplicate = self.handledCallIDs.contains(uuidstr)
                if !isDuplicate {
                    handledCallIDs.add(uuidstr)
                }

                awaitingAsyncCompletion = true
                CallManager.sharedCallManager().reportIncomingCallFromNotification(uuid: uuid, callId: callId.stringValue, caller: caller, suppressBusy: isDuplicate) { _ in
                    // reportNewIncomingCall has already been called; safe to start XMPP login now.
                    if UIApplication.shared.applicationState != .active, self.isProxyDetected() == false {
                        DispatchQueue.global().async {
                            if let account = ChatAccountModel.firstAccount() {
                                // DDLogInfo("***** received VoIP push and about to login.")
                                self.voipNotification = true
                                // Don't gate on isAccountIdConnected: a VoIP-push wake means we
                                // were suspended, so the XMPP socket is likely half-open (reports
                                // connected but is dead on the next write). Force a fresh, bounded
                                // reconnect so the JMI signaling channel is actually live for the
                                // call — the foreground status timer that normally owns retries is
                                // not running here (see ensureConnectedForIncomingCall).
                                GlacierProtocolManager.shared.ensureConnected(forIncomingCall: account)
                            }
                        }
                    }
                    completeOnce()
                }
            } else if let status = userInfo[kNotificationCallStatusKey] as? String, let callId = userInfo[kNotificationCallIdKey] as? NSNumber {
                if status == "accept" || status == "reject" || status == "busy" {
                    awaitingAsyncCompletion = true
                    CallManager.sharedCallManager().reportMAMCallResponse(callId: callId.stringValue, status: status) { _ in
                        // Always call the completion handler when done.
                        completeOnce()
                    }
                }
            } else if twilioVoiceCall == true {
                /*if self.handledCallIDs.contains(uuidstr) {
                    // DDLogInfo("***** Duplicate VoIP push for call ID: \(uuidstr), ignoring.")
                    completion()
                    return
                }
                handledCallIDs.add(uuidstr)*/
                
                //looks like Twilio library wants to get called first
                // Twilio's SDK reports the incoming call to CallKit itself (via callInviteReceived
                // -> reportIncomingCall, or reportPlaceholderCallAndEnd on the cancel/unparseable
                // paths), so the contract is satisfied by the SDK's delegate callback; mark handled
                // so the placeholder safety net below does not also fire. Log the payload shape so a
                // future 0xBAADCA11 here can be traced to the exact push that slipped through.
                if GlacierAppDelegate.isTestFlight {
                    DDLogInfo("VoIP push routed to Twilio SDK. Payload keys: \(Array(userInfo.keys))")
                }
                awaitingAsyncCompletion = true
                CallManager.sharedCallManager().incomingCallReceived(callInfo: userInfo)
                completeOnce()
            }

            if !awaitingAsyncCompletion {
                // We received a .voIP push but none of the branches above reported a call
                // (e.g. an unexpected or malformed payload). iOS 13+ kills the app (0xBAADCA11)
                // if a VoIP push completes without reportNewIncomingCall, so satisfy the contract
                // by reporting a placeholder call and immediately ending it.
                //
                // This should essentially never happen with a well-formed p2 ring, so log the
                // payload shape: if this ever fires in production it means a malformed/unexpected
                // VoIP push is reaching the handler (points at a server payload issue to chase).
                DDLogError("VoIP push did not resolve to a reportable call; reporting placeholder to satisfy CallKit contract. Payload keys: \(Array(userInfo.keys)) status=\(String(describing: userInfo[kNotificationCallStatusKey])) callIdType=\(String(describing: userInfo[kNotificationCallIdKey].map { Swift.type(of: $0) }))")
                awaitingAsyncCompletion = true
                CallManager.sharedCallManager().reportPlaceholderCallAndEnd {
                    completeOnce()
                }
            }
        }
    }
}
