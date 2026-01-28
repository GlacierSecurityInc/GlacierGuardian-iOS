//  ChatSecureCore
//  Created by Chris Ballinger on 12/5/17.
//  Copyright © 2017 Chris Ballinger. All rights reserved.

import Foundation
import UserNotifications
import CocoaLumberjack
import PushKit
import MBProgressHUD
import GRDB
import Amplify
import AWSAPIPlugin
import AWSCognitoAuthPlugin
import AWSS3StoragePlugin
import MetricKit
import os.log

public extension OTRAppDelegate {
    @objc func setupAmplify() {
        if UIApplication.shared.isProtectedDataAvailable {
            configureAmplifyIfNeeded()
            Task {
                await tryFetchSession()
            }
        } else {
            NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                self.configureAmplifyIfNeeded()
                Task {
                    await self.tryFetchSession()
                }
            }
        }
    }
    
    @objc static var isTestFlight: Bool {
        guard let url = Bundle.main.appStoreReceiptURL else { return true }
        // TestFlight and StoreKit sandbox receipts end with "sandboxReceipt"
        return url.lastPathComponent == "sandboxReceipt" ||
                url.path.contains("sandboxReceipt")
    }
    
    private func tryFetchSession() async {
        let signedIn = await AWSAcctManager.sharedMgr().fetchCurrentAuthSession()
            
        if signedIn == false, self.conversationViewController.getFirstAccount() != nil {
            //needs re-login for backend. Set flag to handle login appropriately in AWSAcctManager
            self.conversationViewController.setWelcomeController(true)
        }
    }

    private func configureAmplifyIfNeeded() {
        guard !self.amplifyIsConfigured else { return }

        do {
            try Amplify.add(plugin: AWSAPIPlugin())
            try Amplify.add(plugin: AWSCognitoAuthPlugin())
            try Amplify.add(plugin: AWSS3StoragePlugin())
            try Amplify.configure()
            self.amplifyIsConfigured = true
            print("Amplify configured successfully.")
        } catch {
            print("Failed to initialize Amplify: \(error)")
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
        guard OTRAppDelegate.isTestFlight else { return }

        let hangFiles = HangStore.shared.loadAll()
        guard !hangFiles.isEmpty else { return }

        let rooms = ChatRoomModel.allXMPPRooms()
        guard let room = rooms.first(where: { $0.threadName.localizedCaseInsensitiveContains("GlacierHangs") && $0.joined }) else {
            return
        }
        guard let accountId = room.accountUniqueId,
              OTRProtocolManager.sharedInstance().isAccountIdConnected(accountId),
              let account = ChatAccountModel.getXMPPAccount(uniqueId: accountId),
              let xmppManager = OTRProtocolManager.shared.xmppManager(forChatAccount: account) else {
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

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.glacier.Messenger",
                                category: "MetricKit")

    private override init() {
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
        logger.info("MetricKit subscriber added")
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }


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

public extension OTRAppDelegate {
    
    /// Returns key/collection of visible thread, or nil if not visible or unset
    @objc static func visibleThread(_ block: @escaping (_ tkey: String?, _ tcollection: String?)->(), completionQueue: DispatchQueue? = nil) {
        DispatchQueue.main.async {
            //IOSM#104 added isActive
            guard UIApplication.shared.applicationState == .active else {
                block(nil, nil)
                return
            }
            
            var prekey:String?
            var precoll:String?
            
            let chatVC = OTRAppDelegate.appDelegate.chatViewController
            let roomVC = OTRAppDelegate.appDelegate.chatRoomViewController
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
    
    //IOSM#102
    @objc static func visibleSMSThread(_ block: @escaping (_ tkey: String?)->(), completionQueue: DispatchQueue? = nil) {
        DispatchQueue.main.async {
            let smsMessagesVC = OTRAppDelegate.appDelegate.smsMessagesViewController
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
        let conversationsVC = OTRAppDelegate.appDelegate.conversationViewController
        let hud = MBProgressHUD.showAdded(to: conversationsVC.view, animated: true)
        
        let singleMessagesToMarkAsRead: [ChatMessageModel] = ChatMessageModel.getUnreadMessages()
        let roomMessagesToMarkAsRead: [ChatRoomMessageModel] = ChatRoomMessageModel.getUnreadMessages()
            
        //IOSM-443
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
                
                //IOSM-443 maybe only send once...if toBeSaved has objects
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
                
                //IOSM-443
                if let roomjid = message.grdbRecord?.roomJid, message.isMarkable == true {
                    roomConversationsForReadReceipts[roomjid] = message
                }
            }
        })
            
        //IOSM-443
        if let account = ChatAccountModel.firstAccount(), let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount:account) {
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
    
    //IOSM#103
    @objc func enterSMSThread(key: String, collection: String) {
        if let smsthread = SMSChatConversationModel.getConversation(with: key) {
            //should probably also switch to account
            
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
        if self.callWindow == nil {
            self.callWindow = UIWindow(frame: UIScreen.main.bounds)
        }
        
        if self.callWindow?.rootViewController == nil {
            let screenSize = UIScreen.main.bounds.size
            self.callWindow?.frame = CGRectMake(0, 0, screenSize.width, screenSize.height)
            
            let storyboard = UIStoryboard(name: "VideoCall", bundle: GlacierInfo.resourcesBundle)
            if let callVC = storyboard.instantiateViewController(withIdentifier: "VideoCallVC") as? VideoCallViewController, let account = ChatAccountModel.firstAccount(), let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount:account) {
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
    
    internal func openPhoneCallController(_ callContact:PhoneContact) {
        //do title here? Related to incoming call number/name/contact
        if self.callWindow == nil {
            self.callWindow = UIWindow(frame: UIScreen.main.bounds)
        }
        
        if (self.callWindow?.rootViewController == nil) {
            let screenSize = UIScreen.main.bounds.size
            self.callWindow?.frame = CGRectMake(0, 0, screenSize.width, screenSize.height)
            
            let storyboard = UIStoryboard(name: "PhoneCall", bundle: GlacierInfo.resourcesBundle)
            if let callVC = storyboard.instantiateViewController(withIdentifier: "PhoneCallVC") as? VoiceCallViewController, let account = ChatAccountModel.firstAccount(), let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount:account) {
                xmpp.callManager.setGlacierCallDelegate(callVC)
                callVC.setCallManager(xmpp.callManager)
                callVC.setContact(callContact)
                callVC.modalPresentationStyle = .overCurrentContext
                
                self.callWindow?.rootViewController = UIViewController()
                self.callWindow?.makeKeyAndVisible()
                
                self.callWindow?.rootViewController?.present(callVC, animated: true)
            }
        }
    }
}

extension OTRAppDelegate: SecurityUpdateDel {
    // mark SecurityUpdateDelegate Methods
    public func securityInfoUpdated(_ success:Bool) {
        self.secInfoUpdated(success)
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension OTRAppDelegate: UNUserNotificationCenterDelegate {
    
    private func extractNotificationType(notification: UNNotification) -> NotificationType? {
        let userInfo = notification.request.content.userInfo
        if let rawNotificationType = userInfo[kOTRNotificationType] as? String {
            return NotificationType(rawValue: rawNotificationType)
        } else if userInfo[kNotificationTwilioType] is String {
            return NotificationType(rawValue: kNotificationTwilioType)
        } else {
            return nil
        }
    }

    private func extractThreadInformation(notification: UNNotification) -> (key: String, collection: String)? {
        let userInfo = notification.request.content.userInfo
        if let threadKey = userInfo[kOTRNotificationThreadKey] as? String,
            let threadCollection = userInfo[kOTRNotificationThreadCollection] as? String {
            return (threadKey, threadCollection)
        }
        return nil
    }
    
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        guard let notificationType = extractNotificationType(notification: response.notification) else {
            completionHandler()
            return
        }
        
        let appd = OTRAppDelegate.appDelegate
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
                OTRAppDelegate.visibleSMSThread({ (tkey) in
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
                OTRAppDelegate.visibleThread({ (tkey, _) in
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

extension OTRAppDelegate: PKPushRegistryDelegate {
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        if type == .voIP {
            self.handleVoipPushToken(pushCredentials.token)
        }
    }
    
    @objc public func handleVoipPushToken(_ token: Data) {
        OTRProtocolManager.pushController.setVoipToken(token)
        CallManager.sharedCallManager().credentialsUpdated(token)
    }
    
    open func pushRegistry(_ registry: PKPushRegistry,
                              didReceiveIncomingPushWith payload: PKPushPayload,
                              for type: PKPushType,
                              completion: @escaping () -> Void) {
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
            let userInfo = payload.dictionaryPayload
            
            if let jsonData = try? JSONSerialization.data(withJSONObject: userInfo, options: [.prettyPrinted]),
                let jsonString = String(data: jsonData, encoding: .utf8) {
                DDLogDebug("***** Received VoIP push payload:\n\(jsonString)")
            } else {
                DDLogDebug("***** Received VoIP push payload (raw): \(userInfo)")
            }
            
            
            var twilioVoiceCall = false
            if let type = userInfo[kNotificationTwilioType] as? String, type == kNotificationTwilioVoiceCall {
                twilioVoiceCall = true
            }
            
            if UIApplication.shared.applicationState != .active, !twilioVoiceCall, self.isProxyDetected() == false {
                DispatchQueue.global().async {
                    if let account = ChatAccountModel.firstAccount(), OTRProtocolManager.shared.isAccountIdConnected(account.uniqueId) == false {
                        self.voipNotification = true
                        OTRProtocolManager.shared.loginAccount(account)
                    }
                }
            }
            
            if let caller = userInfo[kNotificationCallerKey] as? String, let callId = userInfo[kNotificationCallIdKey] as? NSNumber, let uuidstr = userInfo[kNotificationRoomnameKey] as? String, let uuid = UUID(uuidString: uuidstr) {

                DDLogInfo("***** didReceiveIncomingPushWith \(uuidstr)")
                let isDuplicate = self.handledCallIDs.contains(uuidstr)
                if !isDuplicate {
                    handledCallIDs.add(uuidstr)
                }

                awaitingAsyncCompletion = true
                CallManager.sharedCallManager().reportIncomingCallFromNotification(uuid: uuid, callId: callId.stringValue, caller: caller, suppressBusy: isDuplicate) { _ in
                    // Always call the completion handler when done.
                    completeOnce()
                }
            } else if let status = userInfo[kNotificationCallStatusKey] as? String, let callId = userInfo[kNotificationCallIdKey] as? NSNumber { //IOSM-569
                if status == "accept" || status == "reject" || status == "busy" {
                    awaitingAsyncCompletion = true
                    CallManager.sharedCallManager().reportMAMCallResponse(callId: callId.stringValue, status: status) { _ in
                        // Always call the completion handler when done.
                        completeOnce()
                    }
                }
            } else if twilioVoiceCall == true {
                //looks like Twilio library wants to get called first
                CallManager.sharedCallManager().incomingCallReceived(callInfo: userInfo)
                completeOnce()
            }

            if !awaitingAsyncCompletion {
                completeOnce()
            }
        }
    }
}
