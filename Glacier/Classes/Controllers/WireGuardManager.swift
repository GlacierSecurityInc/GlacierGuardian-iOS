//
//  WireGuardManager.swift
//  Glacier
//
//  Created by andyfriedman on 8/13/24.
//  Copyright © 2024 Glacier. All rights reserved.
//

import Foundation
import WireGuardKit

public protocol TunnelListDelegate {
    func showTunnelDetail(for tunnel: TunnelContainer, animated: Bool)
}

@objc open class WireGuardManager: NSObject
{
    private static let sharedWGMgr = WireGuardManager()
    private var tunnelListDelegate:TunnelListDelegate?
    private var uiDelegate:UIViewController?
    
    var tunnelsManager: TunnelsManager?
    var onTunnelsManagerReady: ((TunnelsManager) -> Void)?
    var vpnIsActive = false
    
    let internalQueue = DispatchQueue(label: "WG Internal Queue")
    
    @objc private override init() {
        super.init()
        self.initWGClient()
        //setVpnIsActive()
    }
    
    func initWGClient() {
        TunnelsManager.create { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let error):
                if let uiDel = self.uiDelegate {
                    ErrorPresenter.showErrorAlert(error: error, from: uiDel)
                }
            case .success(let tunnelsManager):
                self.tunnelsManager = tunnelsManager
                //self.tunnelsListVC?.setTunnelsManager(tunnelsManager: tunnelsManager)

                if let uiDel = self.uiDelegate as? CoreConnectionViewController {
                    tunnelsManager.activationDelegate = uiDel
                    tunnelsManager.tunnelsListDelegate = uiDel
                }

                self.onTunnelsManagerReady?(tunnelsManager)
                self.onTunnelsManagerReady = nil
            }
        }
    }
    
    func setTunnelListDelegate(_ del: TunnelListDelegate) {
        self.tunnelListDelegate = del
    }
    
    func setUIDelegate(_ del: UIViewController) {
        self.uiDelegate = del
        
        if let uiDel = self.uiDelegate as? CoreConnectionViewController {
            tunnelsManager?.activationDelegate = uiDel
            tunnelsManager?.tunnelsListDelegate = uiDel
        }
    }

    @objc func getWGView() -> UIViewController? {
        return self.uiDelegate
    }
    
    @objc func handleWireguardProfiles(_ profiles:[URL]) {
        self.internalQueue.async {
            self.importFromDisposableFile(urls: profiles)
        }
    }
    
    func importFromDisposableFile(urls: [URL]) {
        guard let uiDelegate = self.uiDelegate else { return }
        let importFromFileBlock: (TunnelsManager) -> Void = { tunnelsManager in
            // probably check if we already have?
            TunnelImporter.importFromFile(urls: urls, into: tunnelsManager, sourceVC: uiDelegate, errorPresenterType: ErrorPresenter.self) {
                for url in urls {
                    _ = FileManager.deleteFile(at: url)
                }
                self.refreshTunnelConnectionStatuses()
            }
        }
        if let tunnelsManager = tunnelsManager {
            importFromFileBlock(tunnelsManager)
        } else {
            onTunnelsManagerReady = importFromFileBlock
        }
    }
    
    func refreshTunnelConnectionStatuses() {
        if let tunnelsManager = tunnelsManager {
            tunnelsManager.refreshStatuses()
        }
    }
    
    @objc func turnOffCore() {
        if let ontunnel = tunnelsManager?.tunnelInOperation(), let mgr = self.tunnelsManager {
            mgr.setOnDemandEnabled(false, on: ontunnel, completionHandler: { _ in
                mgr.startDeactivation(of: ontunnel)
            })
        }
    }

    func showTunnelDetailForTunnel(named tunnelName: String, animated: Bool, shouldToggleStatus: Bool) {
        let showTunnelDetailBlock: (TunnelsManager) -> Void = { [weak self] tunnelsManager in
            guard let self = self else { return }
            guard let tunnelsListVC = self.tunnelListDelegate else { return }
            if let tunnel = tunnelsManager.tunnel(named: tunnelName) {
                tunnelsListVC.showTunnelDetail(for: tunnel, animated: false)
                if shouldToggleStatus {
                    if tunnel.status == .inactive {
                        tunnelsManager.startActivation(of: tunnel)
                    } else if tunnel.status == .active {
                        tunnelsManager.startDeactivation(of: tunnel)
                    }
                }
            }
        }
        if let tunnelsManager = tunnelsManager {
            showTunnelDetailBlock(tunnelsManager)
        } else {
            onTunnelsManagerReady = showTunnelDetailBlock
        }
    }
    
    @objc func setVpnIsActive() -> Void {
        let vpnIsActiveBlock: (TunnelsManager) -> Void = { [weak self] tunnelsManager in
            if let tunMgr = self?.tunnelsManager, tunMgr.numberOfTunnels() > 0 {
                let first = tunMgr.tunnel(at: 0)
                if first.status == .active {
                    self?.vpnIsActive = true
                    return
                }
            }
            self?.vpnIsActive = false
        }
        
        if let tunnelsManager = tunnelsManager {
            vpnIsActiveBlock(tunnelsManager)
        } else {
            onTunnelsManagerReady = vpnIsActiveBlock
        }
    }
    
    @objc public class func shared() -> WireGuardManager {
        return sharedWGMgr
    }
}
