//
//  GuardianPermissionManager.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import AVFoundation
import Contacts
import CoreLocation
import Foundation
import Network
import UIKit
import UserNotifications

/// The system permissions Guardian asks the user for.
@objc public enum GuardianPermissionKind: Int {
    case notifications
    case microphone
    case camera
    case localNetwork
    case contacts
    case location
}

@objc public enum GuardianPermissionStatus: Int {
    case notDetermined
    case granted
    case denied
}

/// Single owner of Guardian's system permission requests.
///
/// Its job is to make sure only one iOS permission prompt is ever in flight. Before
/// this existed the post-login path fired notifications, microphone, camera, local
/// network, contacts and location at once, and the user was handed an opaque stack of
/// system alerts to tap through. Every request now goes through one FIFO queue, so a
/// request raised from anywhere — including `TwilioBackendManager.fetchContacts`, whose
/// timing is decided by a backend response — waits its turn instead of interleaving.
///
/// The queue is driven on the main thread. `perform` hands back to `pumpQueue` only once
/// the underlying system callback has fired, which is what serialises the prompts.
public final class GuardianPermissionManager: NSObject {

    // MARK: - Public properties

    @objc public static let shared = GuardianPermissionManager()

    /// The order permissions are asked in when several are requested together.
    ///
    /// Microphone and camera sit near the front deliberately. They are the two that
    /// silently break an *incoming* call, and an incoming call cannot recover from them
    /// mid-call: `CallManager.reportCallConnected` only gets as far as an alert pointing
    /// at iOS Settings (`checkAudioPermissions`), and for the camera
    /// `VideoCallViewController.handleVideoDenied` says outright that changing it during
    /// a call drops the call. They have to be settled before the first call arrives.
    ///
    /// `.location` is last because it is the one kind this class does not drive itself —
    /// see `performLocation`.
    public static let canonicalOrder: [GuardianPermissionKind] = [
        .notifications, .microphone, .camera, .localNetwork, .contacts, .location
    ]

    // MARK: - Private properties

    private struct PendingRequest {
        let kind: GuardianPermissionKind
        /// How long to wait after this one resolves before raising the next prompt.
        let pacing: TimeInterval
        let completion: (GuardianPermissionStatus) -> Void
    }

    private var pending: [PendingRequest] = []
    private var isRequesting = false
    private var promptHoldCount = 0

    /// Used only to read `authorizationStatus`, which does not prompt. The instance that
    /// actually requests location lives in `LocationManager`.
    private let locationStatusReader = CLLocationManager()

    private let localNetworkProbedKey = "kGuardianLocalNetworkProbedKey"
    private let notificationStatusCacheKey = "kGuardianNotificationStatusCache"
    private let primerShownKey = "kGuardianPermissionsPrimerShown"

    /// Local network is re-probed once per launch even after the first time — see
    /// `performLocalNetwork`.
    private var hasProbedLocalNetworkThisLaunch = false

    /// Whether the post-login permissions primer has already been put in front of this
    /// user. It is shown once; after that the permissions they declined are recovered
    /// through Settings, not by asking again — iOS will not re-prompt anyway.
    public var hasShownPermissionsPrimer: Bool {
        get { UserDefaults.standard.bool(forKey: primerShownKey) }
        set { UserDefaults.standard.set(newValue, forKey: primerShownKey) }
    }

    // MARK: - Status

    /// Whether `status(for:)` reflects a real system answer for this kind.
    ///
    /// False for `.localNetwork` only: iOS exposes no way to query it. For that kind
    /// `.granted` means "we have probed, so the user has been asked" — not "allowed".
    public static func isStatusQueryable(_ kind: GuardianPermissionKind) -> Bool {
        return kind != .localNetwork
    }

    /// Current status, read from the system on every call rather than from a cache.
    ///
    /// iOS usually terminates the app when a privacy toggle is changed in Settings, so a
    /// cached value is worth very little — the user is most likely to come back through a
    /// cold launch, and anything that survived would be stale by definition.
    ///
    /// - Note: `.notifications` is the one kind iOS reports only asynchronously, so it is
    ///   served from the value recorded by the last `liveStatus(for:)` or `request`. Use
    ///   `liveStatus(for:completion:)` where the answer has to be current.
    public func status(for kind: GuardianPermissionKind) -> GuardianPermissionStatus {
        switch kind {
        case .notifications:
            guard let raw = UserDefaults.standard.object(forKey: notificationStatusCacheKey) as? Int,
                  let cached = GuardianPermissionStatus(rawValue: raw) else {
                return .notDetermined
            }
            return cached

        case .microphone:
            if #available(iOS 17.0, *) {
                switch AVAudioApplication.shared.recordPermission {
                case .undetermined: return .notDetermined
                case .granted: return .granted
                case .denied: return .denied
                @unknown default: return .denied
                }
            } else {
                switch AVAudioSession.sharedInstance().recordPermission {
                case .undetermined: return .notDetermined
                case .granted: return .granted
                case .denied: return .denied
                @unknown default: return .denied
                }
            }

        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined: return .notDetermined
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            @unknown default: return .denied
            }

        case .localNetwork:
            return UserDefaults.standard.bool(forKey: localNetworkProbedKey) ? .granted : .notDetermined

        case .contacts:
            // Written as tests rather than a switch because `.limited` only exists on
            // iOS 18, and naming it in a case would need availability around the switch.
            let status = CNContactStore.authorizationStatus(for: .contacts)
            if status == .notDetermined { return .notDetermined }
            if status == .authorized { return .granted }
            // Partial access is still enough to put a name to a number.
            if #available(iOS 18.0, *), status == .limited { return .granted }
            return .denied

        case .location:
            switch locationStatusReader.authorizationStatus {
            case .notDetermined: return .notDetermined
            case .authorizedWhenInUse, .authorizedAlways: return .granted
            case .denied, .restricted: return .denied
            @unknown default: return .denied
            }
        }
    }

    /// Always-current status. Identical to `status(for:)` except for `.notifications`,
    /// which is fetched from `UNUserNotificationCenter` and re-cached.
    public func liveStatus(for kind: GuardianPermissionKind,
                           completion: @escaping (GuardianPermissionStatus) -> Void) {
        guard kind == .notifications else {
            let status = self.status(for: kind)
            onMain { completion(status) }
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = Self.status(from: settings.authorizationStatus)
            self.cacheNotificationStatus(status)
            self.onMain { completion(status) }
        }
    }

    /// Every permission that applies to this account, answered or not, in
    /// `canonicalOrder`.
    public func applicablePermissions() -> [GuardianPermissionKind] {
        return Self.canonicalOrder.filter { isApplicable($0) }
    }

    /// The permissions that apply to this account and have not been answered yet.
    ///
    /// Returned in `canonicalOrder`, so the result can be handed straight to
    /// `requestSequentially`. An empty result means there is nothing left to ask.
    public func neededPermissions(completion: @escaping ([GuardianPermissionKind]) -> Void) {
        // Refresh the notification cache first so the synchronous reads below are current.
        liveStatus(for: .notifications) { _ in
            let queued = Set(self.pending.map { $0.kind.rawValue })
            let kinds = Self.canonicalOrder.filter { kind in
                guard self.status(for: kind) == .notDetermined else { return false }
                // Something in the app has actually asked for this one, which is better
                // evidence that it is in use than the org gate — the gate can still be
                // reading stale defaults when the backend has not answered yet.
                if queued.contains(kind.rawValue) { return true }
                return self.isApplicable(kind)
            }
            self.onMain { completion(kinds) }
        }
    }

    /// Current status of every applicable permission, with the asynchronous one refreshed
    /// first so the whole list is consistent. Completion is on the main thread.
    public func refreshStatuses(
        completion: @escaping ([(kind: GuardianPermissionKind, status: GuardianPermissionStatus)]) -> Void
    ) {
        liveStatus(for: .notifications) { _ in
            let rows = self.applicablePermissions().map {
                (kind: $0, status: self.status(for: $0))
            }
            self.onMain { completion(rows) }
        }
    }

    /// Whether a permission is relevant to this account at all.
    ///
    /// Two of them are provisioned per organisation rather than being universal, and
    /// asking for either outside those orgs would be asking for something Guardian will
    /// never use.
    private func isApplicable(_ kind: GuardianPermissionKind) -> Bool {
        switch kind {
        case .contacts:
            // Contacts exist to name and dial phone numbers, which is the SMS/voice
            // product. Read from the same places, in the same order, as the location gate
            // below — the org enablements fetched at login, then what the account last
            // recorded — with the live flag first for the case where `parseNumbers` has
            // already answered for this session.
            if GlacierAppDelegate.appDelegate.smsEnabled { return true }
            if let orgSMSEnabled = AWSAcctManager.sharedMgr().getGlacierEnablements()?.smsEnabled {
                return orgSMSEnabled
            }
            return ChatAccountModel.allXMPPAccounts().first?.smsEnabled ?? false
        case .location:
            return LocationManager.shared().isTrackingAvailable()
        default:
            return true
        }
    }

    // MARK: - Requesting

    /// Queue a single permission request. Completion is called on the main thread.
    public func request(_ kind: GuardianPermissionKind,
                        completion: ((GuardianPermissionStatus) -> Void)? = nil) {
        onMain {
            if self.canSkipQueue(kind) {
                self.perform(kind) { status in
                    self.onMain { completion?(status) }
                }
                return
            }

            // Already queued: attach to that one rather than asking twice and, more to
            // the point, rather than adding a second prompt somewhere else in the order.
            if let index = self.pending.firstIndex(where: { $0.kind == kind }) {
                let existing = self.pending[index]
                self.pending[index] = PendingRequest(
                    kind: kind,
                    pacing: existing.pacing,
                    completion: { status in
                        existing.completion(status)
                        completion?(status)
                    }
                )
                return
            }

            self.pending.append(PendingRequest(kind: kind, pacing: 0, completion: { completion?($0) }))
            self.pumpQueue()
        }
    }

    /// Whether this request can run straight away instead of taking its turn.
    ///
    /// The queue exists to stop prompts stacking, so a request that cannot raise one has
    /// no reason to wait behind another. Only local network qualifies: its "request" is a
    /// connection attempt rather than a prompt API, so once the user has been asked it is
    /// just a connection. That matters on the JMI-propose path, which probes when an
    /// incoming call arrives — queueing it would park it behind a login-time run of
    /// prompts, which is the delay the fallback exists to avoid.
    /// Note this deliberately ignores `promptHoldCount`: a hold exists to keep prompts
    /// from appearing, and by definition nothing that reaches here can raise one.
    private func canSkipQueue(_ kind: GuardianPermissionKind) -> Bool {
        return kind == .localNetwork && UserDefaults.standard.bool(forKey: localNetworkProbedKey)
    }

    @objc public func request(_ kind: GuardianPermissionKind) {
        request(kind, completion: nil)
    }

    /// Queue several requests as one contiguous run, in the order given.
    ///
    /// The run takes the front of the queue, and any request already queued for one of
    /// its kinds is folded into it — the original caller still gets its callback, but the
    /// prompt appears where the run puts it rather than where that caller happened to
    /// land. Anything else already queued waits until the run is finished.
    ///
    /// Both matter because of `TwilioBackendManager.fetchContacts`, which `parseNumbers`
    /// triggers whenever the backend answers `queryForNumbers`. That timing is the
    /// network's to choose, so without this the contacts prompt can appear ahead of a
    /// run, or in the middle of one, while the user is looking at a list that says it
    /// comes later.
    ///
    /// - Parameters:
    ///   - pacing: a gap between one prompt being answered and the next appearing.
    ///     Without it iOS puts the next alert up the instant the last is dismissed, and
    ///     the screen behind — whose whole job is to say what is being asked and how far
    ///     along you are — never gets a frame in which to show any of it.
    ///   - progress: called as each one resolves, for a UI that shows per-row state.
    ///   - completion: called once, after the last one resolves.
    public func requestSequentially(_ kinds: [GuardianPermissionKind],
                                    pacing: TimeInterval = 0,
                                    progress: ((GuardianPermissionKind, GuardianPermissionStatus) -> Void)? = nil,
                                    completion: (() -> Void)? = nil) {
        guard !kinds.isEmpty else {
            onMain { completion?() }
            return
        }

        onMain {
            var remaining = kinds.count
            var run: [PendingRequest] = []
            var others = self.pending

            for kind in kinds {
                let superseded = others.filter { $0.kind == kind }
                others.removeAll { $0.kind == kind }

                run.append(PendingRequest(kind: kind, pacing: pacing, completion: { status in
                    superseded.forEach { $0.completion(status) }
                    progress?(kind, status)
                    remaining -= 1
                    if remaining == 0 {
                        completion?()
                    }
                }))
            }

            self.pending = run + others
            self.pumpQueue()
        }
    }

    // MARK: - Holding

    /// Stops the queue raising any further prompt until the matching `endHoldingPrompts`.
    /// Balanced, so nested holds are safe. Queued requests are not dropped, only delayed.
    ///
    /// The post-login primer needs its screen in front of the user before the first
    /// system alert, and being first in the queue is not enough to guarantee that:
    /// `doLogin` calls `doSecurityCheck` on its way through, which builds the settings
    /// table, which calls `PushController.checkPushNotifications` — all of it before the
    /// primer has even been decided on. Holding covers that and any other early caller
    /// instead of chasing them one at a time.
    public func beginHoldingPrompts() {
        onMain { self.promptHoldCount += 1 }
    }

    public func endHoldingPrompts() {
        onMain {
            guard self.promptHoldCount > 0 else { return }
            self.promptHoldCount -= 1
            self.pumpQueue()
        }
    }

    // MARK: - Queue

    private func pumpQueue() {
        guard promptHoldCount == 0 else { return }
        guard !isRequesting, !pending.isEmpty else { return }

        let next = pending.removeFirst()
        isRequesting = true

        perform(next.kind) { [weak self] status in
            guard let self = self else { return }
            self.onMain {
                self.isRequesting = false
                next.completion(status)

                guard next.pacing > 0 else {
                    self.pumpQueue()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + next.pacing) {
                    self.pumpQueue()
                }
            }
        }
    }

    private func perform(_ kind: GuardianPermissionKind,
                         completion: @escaping (GuardianPermissionStatus) -> Void) {
        switch kind {
        case .notifications: performNotifications(completion)
        case .microphone:    performMicrophone(completion)
        case .camera:        performCamera(completion)
        case .localNetwork:  performLocalNetwork(completion)
        case .contacts:      performContacts(completion)
        case .location:      performLocation(completion)
        }
    }

    // MARK: - Per-permission requests

    private func performNotifications(_ completion: @escaping (GuardianPermissionStatus) -> Void) {
        let center = UNUserNotificationCenter.current()

        center.getNotificationSettings { settings in
            let alreadyDetermined = (settings.authorizationStatus != .notDetermined)

            // requestAuthorization runs even when the answer is already known: it shows no
            // prompt in that case, but its completion is where the APNs re-registration
            // happens, and that token refresh has to run on every launch.
            let work = {
                center.requestAuthorization(options: [.badge, .alert, .sound]) { granted, error in
                    if let error = error {
                        DDLogError("Notification authorization failed: \(error.localizedDescription)")
                    }

                    let status: GuardianPermissionStatus = granted ? .granted : .denied
                    self.cacheNotificationStatus(status)

                    DispatchQueue.main.async {
                        let app = Application.shared
                        NotificationCenter.default.post(
                            name: Notification.Name(rawValue: GlacierUserNotificationsChanged),
                            object: app.delegate,
                            userInfo: nil
                        )
                        if granted {
                            app.registerForRemoteNotifications()
                        }
                        completion(status)
                    }
                }
            }

            // Only wait for the foreground when a prompt will actually appear. Gating the
            // already-determined case too would strand the APNs re-registration above on a
            // background launch, which is exactly when a messenger needs its token fresh.
            if alreadyDetermined {
                work()
            } else {
                self.whenActive(work)
            }
        }
    }

    private func performMicrophone(_ completion: @escaping (GuardianPermissionStatus) -> Void) {
        let work = {
            let handler: (Bool) -> Void = { granted in
                DispatchQueue.main.async { completion(granted ? .granted : .denied) }
            }
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission(completionHandler: handler)
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission(handler)
            }
        }

        if status(for: .microphone) == .notDetermined {
            whenActive(work)
        } else {
            work()
        }
    }

    private func performCamera(_ completion: @escaping (GuardianPermissionStatus) -> Void) {
        let work = {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted ? .granted : .denied) }
            }
        }

        if status(for: .camera) == .notDetermined {
            whenActive(work)
        } else {
            work()
        }
    }

    private func performContacts(_ completion: @escaping (GuardianPermissionStatus) -> Void) {
        let work = {
            CNContactStore().requestAccess(for: .contacts) { granted, error in
                if let error = error {
                    DDLogError("Contacts authorization failed: \(error.localizedDescription)")
                }
                DispatchQueue.main.async { completion(granted ? .granted : .denied) }
            }
        }

        if status(for: .contacts) == .notDetermined {
            whenActive(work)
        } else {
            work()
        }
    }

    /// iOS has no API to request local network access, and none to query it. The prompt
    /// appears as a side effect of the first attempt to reach a local address, so the
    /// probe below is the request.
    ///
    /// The probe is keyed per install rather than per login. It used to be keyed on
    /// `account.uniqueId + loginDate`, and `loginDate` is rewritten on every login, so it
    /// re-ran each time — harmless, since iOS remembers the answer and shows nothing the
    /// second time, but pointless.
    private func performLocalNetwork(_ completion: @escaping (GuardianPermissionStatus) -> Void) {
        let hasEverProbed = UserDefaults.standard.bool(forKey: localNetworkProbedKey)

        // There is nothing to read back from a probe, so `.granted` here means "the user
        // has been asked", not "allowed". See `isStatusQueryable`.
        let status: GuardianPermissionStatus = hasEverProbed ? .granted : .notDetermined

        guard !hasProbedLocalNetworkThisLaunch else {
            onMain { completion(status) }
            return
        }
        hasProbedLocalNetworkThisLaunch = true

        guard !hasEverProbed else {
            // Already asked once, so this raises no prompt. Re-probe anyway and do not
            // hold the queue for it: if the user has since run Reset Location & Privacy in
            // iOS, the permission is back to not-determined and this is what brings the
            // prompt back. Dropping the re-probe would leave that user with WebRTC
            // silently failing its local candidates until they place an outgoing call.
            LocalNetworkProbe.shared.probe {}
            onMain { completion(status) }
            return
        }

        UserDefaults.standard.set(true, forKey: localNetworkProbedKey)

        // First time only: this one does raise a prompt, so wait for the app to be
        // foregrounded and hold the queue until the probe has settled.
        whenActive {
            LocalNetworkProbe.shared.probe {
                DispatchQueue.main.async { completion(.granted) }
            }
        }
    }

    /// Location is the one kind this class does not drive itself.
    ///
    /// `LocationManager` owns the two-stage When-In-Use → Always escalation, the
    /// explanatory alert it puts up first, and the organisation gating around all of it.
    /// Duplicating any of that here would mean two primers for one permission. So this
    /// hands off and reports the status as it currently stands, without waiting for the
    /// user to answer — which is why `.location` is last in `canonicalOrder`: nothing is
    /// queued behind it, so returning early cannot let another prompt overlap.
    private func performLocation(_ completion: @escaping (GuardianPermissionStatus) -> Void) {
        LocationManager.shared().uiReadyForLocation()
        onMain { completion(self.status(for: .location)) }
    }

    // MARK: - Helpers

    private static func status(from authorization: UNAuthorizationStatus) -> GuardianPermissionStatus {
        switch authorization {
        case .notDetermined: return .notDetermined
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    private func cacheNotificationStatus(_ status: GuardianPermissionStatus) {
        UserDefaults.standard.set(status.rawValue, forKey: notificationStatusCacheKey)
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// Runs `work` on the main thread while the app is foregrounded, waiting for the next
    /// `didBecomeActive` if it is not.
    ///
    /// Without this a prompt raised from a background launch — `autoLoginFromBackground`
    /// reaches the push registration that way — can surface over whatever app the user is
    /// actually looking at, including iOS Settings while they are mid-way through
    /// granting something else.
    private func whenActive(_ work: @escaping () -> Void) {
        onMain {
            if UIApplication.shared.applicationState == .active {
                work()
                return
            }

            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                if let token = token {
                    NotificationCenter.default.removeObserver(token)
                }
                work()
            }
        }
    }
}

// MARK: - Local network probe

/// Opens a short-lived connection to the mDNS multicast address, purely so iOS raises the
/// local network prompt. Nothing is sent that anything listens for, and the reply — if any
/// — is discarded; reaching the wire is the whole point.
///
/// Moved here from `CallManager`, which is no longer the only caller.
private final class LocalNetworkProbe {

    static let shared = LocalNetworkProbe()

    private let queue = DispatchQueue(label: "LocalNetworkProbe")
    private var activeConnection: NWConnection?

    private init() {}

    /// Calls `completion` once the probe has settled — sent, failed, or timed out — so the
    /// permission queue can hold the next prompt back until this one has had its moment.
    func probe(completion: @escaping () -> Void) {
        let connection = NWConnection(host: "224.0.0.251", port: 5353, using: .udp)
        activeConnection = connection

        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            completion()
        }

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let payload = Data([0x00])
                connection.send(content: payload, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            case .failed, .cancelled:
                self?.activeConnection = nil
            default:
                break
            }
        }

        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            connection.cancel()
            if self?.activeConnection === connection {
                self?.activeConnection = nil
            }
            finish()
        }
    }
}
