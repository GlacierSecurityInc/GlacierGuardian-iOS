//
//  OMEMODeviceFingerprintCell.swift
//  ChatSecure
//
//  Created by Chris Ballinger on 10/14/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

import UIKit
import XLForm
import XMPPFramework

private extension String {
    //http://stackoverflow.com/a/34454633/805882
    func splitEvery(_ n: Int) -> [String] {
        var result: [String] = []
        let chars = Array(self)
        for index in stride(from: 0, to: chars.count, by: n) {
            result.append(String(chars[index..<min(index+n, chars.count)]))
        }
        return result
    }
}

public extension NSData {
    /// hex, split every 8 bytes by a space
    @objc func humanReadableFingerprint() -> String {
        return (self as NSData).xmpp_hexStringValue.splitEvery(8).joined(separator: " ")
    }
}

public extension XLFormBaseCell {
    
    @objc class func defaultRowDescriptorType() -> String {
        let type = NSStringFromClass(self)
        return type
    }
    
    @objc class func registerCellClass(_ forType: String) {
        let bundle = GlacierInfo.resourcesBundle
        let path = bundle.bundlePath
        guard let bundleName = (path as NSString?)?.lastPathComponent else {
            return
        }
        let className = bundleName + "/" + NSStringFromClass(self)
        XLFormViewController.cellClassesForRowDescriptorTypes().setObject(className, forKey: forType as NSString)
    }
}

@objc(OMEMODeviceFingerprintCell)
open class OMEMODeviceFingerprintCell: UITableViewCell { //XLFormBaseCell {
    
    @IBOutlet weak var fingerprintLabel: UILabel!
    @IBOutlet weak var trustSwitch: UISwitch!
    @IBOutlet weak var lastSeenLabel: UILabel!
    @IBOutlet weak var trustLevelLabel: UILabel!
    private var omemoDevice:ChatOmemoDevice?
    
    @objc @IBOutlet weak var fingerprintWidth: NSLayoutConstraint!
    
    
    /*open override class func formDescriptorCellHeight(for rowDescriptor: XLFormRowDescriptor!) -> CGFloat {
        return 90
    }*/
    
    @objc public class func cellIdentifier() -> String {
        return "OMEMODeviceFingerprintCell"
    }
    
    public func updateWithDevice(_ device:ChatOmemoDevice) {
        updateCellFromDevice(device)
    }
    
    @IBAction func switchValueChanged(_ sender: UISwitch) {
        if let device = omemoDevice {
            switchValueWithDevice(device)
        }
    }
    
    fileprivate func updateCellFromDevice(_ device: ChatOmemoDevice) {
        omemoDevice = device
        let trusted = device.isTrusted()
        trustSwitch.isOn = trusted
        trustSwitch.isEnabled = true
        
        // we've already filtered out devices w/o public keys
        // so publicIdentityKeyData should never be nil
        let fingerprint = device.humanReadableFingerprint
        
        fingerprintLabel.text = fingerprint
        let since = RelativeTimeFormatter.pastString(since: device.lastSeenDate)
        let lastSeen = "Session established: " + since  //Instead of OMEMO
        lastSeenLabel.text = lastSeen
        //OMEMOTrustLevel.trustedTofu.rawValue
        if (device.trustLevel == OMEMOTrustLevel.trustedTofu.rawValue) {
            trustLevelLabel.text = "Trusted"//"TOFU"
        } else if (device.trustLevel == OMEMOTrustLevel.trustedUser.rawValue) {
            trustLevelLabel.text = "Trusted"//VERIFIED_STRING()
        } else if (device.trustLevel == OMEMOTrustLevel.removed.rawValue) {
            trustLevelLabel.text = Removed_By_Server()
        } else {
            trustLevelLabel.text = UNTRUSTED_DEVICE_STRING()
        }
    }
    
    fileprivate func switchValueWithDevice(_ device: ChatOmemoDevice) {
        var omemoDevice = device
        if (trustSwitch.isOn) {
            omemoDevice.trustLevel = OMEMOTrustLevel.trustedUser.rawValue
            if omemoDevice.isExpired() {
                omemoDevice.lastSeenDate = Date()
            }
        } else {
            omemoDevice.trustLevel = OMEMOTrustLevel.untrusted.rawValue
        }
        
        updateCellFromDevice(omemoDevice)
        
        var deviceCopy = omemoDevice
        deviceCopy.trustLevel = omemoDevice.trustLevel
        if (deviceCopy.trustLevel == OMEMOTrustLevel.trustedUser.rawValue && omemoDevice.isExpired()) {
            deviceCopy.lastSeenDate = omemoDevice.lastSeenDate
        }
        
        deviceCopy.save()
    }
}
