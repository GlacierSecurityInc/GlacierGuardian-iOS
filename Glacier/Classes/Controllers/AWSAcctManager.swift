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
import AWSS3StoragePlugin

public protocol OrgUpdateDel {
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
    private var appSyncMgr = AppSyncMgr()
    private var vpnOnly = false
    private var reauthNeeded = false
    let workQueue = DispatchQueue(label: "AWS Queue")
    private var proxyDetected = false
    
    private var userName:String?
    private var bucketOrg:String?
    private var deviceId:String?
    
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
                // query backend through AppSync

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
        if proxyDetected {
            return false
        }
        do {
            let session = try await Amplify.Auth.fetchAuthSession()
            print("Is user signed in - \(session.isSignedIn)")
            self.updateUI(forSignInStatus: session.isSignedIn)
            
            if session.isSignedIn {
                await self.fetchAttributes()
                return true
            }  else { //else call authenticator? Or try to sign in?
                print("Not signed in")  //if userexists, get pass and autologin?
            }
            
        } catch let error as AuthError {
            print("Fetch session failed with error \(error)")
        } catch {
            print("Unexpected error: \(error)")
        }
        
        return false
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
                //self.getAppSyncData()
            }
            
            if self.userName != nil, self.bucketOrg != nil {
                self.getAppSyncData()
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
    
    func getAppSyncData() {
        guard !proxyDetected else { return }
        guard let org = self.bucketOrg, let name = self.userName else { return }
        
        let glacierDefaults = UserDefaults.init(suiteName: kGlacierGroup)
        if glacierDefaults?.string(forKey: "orgid") == nil {
            glacierDefaults?.set(org, forKey: "orgid")
        }
        //if glacierDefaults?.string(forKey: "username") == nil {
        //    glacierDefaults?.set(name, forKey: "username")
        //}
        
        self.appSyncMgr.getUserInfo(username: name, org: org, completion: { (guser:GlacierUser?) in
            
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
            
            glacierDefaults?.set(guser.displayName, forKey: "displayname")
            glacierDefaults?.set("none", forKey: "connection")
            glacierDefaults?.set(guser.username, forKey: "username")
            if guser.voiceext != nil, guser.voiceext!.count > 0 {
                glacierDefaults?.set(guser.voiceext!, forKey: "extension")
            }
                
            var error: NSError?
            let userid = UUID().uuidString
            _ = SAMKeychain.setPassword(userid, forService: kGlacierGroup, account: kGlacierAcct, accessGroup:kGlacierGroup, error:&error)
            let result = SAMKeychain.setPassword(guser.password, forService: kGlacierGroup, account: userid, accessGroup:kGlacierGroup, error:&error)
            if result == false {
                DDLogError("Error saving password to keychain: \(String(describing: error?.localizedDescription)) \(String(describing: error?.userInfo))")
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
                OTRAppDelegate.appDelegate.conversationViewController.endAuthLogin()
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
        Task {
            //let options = AuthSignOutRequest.Options()
            let _ = await Amplify.Auth.signOut()
        }
    }
    
    private func getOrgData() {
        guard let org = self.bucketOrg else { return }
        
        self.appSyncMgr.getOrgInfo(org: org, completion: { (gorg:GlacierOrg?) in
            guard let gorg = gorg else { return }
            
            self.glacierOrgInfo = gorg
            self.updateOrgDelegates()
            
            DispatchQueue.main.async {
                OTRAppDelegate.appDelegate.setSecurityHubEnabled(gorg.securityHubEnabled)
                if let secInfo = OTRAppDelegate.appDelegate.settingsViewController.getLatestSecurityInfo() {
                    self.workQueue.async {
                        self.updateAppSyncSecurityData(secInfo, force:true)
                    }
                }
            }
        })
    }
    
    private func getLatestVersionsData() {
        guard !proxyDetected else { return }
        self.appSyncMgr.getLatestVersionInfo(completion: { (versions:LatestVersions?) in
            self.latestVersions = versions
        })
    }
    
    public func updateAppSyncSecurityData(_ secInfoUtil:SecurityInfoUtil, force:Bool) {
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
        
        self.appSyncMgr.getAppInfo(username:name, org:org, completion: { (secinfoList:[String]?, coreList:[String]?) in
            
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
                self.appSyncMgr.sendSecurityInfo(username: name, org: org, secInfo: mysecdata, completion: { (success:Bool) in
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
                self.appSyncMgr.sendSecurityInfo(username: name, org: org, secInfo: returnList, completion: { (success:Bool) in
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
        self.orgUpdateDelegates.append(orgDelegate)
    }
    
    private func updateOrgDelegates() {
        if let account = ChatAccountModel.firstAccount(), let gorgInfo = self.glacierOrgInfo {
            if (account.trackingEnabled != gorgInfo.trackingEnabled || account.trackingInterval != gorgInfo.trackingInterval || account.forceTracking != gorgInfo.forceTracking || account.grdbRecord?.apiKey != gorgInfo.apikey) {
                account.trackingEnabled = gorgInfo.trackingEnabled
                account.trackingInterval = gorgInfo.trackingInterval
                account.forceTracking = gorgInfo.forceTracking
                account.grdbRecord?.apiKey = gorgInfo.apikey
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
            self.vpnStorageListener?.handleNoStorageAccess()
            return
        }
        if let org = self.bucketOrg, let account = ChatAccountModel.firstAccount(), let coreList = self.coreRegionsList, self.vpnOnly {
            if coreList.count > 0 {
                self.wgProfiles.removeAll()
                self.coreGroup = DispatchGroup()
                //var accessAvailable = true
                
                for coreinfo in coreList {
                    self.coreGroup?.enter()
                    let keyName = (account.bareJID?.user)! + ".conf"
                    //organizationconfigurations/org/region_core/user.conf
                    let s3path = org.appendingPathComponent(coreinfo).appendingPathComponent(keyName)
                    
                    let downloadingFilePath = NSTemporaryDirectory().appendingPathComponent("download").appendingPathComponent(coreinfo)
                    let downloadingFileURL = NSURL.fileURL(withPath: downloadingFilePath)
                    
                    
                    if FileManager.default.fileExists(atPath: downloadingFilePath) {
                        self.wgProfiles.append(downloadingFileURL)
                        self.coreGroup?.leave()
                    } else {
                        
                        let downloadTask = Amplify.Storage.downloadFile(
                            path: .fromString(s3path),
                            local: downloadingFileURL,
                            options: nil
                        )
                        
                        //organizationconfigurations/org/region_core/user.conf
                        Task {
                            do {
                                try await downloadTask.value
                                print("Completed")
                                self.wgProfiles.append(downloadingFileURL)
                                self.coreGroup?.leave()
                            } catch {
                                DDLogWarn("s3 download failed: \(error)")
                                //[self.awspauth stopSpinner];
                                //accessAvailable = false
                                self.coreGroup?.leave()
                            }
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
            self.vpnStorageListener?.handleNoStorageAccess()
            DDLogError("Could not get s3 bucket due to no org, account, or coreRegionsList");
        }
    }
    
    public func addVPNConnection(_ listener:VPNStorageListener) {
        guard !proxyDetected else {
            listener.handleNoStorageAccess()
            return
        }
        self.vpnStorageListener = listener
        self.vpnOnly = true
        
        if self.bucketOrg == nil {
            let glacierDefaults = UserDefaults.init(suiteName: kGlacierGroup)
            self.bucketOrg = glacierDefaults?.string(forKey: "orgid")
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
        AppSyncMgr.setRequestsBlocked(detected)
    }
}

public final class UserData: ObservableObject {
    @Published var isSignedIn : Bool = false
}
