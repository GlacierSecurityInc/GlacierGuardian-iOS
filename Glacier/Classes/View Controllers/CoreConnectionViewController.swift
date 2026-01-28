//
//  CoreConnectionViewController.swift
//  Created by Andy Friedman on 10/25/19.
//  Copyright © 2019 Glacier Security. All rights reserved.

import UIKit
import NetworkExtension
import SwiftUI
import Authenticator

@objc public protocol CoreConnectionDelegate: NSObjectProtocol {
    func coreSettingChanged()
}

@objc open class CoreConnectionViewController: UIViewController, UITextViewDelegate, CoreConnectionDelegate {

    let profileCellID = "profile"
    var settingsManager: OTRSettingsManager?
    var coreSetting: OTRBoolSetting?
    
    @IBOutlet weak var coreOptionsHeight: NSLayoutConstraint!
    @IBOutlet weak var scrollView: UIScrollView!
    @IBOutlet weak var coreDescriptionTextView: UITextView!
    @IBOutlet weak var profilesTable: UITableView!
    @IBOutlet weak var profilesHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var coreOptionsView: UIView!
    
    var profiles:[String] = []
    var vSpinner : UIView?
    var coreOptionsController: CoreOptionsViewController?
    var refreshButton:UIButton = UIButton(type: .custom)
    var amplifyAuth:UIHostingController<AuthView>? // for refreshing profiles when auth expired
    
    var tunnelsManager: TunnelsManager?
    var onTunnelsManagerReady: ((TunnelsManager) -> Void)?
    
    override open func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override open func viewWillDisappear(_ animated: Bool) {
        self.stopSpinner()
        super.viewWillDisappear(animated)
        //NotificationCenter.default.removeObserver(self)
    }
    
    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Core"
        
        let coreDescription = "Enabling Core adds an additional layer of encryption and anonymitity to all data exiting your device.\n\nLearn more how Glacier protects you."
        
        let attributedString = NSMutableAttributedString(string: coreDescription)
        attributedString.addAttribute(.link, value: "https://glacier.chat/core", range: NSRange(location: 126, length: 12))
        let textRange = NSMakeRange(0, coreDescription.count)
        
        // might need to put everything inside a scroll view
        //let userFont = UIFontDescriptor.preferredFontDescriptor(withTextStyle: UIFontTextStyle.body, compatibleWith: nil)
        //let fontSize = userFont.pointSize-3
        
        attributedString.addAttribute(.font, value: UIFont.systemFont(ofSize: 14), range: textRange)
        let tcolor = UIColor.label
        attributedString.addAttribute(.foregroundColor, value: tcolor, range: textRange)
        
        coreDescriptionTextView.attributedText = attributedString
        coreDescriptionTextView.delegate = self
        
        self.profilesTable.dataSource = self
        self.profilesTable.delegate = self
        let profilenib = UINib(nibName: CoreProfileCell.cellIdentifier(), bundle: Bundle.main)
        self.profilesTable.register(profilenib, forCellReuseIdentifier: CoreProfileCell.cellIdentifier())
        
        WireGuardManager.shared().setUIDelegate(self) //tunnelsManager.tunnelsListDelegate = self
        
        self.setupRefreshButton()
    }
    
    func setupRefreshButton() {
        let lblColor = UIColor.label
        
        refreshButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4.0, leading: 8.0, bottom: 4.0, trailing: 8.0)
        self.refreshButton.translatesAutoresizingMaskIntoConstraints = false
        self.refreshButton.frame = CGRectMake(0, 0, 64, 48)
        self.refreshButton.titleLabel?.font = UIFont(name: "Material Icons", size: 26)
        self.refreshButton.titleLabel?.textAlignment = NSTextAlignment.center
        self.refreshButton.tintColor = lblColor
        self.refreshButton.setTitleColor(lblColor, for: UIControl.State.normal)
        self.refreshButton.setTitleColor(UIColor.lightGray, for: UIControl.State.highlighted)
        let refreshIconChar: UniChar = 0xe5d5
        self.refreshButton.setTitle(String(format: "%C", refreshIconChar), for: .normal)
        self.refreshButton.addTarget(self, action: #selector(didSelectRefreshButton), for: UIControl.Event.touchUpInside)
        
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(customView: self.refreshButton)
    }
    
    open override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        var numTunnels = WireGuardManager.shared().tunnelsManager?.numberOfTunnels() ?? 0
        if numTunnels < 1 {
            numTunnels = 1
        }
        let contentSize = self.profilesTable.contentSize
        profilesHeightConstraint.constant = contentSize.height //CGFloat(48 + (44*numTunnels))
        
        if let coreOpSize = coreOptionsController?.coreOptionsTableView.contentSize, coreOptionsHeight != nil {
            coreOptionsHeight.constant = coreOpSize.height
        }
    }
    
    @objc func didSelectRefreshButton(sender: Any!) {
        AWSAcctManager.sharedMgr().addVPNConnection(self)
        self.startSpinner()
    }
    
    override open func prepare(for segue: UIStoryboardSegue, sender: Any?) {
            
            switch segue.destination {
                
            case let coreController as CoreOptionsViewController:
                coreOptionsController = coreController
                coreOptionsController?.setCoreConnectionDelegate(delegate: self)
                
            default:
                break
            }
    }
    
    public func coreSettingChanged() {
        self.startSpinner()
    }
    
    @available(iOSApplicationExtension, unavailable)
    public func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        Application.shared.open(URL)
        return false
    }
    
    private func startSpinner() {
        self.showSpinner(onView: self.view)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.stopSpinner()
        }
    }
    
    private func stopSpinner() {
        self.removeSpinner()
    }
}

extension CoreConnectionViewController {
    func showSpinner(onView : UIView) {
        DispatchQueue.main.async {
            let spinnerView = UIView.init(frame: onView.bounds)
            spinnerView.backgroundColor = UIColor.init(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5)
            let ai = UIActivityIndicatorView.init(style: .large)
            ai.startAnimating()
            ai.center = spinnerView.center
        
            spinnerView.addSubview(ai)
            onView.addSubview(spinnerView)
            
            self.vSpinner = spinnerView
        }
    }
    
    func removeSpinner() {
        DispatchQueue.main.async {
            self.vSpinner?.removeFromSuperview()
            self.vSpinner = nil
        }
    }
}

extension CoreConnectionViewController: VPNStorageListener {
    public func endLogin() {
        DispatchQueue.main.async {
            self.amplifyAuth?.dismiss(animated: true)
        }
    }
    
    public func handleNoStorageAccess() {
        self.stopSpinner()
        guard let acctname = ChatAccountModel.allXMPPAccounts().first?.bareJID?.user else { return }
        
        let openAuth = {
            let swiftUIAuth = AuthView(acctname) // swiftUIView is View
            self.amplifyAuth = UIHostingController(rootView: swiftUIAuth)
            self.present(self.amplifyAuth!, animated: true)
        }
        
        DispatchQueue.main.async {
            openAuth()
            let alert = UIAlertController(title: "Some services unavailable", message: "You may need to re-open Glacier or sign in again to access updated VPN profiles and some Security Hub data. This does not affect normal messaging.\n\nSwipe down to skip for now and sign in later.", preferredStyle: .alert)
            let okButtonItem = UIAlertAction(title: "OK", style: .default, handler: nil)
            alert.addAction(okButtonItem)
            self.amplifyAuth?.present(alert, animated: true, completion: nil)
        }
    }
    
    public func handleNoCoreProfiles() {
        self.stopSpinner()
        self.alertWith(title:"No Core profile available", message:"There doesn't appear to be any Core profile available for your account. Please ask your Glacier representative if you have additional questions.")
    }
    
    func alertWith(title:String, message:String) {
        DispatchQueue.main.async {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            let action = UIAlertAction(title: "OK", style: .default, handler: nil)
            alert.addAction(action)
            self.present(alert, animated: true)
        }
    }
}

extension CoreConnectionViewController: TunnelsManagerListDelegate {
    func tunnelAdded(at index: Int) {
        self.view.setNeedsLayout()
        self.profilesTable.reloadData()
        if index == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.profilesTable.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
            }
        }
    }

    func tunnelModified(at index: Int) {
        self.profilesTable.reloadData()
    }

    func tunnelMoved(from oldIndex: Int, to newIndex: Int) {
        self.profilesTable.reloadData()
    }

    func tunnelRemoved(at index: Int, tunnel: TunnelContainer) {
        self.profilesTable.reloadData()
    }
}

extension CoreConnectionViewController: TunnelsManagerActivationDelegate {
    func tunnelActivationAttemptFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationAttemptError) {
        ErrorPresenter.showErrorAlert(error: error, from: self)
        //turnSwitchOff
    }

    func tunnelActivationAttemptSucceeded(tunnel: TunnelContainer) {
        // Nothing to do
    }

    func tunnelActivationFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationError) {
        //ErrorPresenter.showErrorAlert(error: error, from: self)
        NSLog("Tunnel activation failed: Likely just due to On Demand rules")
        self.profilesTable.reloadData()
    }

    func tunnelActivationSucceeded(tunnel: TunnelContainer) {
        // Nothing to do
        self.profilesTable.reloadData()
    }
    
    func tunnelDeactivating(tunnel: TunnelContainer) {
        // nothing needed for normal situations I think
    }
}

// MARK: - UITableViewDataSource
extension CoreConnectionViewController: UITableViewDataSource {
    public func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let numTun = WireGuardManager.shared().tunnelsManager?.numberOfTunnels() ?? 0
        if numTun == 0 {
            return 1
        }

        return numTun
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if let cell = self.profilesTable.dequeueReusableCell(withIdentifier: CoreProfileCell.cellIdentifier(), for: indexPath) as? CoreProfileCell {
            if WireGuardManager.shared().tunnelsManager?.numberOfTunnels() == 0 {
                cell.profileName.text = "No profiles loaded"
                cell.profileSwitch.isHidden = true
                return cell
            } else if let tunnel = WireGuardManager.shared().tunnelsManager?.tunnel(at: indexPath.row) {
                cell.profileName.text = tunnel.name
                cell.selectionStyle = .none
                //not if it's active, but if its enabled I think
                cell.profileSwitch.isOn = (tunnel.status == TunnelStatus.active || tunnel.isActivateOnDemandEnabled == true)
                return cell
            }
        }
        
        return UITableViewCell()
    }
    
    // Create a standard header that includes the returned text.
    public func tableView(_ tableView: UITableView, titleForHeaderInSection
                                section: Int) -> String? {
        return "Profiles"
    }
}

// MARK: - UITableViewDelegate
extension CoreConnectionViewController:UITableViewDelegate {
    public func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        if let tunnel = WireGuardManager.shared().tunnelsManager?.tunnel(at: indexPath.row) {
            let action = UIContextualAction(style: .destructive, title: "Delete") { (action, view, completion) in
                WireGuardManager.shared().tunnelsManager?.remove(tunnel: tunnel, completionHandler: {_ in 
                    self.view.setNeedsLayout()
                    completion(true)
                })
            }

            let swipeConfig = UISwipeActionsConfiguration(actions: [action])
            return swipeConfig
        }
        return nil
    }
}
