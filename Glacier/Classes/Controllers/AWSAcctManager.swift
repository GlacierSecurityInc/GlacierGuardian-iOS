//
//  AWSAcctManager.swift
//  Glacier
//
//  Created by andyfriedman on 11/27/24.
//  Copyright © 2024 Glacier. All rights reserved.
//

import Foundation
import Amplify
import AWSCognitoAuthPlugin
import AWSPluginsCore
import SAMKeychain
import os.log

/// Outcome of a Cognito session check.
///
/// `indeterminate` is the important one: "we could not tell" is not the same as
/// "signed out", and collapsing the two is what makes a perfectly good install
/// throw up a login screen after a network blip or a slow keychain read.
///
/// The two sign-in cases are kept apart because they warrant different copy —
/// `tokensInvalid` means the user did nothing wrong and something changed under
/// them, so it earns an explanation before the login screen appears.
public enum GlacierAuthSessionState {
    case signedIn
    /// No credentials at all; the plugin reports signed out.
    case noSession
    /// Credentials exist but the tokens cannot be used — issued by a retired App
    /// Client ID, or the refresh token has expired.
    case tokensInvalid
    case indeterminate
}

/// Outcome of `refreshXMPPCredentials`. `signedOut` is kept apart from `failed`
/// because it is the one failure no retry can fix: /glacier-users only answers a
/// valid Cognito access token, so until the user signs in again there is no way to
/// get an xmpp_token, and on a JWT-only server no way to log in to XMPP at all.
@objc public enum GlacierCredentialRefreshResult: Int {
    case refreshed
    case failed
    case signedOut
}

public extension Notification.Name {
    /// Posted on the main queue after a Cognito sign-in has written fresh XMPP
    /// credentials onto an existing account, so a stream parked on `signedOut` can
    /// reconnect without a relaunch.
    static let glacierXMPPCredentialsUpdated = Notification.Name("GlacierXMPPCredentialsUpdated")
}

public protocol OrgUpdateDel: AnyObject {
    func orgInfoUpdated()
}

public protocol SecurityUpdateDel {
    func securityInfoUpdated(_ success:Bool)
}

public protocol VPNStorageListener {
    func handleNoStorageAccess()
    func handleNoCoreProfiles()
    func endLogin()
}

@objc open class AWSAcctManager: NSObject
{
    private static let shared = AWSAcctManager()
    private var orgUpdateDelegates:[OrgUpdateDel] = []
    private var secUpdateDelegate:SecurityUpdateDel?
    private var vpnStorageListener:VPNStorageListener?
    private let backendHelper = BackendHelper.shared()
    private var vpnOnly = false
    private var reauthNeeded = false
    let workQueue = DispatchQueue(label: "AWS Queue")
    private var proxyDetected = false
    
    private var userName:String?
    private var bucketOrg:String?
    private var deviceId:String?

    /// Identity handed from the login flow to first-time onboarding.
    ///
    /// `fetchUserData` learns the JID and display name from /glacier-users, and
    /// `tryGlacierGroupAccount` needs them a few calls later to build the ChatAccount:
    /// fetchUserData -> endLogin -> endAuthLogin -> lookForAccountInfoIfNeeded. That is one
    /// synchronous chain in one process, so it never needed to travel through the shared
    /// app-group plist - where it then stayed for the life of the install, backup and all
    /// (GUA 02). Held in memory instead, so it goes when the process does.
    ///
    /// Deliberately *not* cleared the moment onboarding reads it. If the login that
    /// follows fails, the account is never saved, and onboarding runs again from the top -
    /// so clearing on first read would strand the retry on the welcome screen. Nothing is
    /// written to disk either way, so keeping it for the session costs nothing.
    @objc public private(set) var stagedUsername: String?
    @objc public private(set) var stagedDisplayName: String?

    /// Dropped on sign-out, along with the rest of the session identity.
    @objc public func clearStagedIdentity() {
        stagedUsername = nil
        stagedDisplayName = nil
    }

    /// The organization id, from the live Cognito session if we have one and from the
    /// account record otherwise.
    ///
    /// The fallback matters: `bucketOrg` is only populated by `fetchAttributes`, which needs
    /// a valid session, so the callers that need an org in order to *repair* a session -
    /// `refreshXMPPCredentials` above all - would otherwise find nothing exactly when they need it.
    /// This used to fall back to the app group's "orgid"; it reads the ChatAccount record
    /// now, which is SQLCipher-backed and so is not recoverable from an unencrypted backup
    /// (GUA 02).
    @objc public var currentOrganization: String? {
        if let org = self.bucketOrg, org.count > 0 {
            return org
        }
        if let org = ChatAccountModel.firstAccount()?.grdbRecord?.org, org.count > 0 {
            return org
        }
        return nil
    }
    
    private var coreRegionsList:[String]?
    private var wgProfiles:[URL] = []
    private var glacierOrgInfo:GlacierOrg?
    private var latestVersions:LatestVersions?
    private var coreGroup:DispatchGroup?
    
    public let userData = UserData()
    private var unsubscribeToken:UnsubscribeToken?
    
    //private var user:AWSCognitoIdentityUser?
    
    @objc public class func sharedMgr() -> AWSAcctManager {
        return shared
    }
    
    @objc override public init() {
        super.init()
        self.setupDownloadDirectory()
        //self.initAWSConnection()
        //self.getOrgData()
        
        unsubscribeToken = Amplify.Hub.listen(to: .auth) { payload in
            switch payload.eventName {
            case HubPayload.EventName.Auth.signedIn:
                print("User signed in")
                self.userData.isSignedIn = true
                Task {
                    await self.fetchAttributes()
                }
                
                // check waiting for login flag?
                // get user info
                // get Organization
                // query backend

            case HubPayload.EventName.Auth.sessionExpired:
                print("Session expired")
                // Re-authenticate the user

            case HubPayload.EventName.Auth.signedOut:
                print("User signed out")
                // Update UI

            case HubPayload.EventName.Auth.userDeleted:
                print("User deleted")
                // Update UI

            default:
                break
            }
        }
    }
    
    func updateUI(forSignInStatus : Bool) {
        DispatchQueue.main.async() {
            self.userData.isSignedIn = forSignInStatus
        }
    }

    func fetchCurrentAuthSession() async -> Bool {
        return await resolveAuthSessionState() == .signedIn
    }

    /// Resolves whether the Cognito session is actually usable, separating a real
    /// sign-out from a check that simply could not complete. Only `.noSession` and
    /// `.tokensInvalid` justify putting a login prompt in front of the user.
    /// `loadAttributes: false` only classifies the session; it skips the
    /// fetchAttributes -> fetchUserData chain a signed-in result normally starts.
    func resolveAuthSessionState(retriesRemaining: Int = 2, loadAttributes: Bool = true) async -> GlacierAuthSessionState {
        if proxyDetected {
            return .indeterminate
        }

        do {
            let session = try await Amplify.Auth.fetchAuthSession()

            guard session.isSignedIn else {
                os_log("fetchAuthSession: not signed in", log: .auth, type: .default)
                self.updateUI(forSignInStatus: false)
                return .noSession
            }

            // isSignedIn only means credentials exist on disk. A session issued by
            // a retired App Client ID, or one whose refresh token has expired,
            // still reports true and fails only when the tokens are read.
            if let provider = session as? AuthCognitoTokensProvider,
               case .failure(let tokenError) = provider.getCognitoTokens() {
                switch tokenError {
                case .sessionExpired, .notAuthorized, .signedOut:
                    // Refresh tokens on this app client last 1096 days, so this is
                    // never routine expiry — it means revocation, a password reset,
                    // a disabled user, or a retired App Client ID. Log the
                    // underlying Cognito error; it is the only thing that tells
                    // those apart after the fact.
                    os_log("fetchAuthSession: tokens unusable (%{public}@) underlying=%{public}@, re-auth required",
                           log: .auth, type: .default,
                           tokenError.errorDescription,
                           String(describing: tokenError.underlyingError))
                    self.updateUI(forSignInStatus: false)
                    return .tokensInvalid
                default:
                    os_log("fetchAuthSession: token read failed transiently (%{public}@)",
                           log: .auth, type: .error, tokenError.errorDescription)
                    return .indeterminate
                }
            }

            os_log("fetchAuthSession: signed in", log: .auth, type: .info)
            self.updateUI(forSignInStatus: true)
            if loadAttributes {
                await self.fetchAttributes()
            }
            return .signedIn

        } catch let error as AuthError {
            // The plugin's state machine finishes configuring asynchronously;
            // asking too early throws invalidState. Retry instead of reporting a
            // sign-out that never happened.
            if case .invalidState = error, retriesRemaining > 0 {
                os_log("fetchAuthSession: auth plugin not ready, retrying (%d left)",
                       log: .auth, type: .info, retriesRemaining)
                try? await Task.sleep(nanoseconds: 750_000_000)
                return await resolveAuthSessionState(retriesRemaining: retriesRemaining - 1,
                                                     loadAttributes: loadAttributes)
            }
            os_log("fetchAuthSession failed: %{public}@",
                   log: .auth, type: .error, error.errorDescription)
            return .indeterminate
        } catch {
            os_log("fetchAuthSession unexpected error: %{public}@",
                   log: .auth, type: .error, String(describing: error))
            return .indeterminate
        }
    }
    
    func fetchAttributes() async {
        if proxyDetected {
            return
        }
        do {
            let attributes = try await Amplify.Auth.fetchUserAttributes()
            
            if self.userName == nil {
                let user = try await Amplify.Auth.getCurrentUser() 
                self.userName = user.username
            }
            
            if let orgattr = attributes.first(where: { $0.key.rawValue == "custom:organization" }) {
                self.bucketOrg = orgattr.value
                //self.fetchUserData()
            }
            
            if self.userName != nil, self.bucketOrg != nil {
                self.fetchUserData()
            }
            
            //print("User attributes - \(attributes)")
        } catch let error as AuthError{
            print("*** Fetching user attributes failed with error \(error)")
            self.endLogin()
        } catch {
            print("*** Unexpected error: \(error)")
            self.endLogin()
        }
    }
    
    func getGlacierEnablements() -> GlacierOrg? {
        return self.glacierOrgInfo
    }
    
    func getLatestVersions() -> LatestVersions? {
        return self.latestVersions
    }

    func handleNoUpdate() {
        self.secUpdateDelegate?.securityInfoUpdated(false)
    }
    
    func fetchUserData() {
        guard !proxyDetected else { return }
        guard let org = self.bucketOrg, let name = self.userName else { return }
        
        self.backendHelper.getGlacierUser(organization: org, username: name, completion: { (guser:GlacierUser?) in
            
            guard let guser = guser else {
                self.endLogin()
                return
            }
            /*if (guser == nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.awspauth stopSpinner];
                    [self alertWithTitle:@"No user info" message:@"Problems logging in."];
                    [self endLogin];
                });
                return
            }*/
            
            self.stagedUsername = guser.username
            self.stagedDisplayName = guser.displayName
                
            var error: NSError?
            let userid = UUID().uuidString
            _ = SAMKeychain.setPassword(userid, forService: kGlacierGroup, account: kGlacierAcct, accessGroup:kGlacierGroup, error:&error)
            if guser.password.count > 0 {
                let result = SAMKeychain.setPassword(guser.password, forService: kGlacierGroup, account: userid, accessGroup:kGlacierGroup, error:&error)
                if result == false {
                    DDLogError("Error saving password to keychain: \(String(describing: error?.localizedDescription)) \(String(describing: error?.userInfo))")
                }
            }

            // Stage the xmpp_token (if the backend returned one) alongside the
            // password under the same userid pointer but a distinct service, so
            // the login flow can prefer token-based (X-OAUTH2) ejabberd auth.
            if let token = guser.token, token.count > 0 {
                let tokenResult = SAMKeychain.setPassword(token, forService: kGlacierAccessTokenServiceName, account: userid, accessGroup:kGlacierGroup, error:&error)
                if tokenResult == false {
                    DDLogError("Error saving xmpp token to keychain: \(String(describing: error?.localizedDescription)) \(String(describing: error?.userInfo))")
                }
            }
            // Backfill the account's own keychain slots (kGlacierKeyGroup) that XMPP
            // auth actually reads from. The staging->slot bridge (tryGlacierGroupAccount)
            // only runs during first-time onboarding, so already-onboarded accounts
            // otherwise never see a new token, a removed token, or a rotated password.
            // Runs every cold launch, so it self-heals existing accounts.
            if let account = ChatAccountModel.firstAccount() {
                Self.applyXMPPCredentials(guser, to: account)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .glacierXMPPCredentialsUpdated, object: account)
                }
            }
            
            self.endLogin()
            self.getOrgData()
        })
    }
    
    func endLogin() {
        if vpnOnly {
            //vpnOnly = false
            self.vpnStorageListener?.endLogin()
            self.getS3Files()
            //self.vpnStorageListener = nil
        } else {
            DispatchQueue.main.async {
                if GlacierAppDelegate.appDelegate.isMainInterfaceReady() {
                    GlacierAppDelegate.appDelegate.conversationViewController.endAuthLogin()
                }
            }
        }
    }
    
    private func setupDownloadDirectory() {
        do {
            if #available(iOS 16.0, *) {
                let downloadsURL = URL(fileURLWithPath: NSTemporaryDirectory(),
                                 isDirectory: true).appending(path: "download")
                
                try FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
            }
        } catch {
            DDLogWarn("Creating 'download' directory failed: \(error)")
        }
    }
    
    public func teardownCognito() {
        self.userName = nil
        self.bucketOrg = nil
        self.glacierOrgInfo = nil
        self.clearStagedIdentity()
        Task {
            //let options = AuthSignOutRequest.Options()
            let _ = await Amplify.Auth.signOut()
        }
    }
    
    private func getOrgData() {
        guard let org = self.bucketOrg, let username = self.userName else { return }
        
        self.backendHelper.getGlacierOrganization(organization: org, username: username, completion: { (gorg:GlacierOrg?) in
            guard let gorg = gorg else { return }
            
            self.glacierOrgInfo = gorg
            self.updateOrgDelegates()
            
            DispatchQueue.main.async {
                GlacierAppDelegate.appDelegate.setSecurityHubEnabled(gorg.securityHubEnabled)
                if let secInfo = GlacierAppDelegate.appDelegate.settingsViewController.getLatestSecurityInfo() {
                    self.workQueue.async {
                        self.updateSecurityData(secInfo, force:true)
                    }
                }
            }
        })
    }
    
    private func getLatestVersionsData() {
        guard !proxyDetected else { return }
        self.backendHelper.getLatestVersion(key: "latest_versions", completion: { (versions:LatestVersions?) in
            self.latestVersions = versions
        })
    }
    
    public func updateSecurityData(_ secInfoUtil:SecurityInfoUtil, force:Bool) {
        guard !proxyDetected else {
            self.secUpdateDelegate?.securityInfoUpdated(false)
            return
        }
        guard let name = self.userName, let org = self.bucketOrg, let orgInfo = self.glacierOrgInfo else {
            secInfoUtil.setNeedsUpdate()
            self.secUpdateDelegate?.securityInfoUpdated(false)
            return
        }
        
        self.getLatestVersionsData()
        
        self.backendHelper.getAppInfo(organization: org, username: name, completion: { (secinfoList:[String]?, coreList:[String]?) in
            
            if let corelist = coreList {
                self.coreRegionsList = corelist
            }
            
            if orgInfo.securityHubEnabled == false {
                self.secUpdateDelegate?.securityInfoUpdated(false)
                return
            }
            
            if secinfoList == nil {
                secInfoUtil.setNeedsUpdate()
                self.secUpdateDelegate?.securityInfoUpdated(false)
                return
            } else if secinfoList?.count == 0 {
                secInfoUtil.setLastUpdated()
                let mysecdata = [secInfoUtil.getJson()]
                self.backendHelper.updateSecurityInfo(organization: org, username: name, securityInfo: mysecdata, completion: { (success:Bool) in
                    if success == false {
                        secInfoUtil.setNeedsUpdate()
                        self.secUpdateDelegate?.securityInfoUpdated(false)
                    } else {
                        self.secUpdateDelegate?.securityInfoUpdated(true)
                    }
                })
                
                return
            }
            
            guard let seclist = secinfoList else { return }
            
            var returnList:[String] = []
            var compromisedList:[String] = []
            let mydeviceid = secInfoUtil.securityInfo.deviceid
            var foundme = false
            for secinfo in seclist {
                if let json = self.getJsonObject(secinfo) {
                    let deviceid = json["deviceid"] as? String
                    //force should only relate to date. If force and found, update date
                    if mydeviceid == deviceid {
                        let compval = json["compromised"] as? Bool ?? false
                        
                        if secInfoUtil.equals(secinfo: json) {
                            if force == false {
                                return //no need to update, no change
                            }
                        } else if compval == true, secInfoUtil.securityInfo.compromised == false {
                            compromisedList.append(secinfo)
                        }
                        
                        secInfoUtil.setLastUpdated()
                        returnList.append(secInfoUtil.getJson())
                        foundme = true
                    } else {
                        returnList.append(secinfo)
                    }
                }
            }
            
            if compromisedList.isEmpty == false {
                for comp in compromisedList {
                    returnList.append(comp)
                }
            }
            
            if foundme == false {
                secInfoUtil.setLastUpdated()
                returnList.append(secInfoUtil.getJson())
            }
            
            if returnList.count > 0 {
                self.backendHelper.updateSecurityInfo(organization: org, username: name, securityInfo: returnList, completion: { (success:Bool) in
                    if success == false {
                        secInfoUtil.setNeedsUpdate()
                        self.secUpdateDelegate?.securityInfoUpdated(false)
                    } else {
                        self.secUpdateDelegate?.securityInfoUpdated(true)
                    }
                })
            }
        })
    }
    
    func getJsonObject(_ jsonString: String) -> Dictionary<String,Any>? {
        if let data = jsonString.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data, options : .allowFragments) as? Dictionary<String,Any> {
            DDLogDebug("getJsonObject: \(json)")
            return json
        }
        
        return nil
    }
    
    func addOrgDelegate(_ orgDelegate: OrgUpdateDel) {
        guard !orgUpdateDelegates.contains(where: { $0 === orgDelegate }) else { return }
        self.orgUpdateDelegates.append(orgDelegate)
    }
    
    private func updateOrgDelegates() {
        if let account = ChatAccountModel.firstAccount(), let gorgInfo = self.glacierOrgInfo {
            if (account.trackingEnabled != gorgInfo.trackingEnabled || account.trackingInterval != gorgInfo.trackingInterval || account.forceTracking != gorgInfo.forceTracking) {
                let wasForceTracking = account.forceTracking
                let willForceTracking = gorgInfo.forceTracking
                let willTrackingEnabled = gorgInfo.trackingEnabled
                
                if willTrackingEnabled && wasForceTracking && !willForceTracking {
                    account.trackingOn = true
                }
                
                account.trackingEnabled = gorgInfo.trackingEnabled
                account.trackingInterval = gorgInfo.trackingInterval
                account.forceTracking = gorgInfo.forceTracking
                self.workQueue.async {
                    account.saveXMPPAccount()
                    
                    for orgDel in self.orgUpdateDelegates {
                        orgDel.orgInfoUpdated()
                    }
                }
            } else {
                for orgDel in self.orgUpdateDelegates {
                    orgDel.orgInfoUpdated()
                }
            }
        } else {
            for orgDel in self.orgUpdateDelegates {
                orgDel.orgInfoUpdated()
            }
        }
    }
    
    private func getS3Files() {
        guard !proxyDetected else {
            //self.vpnStorageListener?.handleNoStorageAccess()
            return
        }
        if let org = self.bucketOrg, let account = ChatAccountModel.firstAccount(), let coreList = self.coreRegionsList, self.vpnOnly {
            if coreList.count > 0 {
                self.wgProfiles.removeAll()
                self.coreGroup = DispatchGroup()
                //var accessAvailable = true
                
                for coreinfo in coreList {
                    self.coreGroup?.enter()
                    guard let username = account.bareJID?.user else {
                        DDLogWarn("Could not get bareJID username for wireguard profile download")
                        self.coreGroup?.leave()
                        continue
                    }
                    
                    let downloadingFilePath = NSTemporaryDirectory().appendingPathComponent("download").appendingPathComponent(coreinfo)
                    let downloadingFileURL = NSURL.fileURL(withPath: downloadingFilePath)
                    
                    
                    if FileManager.default.fileExists(atPath: downloadingFilePath) {
                        self.wgProfiles.append(downloadingFileURL)
                        self.coreGroup?.leave()
                    } else {
                        
                        self.backendHelper.downloadWireguardProfile(
                            organization: org,
                            coreRegion: coreinfo,
                            username: username,
                            destinationURL: downloadingFileURL
                        ) { success in
                            if success {
                                print("Completed")
                                self.wgProfiles.append(downloadingFileURL)
                            } else {
                                DDLogWarn("wireguard webhook download failed for region \(coreinfo)")
                            }
                            self.coreGroup?.leave()
                        }
                    }
                }

                self.coreGroup?.notify(queue: DispatchQueue.main) {
                    self.vpnStorageListener?.endLogin()
                    if self.wgProfiles.count == 0 {
                        //if accessAvailable == false {
                        //    self.vpnStorageListener?.handleNoStorageAccess()
                        //} else {
                            self.vpnOnly = false
                            self.vpnStorageListener?.handleNoCoreProfiles()
                        //}
                    } else {
                        self.vpnOnly = false
                        WireGuardManager.shared().handleWireguardProfiles(self.wgProfiles)
                    }
                }
            } else {
                self.vpnStorageListener?.handleNoCoreProfiles()
            }
        } else {
            //[self.awspauth stopSpinner];
            self.vpnStorageListener?.handleNoStorageAccess()
            //self.vpnOnly = false
            DDLogError("Could not get s3 bucket due to no org, account, or coreRegionsList");
        }
    }
    
    public func addVPNConnection(_ listener:VPNStorageListener) {
        guard !proxyDetected else {
            //listener.handleNoStorageAccess()
            return
        }
        self.vpnStorageListener = listener
        self.vpnOnly = true
        
        if self.bucketOrg == nil {
            self.bucketOrg = self.currentOrganization
        }
        
        if self.userData.isSignedIn == false {
            Task {
                if await self.fetchCurrentAuthSession() {
                    self.getS3Files()
                } else {
                    self.vpnStorageListener?.handleNoStorageAccess()
                    //self.vpnOnly = false
                }
            }
        } else {
            self.getS3Files()
        }
    }

    @objc public func setProxyDetected(_ detected: Bool) {
        proxyDetected = detected
        BackendHelper.setRequestsBlocked(detected)
    }

    /// Re-reads the account's XMPP credentials from /glacier-users and makes the
    /// account match what the Console says now: the xmpp_token is stored when present
    /// and *removed* when absent, and glacierpwd replaces the stored password when it
    /// differs. Called after any SASL rejection, on either auth path:
    ///   - token path: the JWT expired (ejabberd only checks it at SASL time);
    ///   - password path: the server was switched to JWT-only while we were running.
    ///     Before this, the token only reached the account at cold launch
    ///     (fetchUserData), so a live process kept retrying the password forever.
    ///   - removing a stale token lets a server rolled back to passwords recover too.
    /// Completes on the main queue with `.refreshed` when the response carried at least
    /// one usable credential (so a reconnect is worth trying), `.signedOut` when the
    /// Cognito session is gone and only the user typing a password can fix it, and
    /// `.failed` for anything that may clear up by itself (network, backend).
    @objc public func refreshXMPPCredentials(for account: ChatAccountModel, completion: @escaping (GlacierCredentialRefreshResult) -> Void) {
        let finish: (GlacierCredentialRefreshResult) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        // The request failed; work out whether it was because there is no session.
        let finishFailed: () -> Void = { [weak self] in
            Task {
                let state = await self?.resolveAuthSessionState(loadAttributes: false)
                switch state {
                case .noSession, .tokensInvalid:
                    DDLogError("refreshXMPPCredentials: Cognito session is gone; sign-in required")
                    finish(.signedOut)
                default:
                    finish(.failed)
                }
            }
        }
        Task { [weak self] in
            guard let self = self else { finish(.failed); return }

            // Re-fetching the Cognito user also confirms the session is still
            // valid — the /glacier-users call is authed with those credentials.
            var name = self.userName
            if name == nil, let user = try? await Amplify.Auth.getCurrentUser() {
                name = user.username
                self.userName = user.username
            }
            let org = self.currentOrganization
            guard let org = org, let name = name else {
                DDLogError("refreshXMPPCredentials: missing org/username; cannot refresh")
                finishFailed()
                return
            }
            self.backendHelper.getGlacierUser(organization: org, username: name, completion: { guser in
                guard let guser = guser else {
                    DDLogError("refreshXMPPCredentials: /glacier-users request failed")
                    finishFailed()
                    return
                }
                let hasToken = Self.applyXMPPCredentials(guser, to: account)
                DDLogInfo("refreshXMPPCredentials: token=\(hasToken ? "YES" : "NO") password=\(guser.password.isEmpty ? "NO" : "YES")")
                finish((hasToken || !guser.password.isEmpty) ? .refreshed : .failed)
            })
        }
    }

    /// Writes a successful /glacier-users result onto the account's own keychain slots
    /// (the ones XMPP auth reads). Returns whether a token is now stored.
    @discardableResult
    static func applyXMPPCredentials(_ guser: GlacierUser, to account: ChatAccountModel) -> Bool {
        if let token = guser.token, !token.isEmpty {
            if account.accessToken != token {
                account.accessToken = token
            }
        } else if account.accessToken?.isEmpty == false {
            // The Console no longer issues a token for this user. Keeping the old one
            // would pin us to the token path against a server that may not take it.
            DDLogWarn("applyXMPPCredentials: /glacier-users returned no xmpp_token — removing the stored one")
            try? account.removeKeychainAccessToken(nil)
        }
        if !guser.password.isEmpty, account.password != guser.password {
            account.password = guser.password
        }
        return guser.token?.isEmpty == false
    }
}

public final class UserData: ObservableObject {
    @Published var isSignedIn : Bool = false
}

@objc public class GlacierUser:NSObject {
    @objc public let username:String
    @objc public var voiceext:String?
    @objc public let password:String
    @objc public var token:String?
    @objc public var organization:String?
    @objc public var displayName:String?

    @objc public init(username:String, voiceext:String, password:String, token:String?, org:String, displayname:String) {
        self.username = username
        self.voiceext = voiceext
        self.password = password
        self.token = token
        self.organization = org
        self.displayName = displayname
    }
}

@objc public class GlacierOrg:NSObject {
    @objc public var organization:String?
    @objc public var smsEnabled:Bool = false
    @objc public var securityHubEnabled:Bool = false
    @objc public var uploadEnabled:Bool = false
    @objc public var voicemailEnabled:Bool = false
    @objc public var trackingEnabled:Bool = false
    @objc public var trackingInterval:Int = 300
    @objc public var forceTracking:Bool = false
    
    @objc public init(org:String, smsEnabled:Bool, securityHubEnabled:Bool, uploadEnabled:Bool, voicemailEnabled:Bool, trackingEnabled:Bool, forceTracking:Bool, trackingFrequency:String) {
        self.organization = org
        self.smsEnabled = smsEnabled
        self.securityHubEnabled = securityHubEnabled
        self.uploadEnabled = uploadEnabled
        self.trackingEnabled = trackingEnabled
        self.forceTracking = forceTracking
        self.voicemailEnabled = voicemailEnabled
        self.trackingInterval = Int(trackingFrequency) ?? 300
    }
}

@objc public class LatestVersions:NSObject {
    @objc public var altOs:String?
    @objc public var altOsNew:String?
    @objc public var androidOs:String?
    @objc public var glacier:String?
    @objc public var glacierAndroid:String?
    @objc public var ios:String?
    
    @objc public init(altOs: String, altOsNew: String, androidOs: String, glacier: String, glacierAndroid: String, ios: String) {
        self.altOs = altOs
        self.altOsNew = altOsNew
        self.androidOs = androidOs
        self.glacier = glacier
        self.glacierAndroid = glacierAndroid
        self.ios = ios
    }
}
