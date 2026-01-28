//
//  ChatProfileViewController.swift
//  Glacier
//
//  Created by andyfriedman on 12/18/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import UIKit
import PureLayout
import MBProgressHUD
import GRDB
//import MobileCoreServices

@objc open class ChatProfileViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, OTRSettingDelegate, UIPopoverPresentationControllerDelegate, OTRAttachmentPickerDelegate, UIGestureRecognizerDelegate
{
    static let kSettingsCellIdentifier = "kSettingsCellIdentifier"
    
    var tableView:UITableView
    public var profileManager:ProfileManager
    
    var currentDevice:ChatOmemoDevice?
    var allDevices:[ChatOmemoDevice] = []
    var teams:[String] = []
    var teamsHeight:CGFloat = UITableView.automaticDimension
    var viewWidth:CGFloat = 375

    /** This is only non-nil during avatar picking */
    var avatarPicker:OTRAttachmentPicker?
    
    public init() {
        self.tableView = UITableView(frame: CGRect.zero, style: .grouped)
        self.profileManager = ProfileManager()
        self.viewWidth = 375
        super.init(nibName: nil, bundle: nil)
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        self.title = "My Profile"
        
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = GlobalTheme.shared.lightThemeColor;
        appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.label]
        self.navigationController?.navigationBar.tintColor = UIColor.label
        self.navigationController?.navigationBar.standardAppearance = appearance
        self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
        
        /////////// TableView ///////////
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.tableView.accessibilityIdentifier = "profileTableView"
        self.tableView.translatesAutoresizingMaskIntoConstraints = false
        
        //self.tableView.contentInsetAdjustmentBehavior = .never
        
        self.tableView.autoresizingMask = [.flexibleHeight, .flexibleRightMargin, .flexibleWidth, .flexibleBottomMargin]
        self.view.addSubview(self.tableView)
        
        let nib = UINib(nibName: XMPPAccountCell.cellIdentifier(), bundle: Bundle.main)
        self.tableView.register(nib, forCellReuseIdentifier: XMPPAccountCell.cellIdentifier())
        
        let omemonib = UINib(nibName: OMEMODeviceFingerprintCell.cellIdentifier(), bundle: Bundle.main)
        self.tableView.register(omemonib, forCellReuseIdentifier: OMEMODeviceFingerprintCell.cellIdentifier())
        
        self.getFingerprintData(false)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.refreshView()
        }
    }
    
    // get view width for constant?
    open override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        self.viewWidth = self.view.bounds.size.width
    }

    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // get a reference to the table's footer view
        if let currentFooterView = self.tableView.tableFooterView {
            // tell auto-layout to calculate the size based on the footer view's content
            let newHeight = currentFooterView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
            
            // get the current frame of the footer view
            var currentFrame = currentFooterView.frame
            
            // we only want to do this when necessary (otherwise we risk infinite recursion)
            // so... if the calculated height is not the same as the current height
            if (newHeight != currentFrame.size.height) {
                // use the new (calculated) height
                currentFrame.size.height = newHeight
                currentFooterView.frame = currentFrame
            }
            
        }
    }
    
    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.tableView.frame = self.view.bounds
        self.profileManager.populateSettings()
        self.tableView.reloadData()
    }
    
    override open func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self)
    }
    
    public func numberOfSections(in tableView: UITableView) -> Int {
        return self.profileManager.settingsGroups.count
    }
    
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if (section == 0) {
            let cnt = ChatAccountModel.countXMPPAccounts()
            if (cnt == 0) {
                return cnt+3 // +1 and below
            } else {
                return cnt+2
            }
        }
        
        if (section == 1 || section == 2) {
            return 1
        }
        
        if (section == 3) {
            if (self.allDevices.count == 0) {
                return 1
            } else {
                return self.allDevices.count+1
            }
        }
        
        return Int(self.profileManager.numberOfSettings(inSection:UInt(section)))
    }
    
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if (indexPath.section == 0) {
            if (indexPath.row != 0) {
                return 50.0
            } else {
                return XMPPAccountCell.cellHeight()
            }
        } else if (indexPath.section == 1) {
            if (self.teamsHeight > 0 && self.teamsHeight > UITableView.automaticDimension) {
                return self.teamsHeight
            }
        }
        return UITableView.automaticDimension
    }
    
    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return self.profileManager.stringForGroup(inSection: UInt(section))
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        
        if (indexPath.section == 0 && indexPath.row == 0) {
            //do nothing
        } else if (indexPath.section > 2 && self.allDevices.count > 0) {
            if (indexPath.row == 0) { //clear devices
                let setting = self.profileManager.setting(at: indexPath)
                if let actionBlock = setting.actionBlock {
                    actionBlock(self)
                }
            }
        } else {
            let setting = self.profileManager.setting(at: indexPath)
            if let actionBlock = setting.actionBlock {
                actionBlock(self)
            }
        }
        
        tableView.deselectRow(at: indexPath, animated: true)
    }
    
    public func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return .none
    }

    public func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if (indexPath.section != 0) {
            return
        }
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        //var cell:UITableViewCell?
        if (indexPath.section == 0 && indexPath.row == 0) {
            if ChatAccountModel.countXMPPAccounts() > 0, let account = self.account(at: indexPath), let accountCell = tableView.dequeueReusableCell(withIdentifier: XMPPAccountCell.cellIdentifier()) as? XMPPAccountCell {
                accountCell.setAppearance(account: account)
                accountCell.accessoryType = .none
                accountCell.displayNameTop.constant = 10
                accountCell.userNameLabel.isHidden = false
                if let usr = account.bareJID?.user {
                    let userStr = String(format: "@%@", usr)
                    accountCell.userNameLabel.text = userStr
                }
                
                // five taps to get to account settings
                let fiveTapGesture = UITapGestureRecognizer.init(target: self, action: #selector(gotoAccountSettings))
                fiveTapGesture.numberOfTapsRequired = 5
                fiveTapGesture.cancelsTouchesInView = false
                accountCell.addGestureRecognizer(fiveTapGesture)
                
                accountCell.infoButton.isHidden = true
                
                let nameTapGesture = UITapGestureRecognizer.init(target: self, action: #selector(handleDisplayNameClick))
                
                accountCell.displayNameLabel.addGestureRecognizer(nameTapGesture)

                accountCell.avatarButtonAction = { (cell:UITableViewCell, sender:Any) in
                    self.avatarPicker = OTRAttachmentPicker(parentViewController: self, delegate: self)
                    self.avatarPicker?.tag = account
                    self.avatarPicker?.showAlertController(fromSourceView: cell)
                }
                accountCell.selectionStyle = .none
                return accountCell
            }
            //return cell;
        } else if (indexPath.section == 1) {
            var cell = tableView.dequeueReusableCell(withIdentifier: FlowLabelTableViewCell.cellIdentifier()) as? FlowLabelTableViewCell
            if (cell == nil) {
                cell = FlowLabelTableViewCell.flowCell
                //cell.myCollectionView.scrollEnabled = false;
            }
            //cell.backgroundColor = [UIColor clearColor];
            if let cell = cell {
                cell.contentView._setWidth(width: self.viewWidth)
                cell.updateWithTeams(self.teams)
                self.teamsHeight = cell.getHeightConstraint()
                return cell
            }
        } else if indexPath.section == 2, let curDevice = self.currentDevice {
            var cell = tableView.dequeueReusableCell(withIdentifier: OMEMODeviceFingerprintCell.cellIdentifier()) as? OMEMODeviceFingerprintCell
            if (cell == nil) {
                cell = OMEMODeviceFingerprintCell(style: .default, reuseIdentifier: OMEMODeviceFingerprintCell.cellIdentifier())
            }
            cell?.updateWithDevice(curDevice)
            cell?.fingerprintWidth.constant = self.viewWidth-24
            cell?.trustSwitch.isEnabled = false
            cell?.trustLevelLabel.isHidden = true
            cell?.trustSwitch.isHidden = true
            return cell!
        } else if (indexPath.section > 2) {
            if (indexPath.row == 0) {
                var cell = tableView.dequeueReusableCell(withIdentifier: Self.kSettingsCellIdentifier) as? OTRSettingTableViewCell
                if (cell == nil) {
                    cell = OTRSettingTableViewCell(style: .default, reuseIdentifier: Self.kSettingsCellIdentifier)
                }
                
                var setting = self.profileManager.setting(at: indexPath)
                if self.allDevices.count == 0 {
                    setting = self.profileManager.setting(at: indexPath, row: UInt(indexPath.row+1))
                }
                setting.delegate = self
                cell?.otrSetting = setting
                return cell!
            } else if self.allDevices.count > 0 {
                var cell = tableView.dequeueReusableCell(withIdentifier: OMEMODeviceFingerprintCell.cellIdentifier()) as? OMEMODeviceFingerprintCell
                if (cell == nil) {
                    cell = OMEMODeviceFingerprintCell(style: .default, reuseIdentifier: OMEMODeviceFingerprintCell.cellIdentifier())
                }
                if self.allDevices.count > indexPath.row {
                    let device = self.allDevices[indexPath.row-1]
                    cell?.updateWithDevice(device)
                }
                cell?.trustLevelLabel.isHidden = true
                cell?.lastSeenLabel.text = "Glacier ID"
                cell?.fingerprintWidth.constant = self.viewWidth-82
                return cell!
            }
        }
        
        var cell = tableView.dequeueReusableCell(withIdentifier: ChatProfileViewController.kSettingsCellIdentifier) as? OTRSettingTableViewCell
        if (cell == nil) {
            cell = OTRSettingTableViewCell(style: .subtitle, reuseIdentifier: ChatProfileViewController.kSettingsCellIdentifier)
        }
        let setting = self.profileManager.setting(at: indexPath)
        setting.delegate = self
        cell?.otrSetting = setting
        
        return cell!
    }
    
    func account(at indexPath:IndexPath) -> ChatAccountModel? {
        var account:ChatAccountModel?
        let accts = ChatAccountModel.allXMPPAccounts()
        if (accts.count > indexPath.row) {
            account = accts[indexPath.row]
        }
        return account
    }
    
    public func attachmentPicker(_ attachmentPicker: OTRAttachmentPicker, gotPhoto photo: UIImage, withInfo info: [AnyHashable : Any]) {
        self.avatarPicker = nil;
        guard let account = attachmentPicker.tag as? ChatAccountModel, let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account) else { return}
        
        xmpp.setAvatar(photo)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.refreshView()
        }
    }
    
    public func attachmentPicker(_ attachmentPicker: OTRAttachmentPicker, gotVideoURL videoURL: URL) {
        self.avatarPicker = nil
    }
    
    public func attachmentPicker(_ attachmentPicker: OTRAttachmentPicker, preferredMediaTypesFor source: UIImagePickerController.SourceType) -> Array<String>
    {
        return [UTType.image.identifier]
    }
    
    func getFingerprintData(_ publish:Bool) {
        let acctpath = IndexPath(row: 0, section: 0)
        guard let account = self.account(at:acctpath), let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account) else {
            return
        }
        
        self.teams = xmpp.getTeams()
        do {
            try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                if let bundle = xmpp.omemoSignalCoordinator?.fetchMyBundle(transaction) {
                    let idNumber = NSNumber(value: bundle.deviceId)
                    
                    self.currentDevice = ChatOmemoDevice(deviceId: idNumber, trustLevel: .trustedUser, parentKey: account.uniqueId, parentCollection: ChatAccountModel.collection(), publicIdentityKeyData: bundle.identityKey, lastSeenDate: xmpp.getLastConnected())
                    
                    let odevices = ChatOmemoDevice.allOMEMODevices(for: account.uniqueId, collection: ChatAccountModel.collection(), transaction: transaction)
                    self.allDevices = odevices.filter({
                        if $0.publicIdentityKeyData != nil {
                            return true
                        }
                        return false
                    })
                    
                    if publish, let coorder = xmpp.omemoSignalCoordinator {
                        coorder.omemoModule?.publishBundle(bundle, elementId: nil)
                        if let bjid = account.bareJID {
                            let nsdevices = coorder.fetchDeviceIds(for: bjid, transaction: transaction)
                            coorder.omemoModule?.publishDeviceIds(nsdevices, elementId: nil)
                        }
                    }
                }
            })
        } catch {
            DDLogError("getFingerprintData error \(error)")
        }
    }

    @objc func changeDisplayName(_ sender:Any?, withNewName newName: String) {
        let acctpath = IndexPath(row: 0, section: 0)
        guard let xcct = self.account(at: acctpath) else { return }
        
        if xcct.vCardTemp == nil {
            let newvCardTemp = XMPPvCardTemp.v()
            xcct.vCardTemp = newvCardTemp
        }
        
        //xcct.vCardTemp?.nickname = newName
        if let vtemp = xcct.vCardTemp, let xmgr = OTRProtocolManager.shared.xmppManager(forChatAccount: xcct) {
            vtemp.nickname = newName
            xmgr.updateNickname(vtemp)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.refreshView()
        }
    }
    
    @objc func clearDevicesButtonPressed() {
        let alert = UIAlertController(title: "Clear Devices", message: "Are you sure you want to clear all your other devices? If you have other devices with the same account, the next time they connect they will reannounce themselves, but they might not receive messages sent in the meantime.", preferredStyle: .alert)
        let reset = UIAlertAction(title: "Clear", style: .default, handler: {[weak self] _ in
            guard let self = self else { return }
            self.doClearDevices()
            //above is not returning for some reason, so assume it worked, wait a second and reload
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                self.allDevices.removeAll()
                self.tableView.reloadData()
            }
        })
        let cancel = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        alert.addAction(reset)
        alert.addAction(cancel)
        self.present(alert, animated: true, completion: nil)
    }
    
    @objc func resetSecureConnectionsButtonPressed() {
        let alertController = UIAlertController(title: "Reset Secure Sessions", message: "This may help if you are having problems with message delivery. All your messages will be kept.", preferredStyle: .alert)
        let resetAction = UIAlertAction(title: "Reset", style: .default, handler: {[weak self] _ in
            self?.doResetSecureConnections()
        })
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        alertController.addAction(resetAction)
        alertController.addAction(cancelAction)
        self.present(alertController, animated: true, completion: nil)
    }
    
    func doClearDevices() {
        let acctpath = IndexPath(row: 0, section: 0)
        if let account = self.account(at: acctpath), let curDevice = self.currentDevice {
            let devicenums = [NSNumber(value: curDevice.deviceId)]
            let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account)
            xmpp?.omemoSignalCoordinator?.omemoModule?.publishDeviceIds(devicenums, elementId: nil)
            
            var allDevices:[ChatOmemoDevice] = []
            var devices:[ChatOmemoDevice] = ChatOmemoDevice.allOMEMODevices(for: account.uniqueId, collection: ChatAccountModel.collection())
            if devices.count > 0 {
                allDevices = devices.filter({
                    if $0.deviceId != self.currentDevice?.deviceId {
                        return true
                    }
                    return false
                })
            }
            
            if allDevices.count > 0 {
                xmpp?.omemoSignalCoordinator?.removeDevice(allDevices, localOnly: true, completion: {_ in })
            }
        }
    }
    
    func doResetSecureConnections() {
        let hud = MBProgressHUD.showAdded(to: self.view, animated: true)
        
        let acctpath = IndexPath(row: 0, section: 0)
        guard let account = self.account(at: acctpath), let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account), let omemoCoord = xmpp.omemoSignalCoordinator else {
            hud.removeFromSuperview()
            return
        }
        var allDevicesToClear: [ChatOmemoDevice] = []
        
        let buddies = ChatBuddyModel.getAllBuddies(for: account.uniqueId)
        for buddy in buddies {
            let devices = ChatOmemoDevice.allOMEMODevices(for: buddy.uniqueId)
            allDevicesToClear.append(contentsOf: devices)
        }
        
        if let curDevice = self.currentDevice {
            allDevicesToClear.append(curDevice)
        }
        
        // only remove current device
        var mutableDevices:[NSNumber] = []
        if let bareJid = account.bareJID {
            let devices = omemoCoord.fetchDeviceIds(for: bareJid)
            mutableDevices = devices
            
            if let curId = self.currentDevice?.deviceId {
                let removeId = NSNumber(value:curId)//[NSNumber(value:curId)]
                let indexSet = devices.enumerated().lazy
                    .filter {
                        removeId == $0.element
                        //removedevices.contains($0)
                    }.map{$0.offset}
                
                // Remove devices
                let iset = IndexSet(indexSet)
                mutableDevices.remove(atOffsets: iset)
            }
        }
        
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                try ChatAccountSignalIdentity
                    .filter(Column("accountKey") == account.uniqueId)
                    .deleteAll(transaction.database)
                try ChatSignedPreKey
                    .filter(Column("accountKey") == account.uniqueId)
                    .deleteAll(transaction.database)
            } catch {
                DDLogError("ChatProfileViewController error removing old secure keys: \(error)")
            }
        }, completion: {
            if let bundle = omemoCoord.fetchMyBundle() {
                //NSNumber *idNumber = [NSNumber numberWithInt:bundle.deviceId];
                //NSArray<NSNumber *>* mydevice = @[idNumber];
                omemoCoord.omemoModule?.publishBundle(bundle, elementId: nil)
                //[xmpp.omemoSignalCoordinator.omemoModule publishDeviceIds:mydevice elementId:nil];
                // should include my other deviceIDs
                mutableDevices.append(NSNumber(value: bundle.deviceId))
                let copyDevices = mutableDevices
                omemoCoord.omemoModule?.publishDeviceIds(copyDevices, elementId: nil)
                
                omemoCoord.removeDevice(allDevicesToClear, localOnly: true, completion: { (success) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                        self.allDevices.removeAll()
                        self.getFingerprintData(false)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.tableView.reloadData()
                            hud.removeFromSuperview()
                        }
                    }
                })
            } else {
                hud.removeFromSuperview() //we have issues, should give alert
            }
        })
        
        
        /*ChatAccountSignalIdentity.removeAccountSignalIdKey(for:account.uniqueId)
        ChatSignedPreKey.removeSignalSignedPreKey(for:account.uniqueId)
        
        //OTRXMPPManager *xmpp = (OTRXMPPManager*)[[OTRProtocolManager sharedInstance] protocolForAccount:account];
        if let bundle = omemoCoord.fetchMyBundle() {
            //NSNumber *idNumber = [NSNumber numberWithInt:bundle.deviceId];
            //NSArray<NSNumber *>* mydevice = @[idNumber];
            omemoCoord.omemoModule?.publishBundle(bundle, elementId: nil)
            //[xmpp.omemoSignalCoordinator.omemoModule publishDeviceIds:mydevice elementId:nil];
            // should include my other deviceIDs
            mutableDevices.append(NSNumber(value: bundle.deviceId))
            let copyDevices = mutableDevices
            omemoCoord.omemoModule?.publishDeviceIds(copyDevices, elementId: nil)
            
            omemoCoord.removeDevice(allDevicesToClear, localOnly: true, completion: { (success) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                    self.allDevices.removeAll()
                    self.getFingerprintData(false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.tableView.reloadData()
                        hud.removeFromSuperview()
                    }
                }
            })
        } else {
            hud.removeFromSuperview() //we have issues, should give alert
        }*/
    }
    
    @objc func gotoAccountSettings() {
        let ip = IndexPath(row: 0, section: 0)
        if let account = self.account(at: ip) {
            let loginViewController = OTRBaseLoginViewController(account: account)
            self.navigationController?.pushViewController(loginViewController, animated: true)
        }
    }
    
    @objc func handleDisplayNameClick() {
        if ChatAccountModel.countXMPPAccounts() > 0 {
            let xcct = self.account(at: IndexPath(row: 0, section: 0))
            self.profileManager.handleChangeDisplayName(self, currentDisplayName: xcct?.displayName ?? nil)
        }
    }
    
    //#pragma mark OTRSettingDelegate method
    @objc public func refreshView() {
        self.tableView.reloadData()
    }

    @objc public func otrSetting(_ setting: OTRSetting, showDetailViewControllerClass viewControllerClass: AnyClass) {
        
    }
}
