//
//  CoreDetailsViewController.swift
//  Created by Andy Friedman on 1/28/20.
//  Copyright © 2020 Glacier Security. All rights reserved.

import UIKit
import NetworkExtension

open class CoreOptionsViewController: UITableViewController, TunnelsManagerStatusDelegate {

    @IBOutlet weak var cellularSwitch: UISwitch!
    @IBOutlet weak var wifiSwitch: UISwitch!
    @IBOutlet weak var wifiNetworksCountLabel: UILabel!
    @IBOutlet weak var coreStatusLbl: UILabel!
    @IBOutlet weak var currentUsageLbl: UILabel!
    @IBOutlet var coreOptionsTableView: UITableView!
    
    var hidden = false
    var wifihidden = false
    var ssids = [String]()
    var onDemandViewModel: ActivateOnDemandViewModel?
    
    var coreDelegate: CoreConnectionDelegate?
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        //set slider values based on target manager also
        cellularSwitch.addTarget(self, action: #selector(cellularSwitchChanged), for: UIControl.Event.valueChanged)
        wifiSwitch.addTarget(self, action: #selector(wifiSwitchChanged), for: UIControl.Event.valueChanged)
        
        WireGuardManager.shared().tunnelsManager?.reloadDelegate = self
        //check if there is an active tunnel
        if let tun = WireGuardManager.shared().tunnelsManager?.tunnelInOperation() {
            hidden = false
            coreStatusLbl.text = "Enabled"
            self.onDemandViewModel = ActivateOnDemandViewModel(tunnel: tun)
            self.statusUpdate(tun.status)
        } else {
            hidden = true
            coreStatusLbl.text = "Disabled"
            currentUsageLbl.text = "Inactive"
        }
    }
    
    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        //NotificationCenter.default.addObserver(self, selector: #selector(coreUpdate), name: NSNotification.Name.NEVPNStatusDidChange, object: nil)
        
        self.updateCoreDetails()
    }
    
    override open func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        //NotificationCenter.default.removeObserver(self)
    }
    
    public func setCoreConnectionDelegate(delegate: CoreConnectionDelegate) {
        self.coreDelegate = delegate
    }
    
    func statusUpdate(_ status:TunnelStatus) {
        switch status {
            
        case .inactive:
            currentUsageLbl.text = "Inactive"
        case .activating:
            currentUsageLbl.text = "In progress"
        case .active:
            currentUsageLbl.text = "In Use"
        case .deactivating:
            currentUsageLbl.text = "Inactive"
        case .reasserting:
            currentUsageLbl.text = "In progress"
        case .restarting:
            currentUsageLbl.text = "Restarting"
        case .waiting:
            currentUsageLbl.text = "Transition in progress"
        }
        
        if status == .inactive, WireGuardManager.shared().tunnelsManager?.hasActiveOnDemandTunnel() == true {
            let curssid = TunnelsManager.retrieveCurrentSSID()
            if self.onDemandViewModel?.isWiFiInterfaceEnabled == false, curssid != nil {
                currentUsageLbl.text = "Inactive - using wifi"
            } else if self.onDemandViewModel?.isNonWiFiInterfaceEnabled == false, curssid == nil {
                currentUsageLbl.text = "Inactive - using cellular"
            } else if self.onDemandViewModel?.isWiFiInterfaceEnabled == true, let ssid = curssid, self.onDemandViewModel?.selectedSSIDs.contains(ssid) == true {
                currentUsageLbl.text = "Inactive - on trusted wifi"
            }
        }
    }
    
    func reloadComplete() {
        self.updateCoreDetails()
    }
    
    private func updateCoreDetails() {
        let tunnel = WireGuardManager.shared().tunnelsManager?.tunnelInOperation()
        self.onDemandViewModel = nil
        
        hidden = true
        if let tunnel = tunnel {
            hidden = false
            self.onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
            coreStatusLbl?.text = "Enabled"
        } else {
            coreStatusLbl?.text = "Disabled"
            currentUsageLbl?.text = "Inactive"
        }
        
        setSwitchStatus()
        
        tableView.reloadData()
    }
    
    private func setSwitchStatus() {
        let cellon = self.onDemandViewModel?.isNonWiFiInterfaceEnabled ?? true
        let wifion = self.onDemandViewModel?.isWiFiInterfaceEnabled ?? true
        
        ssids = self.onDemandViewModel?.selectedSSIDs ?? []
        
        if wifion {
            wifiSwitch.isOn = true
            wifihidden = false
        } else {
            wifiSwitch.isOn = false
            wifihidden = true
        }
        
        if cellon {
            cellularSwitch.isOn = true
        } else {
            cellularSwitch.isOn = false
        }
        
        if (ssids.count == 0) {
            wifiNetworksCountLabel.text = "All"
        } else if (ssids.count == 1) {
            wifiNetworksCountLabel.text = "\(ssids.count) network trusted"
        } else {
            wifiNetworksCountLabel.text = "\(ssids.count) networks trusted"
        }
    }
    
    override open func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            if hidden {
                return 0
            } else if wifihidden {
                return 2
            }
        } else {
            if hidden {
                return 1
            }
        }
        return super.tableView(tableView, numberOfRowsInSection: section)
    }
    
    public override func numberOfSections(in tableView: UITableView) -> Int {
        if hidden {
            let numTun = WireGuardManager.shared().tunnelsManager?.numberOfTunnels() ?? 0
            if numTun == 0 {
                return 1
            }
        }
        return 2
    }
    
    override open func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if hidden && section == 0 {
            return CGFloat.leastNonzeroMagnitude
        }
        return super.tableView(tableView, heightForHeaderInSection: section)
    }
    
    @objc func cellularSwitchChanged(coreSwitch: UISwitch) {
        guard let tunnelMgr = WireGuardManager.shared().tunnelsManager, let tunnel = tunnelMgr.tunnelInOperation(), let model = self.onDemandViewModel, let tunnelConfig = tunnel.tunnelConfiguration else {
            return
        }
        
        model.isNonWiFiInterfaceEnabled = cellularSwitch.isOn
        let onDemandOption = model.toOnDemandOption()
        tunnelMgr.modify(tunnel: tunnel, tunnelConfiguration: tunnelConfig, onDemandOption: onDemandOption) { [weak self] error in
            if let error = error {
                ErrorPresenter.showErrorAlert(error: error, from: self)
            }
        }
        
        self.coreDelegate?.coreSettingChanged()
    }
    
    @objc func wifiSwitchChanged(coreSwitch: UISwitch) {
        guard let tunnelMgr = WireGuardManager.shared().tunnelsManager, let tunnel = tunnelMgr.tunnelInOperation(), let model = self.onDemandViewModel, let tunnelConfig = tunnel.tunnelConfiguration else {
            return
        }
        
        model.isWiFiInterfaceEnabled = wifiSwitch.isOn
        let onDemandOption = model.toOnDemandOption()
        tunnelMgr.modify(tunnel: tunnel, tunnelConfiguration: tunnelConfig, onDemandOption: onDemandOption) { [weak self] error in
            if let error = error {
                ErrorPresenter.showErrorAlert(error: error, from: self)
            }
            self?.tableView.reloadData()
        }
        
        self.coreDelegate?.coreSettingChanged()
        //tableView.reloadData()
    }
}
