//  Glacier
//  Created by andyfriedman on 9/10/24.
//  Copyright © 2024 Glacier. All rights reserved.

import UIKit

public class CoreProfileCell: UITableViewCell {
    @IBOutlet weak var profileSwitch: UISwitch!
    @IBOutlet weak var profileName: UILabel!
    
    @objc public class func cellIdentifier() -> String {
        return "CoreProfileCell"
    }
    
    @IBAction func profileSwitchChanged(_ sender: Any) {
        guard let tunnelMgr = WireGuardManager.shared().tunnelsManager else {
            return
        }
        if (profileSwitch.isOn) {
            if let tname = profileName.text, let tunnel = tunnelMgr.tunnel(named: tname), (tunnel.status != .active && tunnel.status != .activating && tunnel.status != .restarting) {
                
                //seems like this needs to happen before starting the other
                if let ontunnel = tunnelMgr.tunnelInOperation() {
                    tunnelMgr.setOnDemandEnabled(false, on: ontunnel, completionHandler: { _ in
                        tunnelMgr.startDeactivation(of: ontunnel)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            tunnelMgr.setOnDemandEnabled(true, on: tunnel, completionHandler: {_ in
                                tunnelMgr.startActivation(of: tunnel)
                            })
                        }
                    })
                } else {
                    tunnelMgr.setOnDemandEnabled(true, on: tunnel, completionHandler: {_ in
                        tunnelMgr.startActivation(of: tunnel)
                    })
                }
            }
        } else {
            if let tname = profileName.text, let tunnel = tunnelMgr.tunnel(named: tname), (tunnel.status == .active || tunnel.status == .activating || tunnel.status == .restarting || tunnel.isActivateOnDemandEnabled == true) {
                tunnelMgr.setOnDemandEnabled(false, on: tunnel, completionHandler: { _ in
                    tunnelMgr.startDeactivation(of: tunnel)
                })
            }
        }
    }
}
