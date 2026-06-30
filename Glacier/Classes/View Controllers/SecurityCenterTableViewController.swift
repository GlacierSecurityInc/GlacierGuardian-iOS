//
//  SecurityCenterTableViewController.swift
//  Glacier
//
//  Created by andyfriedman on 3/1/22.
//  Copyright © 2022 Glacier. All rights reserved.
//

import UIKit
import Alamofire
import LocalAuthentication
import IOSSecuritySuite
import NetworkExtension

open class SecurityCenterTableViewController: UITableViewController {
    
    @IBOutlet weak var coreConnectionCell: UITableViewCell!
    @IBOutlet weak var bioLockCell: UITableViewCell!
    @IBOutlet weak var screenLockCell: UITableViewCell!
    @IBOutlet weak var systemSafeCell: UITableViewCell!
    @IBOutlet weak var latestVersionCell: UITableViewCell!
    @IBOutlet var securityTable: UITableView!
    
    var securityDelegate: SecurityCenterDelegate?
    let internalQueue = DispatchQueue(label: "SecCenter Queue")
    let sessionManager = Alamofire.Session(configuration: URLSessionConfiguration.ephemeral, serverTrustManager: GlacierPinningConfiguration.makeServerTrustManager())
    fileprivate var context = LAContext()
    let coreManager = WireGuardManager.shared().tunnelsManager
    var issuesFound = false
    
    func getLatestVersions() {
        if let versions = AWSAcctManager.sharedMgr().getLatestVersions() {
            self.handleVersions(versions: versions)
        }
    }
    
    func handleVersions(versions: LatestVersions) {
        let curVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        
        DispatchQueue.main.async {
            //check our Glacier version vs latest
            var gversionissue = false
            var iversionissue = false
            if let myVersion = curVersion, let latestVersion = versions.glacier, myVersion.compare(latestVersion, options: .numeric) == .orderedAscending {
                gversionissue = true
            }
        
            //check our iOS version vs latest
            if let latestios = versions.ios, self.iOS_VERSION_LESS_THAN(version: latestios) {
                iversionissue = true
            }
            
            if gversionissue || iversionissue {
                if var latestContent = self.latestVersionCell.contentConfiguration as? UIListContentConfiguration {
                    latestContent.secondaryTextProperties.numberOfLines = 0
                    latestContent.secondaryTextProperties.color = .red
                    if gversionissue && iversionissue {
                        latestContent.secondaryText = "Both Guardian and iOS are not up to date"
                    } else if gversionissue {
                        latestContent.secondaryText = "Guardian is not up to date"
                    } else if iversionissue {
                        latestContent.secondaryText = "iOS is not up to date"
                    }
                    
                    if let notlatest = UIImage(named: "glaciersecure_disabled", in: GlacierInfo.resourcesBundle, compatibleWith: nil) {
                        latestContent.image = notlatest
                    }
                    
                    latestContent.imageProperties.maximumSize = CGSize(width: 30, height: 30)
                    self.latestVersionCell.contentConfiguration = latestContent
                }
                
                GlacierAppDelegate.appDelegate.settingsViewController.setVersionIssue(true)
                if self.issuesFound == false {
                    self.issuesFound = true
                }
            } else {
                if var latestContent = self.latestVersionCell.contentConfiguration as? UIListContentConfiguration {
                    latestContent.secondaryTextProperties.numberOfLines = 0
                    latestContent.secondaryText = "Guardian and iOS up to date"
                    latestContent.secondaryTextProperties.color = .label
                    self.latestVersionCell.contentConfiguration = latestContent
                }
                GlacierAppDelegate.appDelegate.settingsViewController.setVersionIssue(false)
            }
            
            if let delegate = self.securityDelegate {
                delegate.secureSummaryUpdated(isSecure: !self.issuesFound)
            }
        }
    }
    
    public func setSecurityCenterDelegate(delegate: SecurityCenterDelegate) {
        self.securityDelegate = delegate
    }
    
    func iOS_VERSION_LESS_THAN(version: String) -> Bool {
        return UIDevice.current.systemVersion.compare(version, options: .numeric) == ComparisonResult.orderedAscending
    }
    
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if (indexPath.row == 4) {
            self.gotoCore()
        }
    }
    
    open override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
    
    private func gotoCore() {
        let storyboard = UIStoryboard(name: "CoreConnection", bundle: GlacierInfo.resourcesBundle)
        if let vc = storyboard.instantiateViewController(withIdentifier: "coreConnection") as? CoreConnectionViewController {
            self.navigationController?.pushViewController(vc, animated: true)
        }
    }
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        securityTable.sectionHeaderTopPadding = CGFloat(2)
        securityTable.estimatedSectionFooterHeight = CGFloat(0)
        securityTable.sectionFooterHeight = CGFloat(0)
        securityTable.estimatedRowHeight = CGFloat(80)
        securityTable.rowHeight = UITableView.automaticDimension
        
        //self.doSecurityChecks() //moved to ViewDidAppear
    }
    
    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.doSecurityChecks()
    }
    
    public func doSecurityChecks() {
        self.issuesFound = false
        self.getLatestVersions()
        
        if var coreContent = coreConnectionCell.contentConfiguration as? UIListContentConfiguration, var bioContent = bioLockCell.contentConfiguration as? UIListContentConfiguration, var screenContent = screenLockCell.contentConfiguration as? UIListContentConfiguration, var systemContent = systemSafeCell.contentConfiguration as? UIListContentConfiguration, var latestContent = latestVersionCell.contentConfiguration as? UIListContentConfiguration {
            coreContent.imageProperties.maximumSize = CGSize(width: 30, height: 30)
            bioContent.imageProperties.maximumSize = CGSize(width: 30, height: 30)
            screenContent.imageProperties.maximumSize = CGSize(width: 30, height: 30)
            systemContent.imageProperties.maximumSize = CGSize(width: 30, height: 30)
            latestContent.imageProperties.maximumSize = CGSize(width: 30, height: 30)
            
            coreContent.secondaryTextProperties.numberOfLines = 0
            bioContent.secondaryTextProperties.numberOfLines = 0
            screenContent.secondaryTextProperties.numberOfLines = 0
            systemContent.secondaryTextProperties.numberOfLines = 0
            latestContent.secondaryTextProperties.numberOfLines = 0
            
            latestVersionCell.contentConfiguration = latestContent
                
            if !deviceBiometricsEnabled() {
                bioContent.secondaryText = "Biometric lock is disabled"
                if let nobio = UIImage(named: "biometric_lock_disabled", in: GlacierInfo.resourcesBundle, compatibleWith: nil) {
                    bioContent.image = nobio
                }
            } else {
                if ( context.biometryType == .faceID ) {
                    bioContent.secondaryText = "Face ID enabled"
                } else if ( context.biometryType == .touchID) {
                    bioContent.secondaryText = "Touch ID enabled"
                } else { // Stone Age
                    bioContent.secondaryText = "Biometrics enabled"
                }
                if let bio = UIImage(named: "biometric_lock", in: GlacierInfo.resourcesBundle, compatibleWith: nil) {
                    bioContent.image = bio
                }
            }
            bioLockCell.contentConfiguration = bioContent
            
            if !devicePasscodeEnabled() {
                screenContent.secondaryText = "Screen lock is disabled"
                screenContent.secondaryTextProperties.color = .red
                issuesFound = true
                if let noscreenlock = UIImage(named: "screen_lock_disabled", in: GlacierInfo.resourcesBundle, compatibleWith: nil) {
                    screenContent.image = noscreenlock
                }
            } else {
                screenContent.secondaryText = "Screen lock enabled"
                screenContent.secondaryTextProperties.color = .label
                if let screenlock = UIImage(named: "screen_lock", in: GlacierInfo.resourcesBundle, compatibleWith: nil) {
                    screenContent.image = screenlock
                }
            }
            screenLockCell.contentConfiguration = screenContent
                
            var shielded = true
            if IOSSecuritySuite.amIJailbroken() {
                systemContent.secondaryText = "Shows signs of being jailbroken"
                shielded = false
            } else if IOSSecuritySuite.amIProxied() {
                systemContent.secondaryText = "Shows signs of being proxied"
                shielded = false
            } else if IOSSecuritySuite.amIDebugged() {
                systemContent.secondaryText = "Shows signs of being debugged"
                //shielded = false
            } else if IOSSecuritySuite.amIReverseEngineered() {
                systemContent.secondaryText = "Shows signs of being reverse engineered"
                shielded = false
            } else if IOSSecuritySuite.amIRunInEmulator() {
                systemContent.secondaryText = "Shows signs of being run in emulator"
                shielded = false
            }
            
            if !shielded {
                issuesFound = true
                systemContent.text = "Your system might not be safe"
                systemContent.secondaryTextProperties.color = .red
                if let broken = UIImage(named: "shield_safe_disabled", in: GlacierInfo.resourcesBundle, compatibleWith: nil) {
                    systemContent.image = broken
                }
            } else {
                systemContent.text = "Your system is safe"
                systemContent.secondaryTextProperties.color = .label
                if let unbroken = UIImage(named: "shield_safe", in: GlacierInfo.resourcesBundle, compatibleWith: nil) {
                    systemContent.image = unbroken
                }
            }
            systemSafeCell.contentConfiguration = systemContent
            
            let coreon = self.coreManager?.isTunnelEnabled() ?? false 
            if !coreon {
                coreContent.secondaryText = "Core is disabled"
                if let nocore = UIImage(named: "core_connection_disabled", in: GlacierInfo.resourcesBundle, compatibleWith: nil) {
                    coreContent.image = nocore
                }
            } else {
                coreContent.secondaryText = "Core enabled"
                if let coreon = UIImage(named: "core_connection", in: GlacierInfo.resourcesBundle, compatibleWith: nil) {
                    coreContent.image = coreon
                }
            }
            coreConnectionCell.contentConfiguration = coreContent
        }
        
        if self.issuesFound, let delegate = self.securityDelegate {
            delegate.secureSummaryUpdated(isSecure: false)
        }
        
    }
    
    public func devicePasscodeEnabled() -> Bool {
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
        
    public func deviceBiometricsEnabled() -> Bool {
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }
    
    public func rapidResponseEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: "AutomaticSecurityResponsesEnabled")
    }
}
