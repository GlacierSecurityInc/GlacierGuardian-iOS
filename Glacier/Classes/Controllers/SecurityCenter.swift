//
//  SecurityCenter.swift
//  Glacier
//
//  Created by andyfriedman on 3/3/22.
//  Copyright © 2022 Glacier. All rights reserved.
//

import Foundation
//import Alamofire
import LocalAuthentication
import IOSSecuritySuite
import NetworkExtension

@objc open class SecurityCenter: NSObject {
    @objc
    public static let didCheckCompromised = Notification.Name("didCheckCompromised")
    fileprivate var context = LAContext()
    var needsNotification = false
    var versionNeedsNotification = false
    var lastVersionsCheck = Date.distantPast
    var compromisedStatus = false
    
    let DEVICE_ID = "device"
    let DEVICE = "deviceid"
    let GLACIER_VERSION = "glacier_version"
    let GLACIER_VERSION_OUTDATED = "glacier_version_outdated"
    let OS_VERSION = "os_version"
    let OS_VERSION_OUTDATED = "os_version_outdated"
    let OS_PATCH = "os_patch"
    let COMPROMISED = "compromised"
    let COMPROMISED_DETAIL = "compromised_detail"
    let SCREEN_LOCK = "screen_lock"
    let BIOMETRIC_LOCK = "biometric_lock"
    let CORE_ENABLED = "core_enabled"
    
    let COMPROMISED_JAILBROKEN = "jailbroken"
    let COMPROMISED_PROXIED = "proxied"
    let COMPROMISED_REVERSE_ENGINEERED = "reverse engineered"
    let COMPROMISED_RUN_IN_EMULATOR = "run in emulator"
    var ignoreCompromisedAlert = false
    var gotEnablements = false

    @objc var secInfoUtil = SecurityInfoUtil()
    
    //FOR TSTING
    /*private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    var isUsingWiFi: Bool = false
    @objc override public init() {
        super.init()
        
        monitor.pathUpdateHandler = { path in
            if path.status == .satisfied {
                self.isUsingWiFi = path.usesInterfaceType(.wifi)
            } else {
                self.isUsingWiFi = false
            }
        }
        monitor.start(queue: queue)
    }*/
    
    @objc public func doSettingsSecurityChecks() {
        self.needsNotification = false
        DispatchQueue.global().async {
            self.needsSettingsNotification()
        }
    }
    
    @objc public func isCompromised() -> Bool {
        let previousCompromisedStatus = self.compromisedStatus
        let previousCompromisedDetail = self.secInfoUtil.securityInfo.compromised_detail
        var compromised = false
        
        let jailStatus = IOSSecuritySuite.amIJailbrokenWithFailMessage()
        let extraJail = GlacierJailbreakChecks.run()
        // Ignore the EXPERIMENTAL pSelectFlag check: P_SELECT is set on any process
        // sitting in select()/poll() (normal networking), so it false-positives on
        // clean devices with "Suspicious PFlag value". See isReverseEngineered().
        let reFailedChecks = SecurityCenter.significantReverseEngineeringChecks()
        if jailStatus.jailbroken || extraJail.jailbroken {
            compromised = true
            var reasons: [String] = []
            if jailStatus.jailbroken { reasons.append(jailStatus.failMessage) }
            if extraJail.jailbroken { reasons.append(extraJail.indicators.joined(separator: ", ")) }
            let reason = " with reason: \(reasons.joined(separator: "; "))"
            self.secInfoUtil.securityInfo.compromised_detail = COMPROMISED_JAILBROKEN + reason
        } else if IOSSecuritySuite.amIProxied() {
            compromised = true
            self.secInfoUtil.securityInfo.compromised_detail = COMPROMISED_PROXIED
        //} else if IOSSecuritySuite.amIDebugged() {
        //    compromised = true
        } else if !reFailedChecks.isEmpty {
            compromised = true
            let reason = ": The following checks failed: \(reFailedChecks)"
            self.secInfoUtil.securityInfo.compromised_detail = COMPROMISED_REVERSE_ENGINEERED + reason
        } else if IOSSecuritySuite.amIRunInEmulator() {
            compromised = true
            self.secInfoUtil.securityInfo.compromised_detail = COMPROMISED_RUN_IN_EMULATOR
        } else {
            self.secInfoUtil.securityInfo.compromised_detail = "none"
        }
        
        /*if self.isUsingWiFi {
            compromised = true
            self.secInfoUtil.securityInfo.compromised_detail = COMPROMISED_PROXIED
        }*/
        
        self.compromisedStatus = compromised
        let compromisedDetail = self.secInfoUtil.securityInfo.compromised_detail
        if compromised && compromisedDetail == COMPROMISED_PROXIED {
            DispatchQueue.main.async {
                let appDelegate = GlacierAppDelegate.appDelegate
                if !appDelegate.isProxyDetected() {
                    appDelegate.setProxyDetected(true)
                }
            }
        } else if previousCompromisedStatus, previousCompromisedDetail == COMPROMISED_PROXIED {
            DispatchQueue.main.async {
                let appDelegate = GlacierAppDelegate.appDelegate
                if appDelegate.isProxyDetected() {
                    appDelegate.setProxyDetected(false)
                }
            }
        }
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: SecurityCenter.didCheckCompromised, object: self, userInfo: ["compromised":compromised, "detail": compromisedDetail ?? "none"])
        }
        
        return compromised
    }
    
    @objc public func getCurrentCompromisedStatus() -> Bool {
        return self.compromisedStatus
    }

    /// Reverse-engineering failed checks, excluding the EXPERIMENTAL `.pSelectFlag`
    /// check. That check reads P_SELECT, which the kernel sets on any process that is
    /// currently in a select()/poll() call, so it false-positives on clean devices
    /// ("Suspicious PFlag value"). Use this instead of IOSSecuritySuite's raw APIs.
    static func significantReverseEngineeringChecks() -> [FailedCheckType] {
        return IOSSecuritySuite.amIReverseEngineeredWithFailedChecks()
            .failedChecks
            .filter { $0.check != .pSelectFlag }
    }

    /// Whether the device shows real signs of reverse engineering, ignoring the
    /// pSelectFlag false positive. Replacement for IOSSecuritySuite.amIReverseEngineered().
    @objc public static func isReverseEngineered() -> Bool {
        return !significantReverseEngineeringChecks().isEmpty
    }
    
    @objc public func shouldIgnoreCompromisedAlert() -> Bool {
        return self.ignoreCompromisedAlert
    }
    
    @objc public func setIgnoreCompromisedAlert(_ ignore: Bool) {
        self.ignoreCompromisedAlert = ignore
    }
    
    @objc public func getNeedsSettingsNotification() -> Bool {
        return self.needsNotification
    }
    
    @objc private func needsSettingsNotification() {
        let compromised = isCompromised()
        if (compromised != self.secInfoUtil.securityInfo.compromised) {
            self.secInfoUtil.secinfoNeedsUpdate = true
        }
        self.secInfoUtil.securityInfo.compromised = compromised
        if compromised {  
            self.needsNotification = true
        }
        
        let devicePassEnabled = devicePasscodeEnabled()
        if (devicePassEnabled != self.secInfoUtil.securityInfo.screen_lock) {
            self.secInfoUtil.secinfoNeedsUpdate = true
        }
        self.secInfoUtil.securityInfo.screen_lock = devicePassEnabled
        if !devicePassEnabled {
            self.needsNotification = true
        }
        
        let biometricEnabled = deviceBiometricsEnabled()
        if (biometricEnabled != self.secInfoUtil.securityInfo.biometric_lock) {
            self.secInfoUtil.secinfoNeedsUpdate = true
        }
        self.secInfoUtil.securityInfo.biometric_lock = biometricEnabled
        
        self.handleUpdate()
        
        if Calendar.current.isDateInToday(self.lastVersionsCheck) {
            if self.versionNeedsNotification {
                self.needsNotification = true
            }
        } else {
            self.getLatestVersions()
        }
    }
    
    private func handleUpdate() {
        if self.secInfoUtil.secinfoNeedsUpdate == true {
            self.secInfoUtil.secinfoNeedsUpdate = false
            DispatchQueue.global().async {
                AWSAcctManager.sharedMgr().updateSecurityData(self.secInfoUtil, force: false)
            }
        } else {
            DispatchQueue.global().async {
                AWSAcctManager.sharedMgr().handleNoUpdate()
            }
        }
    }
    
    @objc public func getSecurityInfo() -> SecurityInfoUtil {
        return self.secInfoUtil
    }

    public func osUpdateAvailable() -> Bool {
        return false
    }
    
    public func getLatestVersions() {
        self.versionNeedsNotification = false
        if let versions = AWSAcctManager.sharedMgr().getLatestVersions() {
            self.handleVersions(versions: versions)
        }
        self.lastVersionsCheck = Date()
    }
    
    func handleVersions(versions: LatestVersions) {
        let curVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        
        //check our Glacier version vs latest
        if (curVersion != self.secInfoUtil.securityInfo.glacier_version) {
            self.secInfoUtil.secinfoNeedsUpdate = true
        }
        self.secInfoUtil.securityInfo.glacier_version = curVersion
        if let myVersion = curVersion, let latestVersion = versions.glacier, myVersion.compare(latestVersion, options: .numeric) == .orderedAscending {
            self.versionNeedsNotification = true
            
            if self.secInfoUtil.securityInfo.glacier_version_outdated == false {
                self.secInfoUtil.secinfoNeedsUpdate = true
            }
            self.secInfoUtil.securityInfo.glacier_version_outdated = true
        } else {
            if self.secInfoUtil.securityInfo.glacier_version_outdated == true {
                self.secInfoUtil.secinfoNeedsUpdate = true
            }
            self.secInfoUtil.securityInfo.glacier_version_outdated = false
        }
        
        //check our iOS version vs latest
        let osversion = UIDevice.current.systemVersion
        if osversion != self.secInfoUtil.securityInfo.os_version {
            self.secInfoUtil.secinfoNeedsUpdate = true
        }
        self.secInfoUtil.securityInfo.os_version = osversion
        
        if let latestios = versions.ios, self.iOS_VERSION_LESS_THAN(version: latestios) {
            self.versionNeedsNotification = true
            
            if self.secInfoUtil.securityInfo.os_version_outdated == false {
                self.secInfoUtil.secinfoNeedsUpdate = true
            }
            self.secInfoUtil.securityInfo.os_version_outdated = true
        } else {
            if self.secInfoUtil.securityInfo.os_version_outdated == true {
                self.secInfoUtil.secinfoNeedsUpdate = true
            }
            self.secInfoUtil.securityInfo.os_version_outdated = false
        }
        
        if self.versionNeedsNotification {
            self.needsNotification = true
        }
    }
    
    @objc public func setVersionIssue(_ versionIssue: Bool) {
        self.versionNeedsNotification = versionIssue
    }
    
    func iOS_VERSION_LESS_THAN(version: String) -> Bool {
        return UIDevice.current.systemVersion.compare(version, options: .numeric) == ComparisonResult.orderedAscending
    }
    
    @objc public func devicePasscodeEnabled() -> Bool {
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
        
    public func deviceBiometricsEnabled() -> Bool {
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }
}

@objc public class SecurityInfoUtil:NSObject {
    @objc var secinfoNeedsUpdate = false
    @objc var securityInfo: SecurityInfo
    
    @objc override public init() {
        self.securityInfo = SecurityInfo()
        self.securityInfo.deviceid = UIDevice.current.identifierForVendor?.uuidString
        
        //fill the basics
        self.securityInfo.device = UIDevice.modelName
        self.securityInfo.os_version = UIDevice.current.systemVersion
        self.securityInfo.glacier_version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        self.securityInfo.compromised_detail = "none"
        self.securityInfo.os_patch = "none"
        self.secinfoNeedsUpdate = true
        super.init()
    }
    
    @objc public func setNeedsUpdate() {
        self.secinfoNeedsUpdate = true
    }
    
    @objc public func setLastUpdated() {
        let lastupdated = Date().formatted(date: .complete, time: .standard).replacingOccurrences(of: " at", with: ",")
        let cleanDate = lastupdated.replacingOccurrences(of: "\u{202F}", with: " ")
        self.securityInfo.last_updated = cleanDate
    }
    
    @objc public func getJson() -> String {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(self.securityInfo)
            if let jsonString = String(data: data, encoding: .utf8) {
                return jsonString
            }
        } catch {
          print(error)
        }
        
        /*let dict = ["deviceid": sDeviceId, "device": sDevice, "glacier_version": sGlacierVersion,
                   "glacier_version_outdated": String(sGlacierOutdated), "os_version": sOsVersion, "os_version_outdated": String(sOsOutdated), "os_patch": sOsPatch, "compromised": String(sCompromised), "compromised_detail": sCompromisedDetail, "screen_lock": String(sScreenLock), "biometric_lock": String(sBiometricLock), "core_enabled": String(sCoreEnabled)];
        
        let encoder = JSONEncoder()
        if let jsonData = try? encoder.encode(dict) {
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            }
        }*/
        return ""
    }
    
    @objc public func equals(secinfo: Dictionary<String, Any>) -> Bool {
        let outdatedGlacier = secinfo["glacier_version_outdated"] as? Bool ?? false
        let outdatedOs = secinfo["os_version_outdated"] as? Bool ?? false
        let compromised = secinfo["compromised"] as? Bool ?? false
        let screenLock = secinfo["screen_lock"] as? Bool ?? false
        let biometricLock = secinfo["biometric_lock"] as? Bool ?? false
        let coreEnabled = secinfo["core_enabled"] as? Bool ?? false
        
        if secinfo["deviceid"] as? String == securityInfo.deviceid, secinfo["device"] as? String == securityInfo.device, secinfo["glacier_version"] as? String == securityInfo.glacier_version, outdatedGlacier == securityInfo.glacier_version_outdated, secinfo["os_version"] as? String == securityInfo.os_version, outdatedOs == securityInfo.os_version_outdated, secinfo["os_patch"] as? String == securityInfo.os_patch, compromised == securityInfo.compromised, secinfo["compromised_detail"] as? String == securityInfo.compromised_detail, screenLock == securityInfo.screen_lock, biometricLock == securityInfo.biometric_lock, coreEnabled == securityInfo.core_enabled {
            return true
        }
        return false
    }
}

@objc public class SecurityInfo:NSObject, Codable {
    @objc var deviceid: String?
    @objc var device: String?
    @objc var glacier_version: String?
    @objc var glacier_version_outdated = false
    @objc var os_version: String?
    @objc var os_version_outdated = false
    @objc var os_patch: String?
    @objc var compromised = false
    @objc var compromised_detail: String?
    @objc var screen_lock = false
    @objc var biometric_lock = false
    @objc var core_enabled = false
    @objc var last_updated: String?
}
