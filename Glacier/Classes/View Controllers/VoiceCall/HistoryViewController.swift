//
//  HistoryViewController.swift
//  Glacier
//
//  Created by andyfriedman on 1/22/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import Foundation
import MBProgressHUD

@objc open class HistoryViewController: UITableViewController, UITabBarDelegate {
    let missedStatus = "no-answer"
    
    var historyRecords = [CallRecord]()
    var callRecDict = [String:CallRecord]()
    var myNumber: String?
    var myAccount: SMSChatAccountModel?
    var contacts = [PhoneContact]()
    var spinnerHUD: MBProgressHUD?
    var outgoingImage = UIImage(named: "call_status_outgoing", in: GlacierInfo.resourcesBundle, with: nil)
    var incomingImage = UIImage(named: "call_status_incoming", in: GlacierInfo.resourcesBundle, with: nil)
    var missedImage = UIImage(named: "call_status_missed", in: GlacierInfo.resourcesBundle, with: nil)
    var tabBar:GlacierTabs?
    let dateFormatter = DateFormatter()
    let inputFormatter = DateFormatter()
    var emptySet = false
    
    var smsMenu: UIMenu
    var settingsButton: UIBarButtonItem
    
    var vmBtn:UIBarButtonItem?
    var vmBtnNew:UIBarButtonItem?
    var vmEnabled = false
    
    public init() {
        let lblColor = UIColor.label
        let settingsIcon = UIImage(named: "OTRSettingsIcon-1", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        
        settingsButton = UIBarButtonItem(image: settingsIcon, style: UIBarButtonItem.Style.plain, target: nil, action:nil)
        settingsButton.tintColor = lblColor
        
        let initial = UIAction(title: "No numbers to display", handler: { (_) in  })
        let initMenu = UIMenu(title: "", options: .displayInline, children: [initial])
        
        let items = [initMenu]
        smsMenu = UIMenu(title: "Phone Numbers", children: items)
        super.init(nibName:nil, bundle:nil)
        
        let vmIcon = UIImage(systemName: "recordingtape")?.imageMasked(with: UIColor.label)
        let vmUBtn = UIButton(type: .custom)
        vmUBtn.translatesAutoresizingMaskIntoConstraints = false
        if let normalVmImage = vmIcon?.imageMasked(with: UIColor.label) {
            vmUBtn.setImage(normalVmImage, for: UIControl.State.normal)
        }
        vmUBtn.addTarget(self, action: #selector(vmButtonPressed), for: UIControl.Event.touchUpInside)
        vmUBtn.autoSetDimensions(to: CGSize(width: 36, height: 40))
        vmBtn = UIBarButtonItem(customView: vmUBtn)
        vmBtn?.style = UIBarButtonItem.Style.plain
        
        TwilioBackendManager.sharedMgr().setSMSDelegate(self)
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        self.tableView = EmptyStateTableView(frame: .zero, style: .plain, centerOffset: CGPoint(x: 0.0, y: -64.0))
        self.tableView.register(CallHistoryCell.self, forCellReuseIdentifier: CallHistoryCell.reuseIdentifier)
        
        let vmIcon = UIImage(systemName: "recordingtape")?.imageMasked(with: UIColor.label)
        let customView = createCustomBarButtonView(with: vmIcon!)
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(vmButtonPressed))
        customView.isUserInteractionEnabled = true
        customView.addGestureRecognizer(tapGesture)
        vmBtnNew = UIBarButtonItem(customView: customView)
        vmBtnNew?.style = UIBarButtonItem.Style.plain
        
        var titleColor = UIColor.label
        if let acctrec = TwilioBackendManager.sharedMgr().selectedAccount?.grdbRecord {
            self.navigationItem.title = acctrec.displayName ?? acctrec.phoneNumber
            self.myNumber = acctrec.phoneNumber
            if let colorstr = acctrec.color {
                titleColor = UIColor.UIColorFromString(string: colorstr)
            }
            
            if AWSAcctManager.sharedMgr().getGlacierEnablements()?.voicemailEnabled == true {
                self.vmEnabled = true
                self.navigationItem.rightBarButtonItem = self.vmBtn
            }
        }
        
        let appearance = UINavigationBarAppearance.init()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = GlobalTheme.shared.lightThemeColor
        appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor : titleColor]
        self.navigationController?.navigationBar.standardAppearance = appearance
        self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
        self.navigationController?.navigationBar.tintColor = titleColor
        
        self.dateFormatter.dateFormat = "MM/dd/yyyy hh:mm a"
        self.inputFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        
        self.initData()
        
        self.settingsButton.menu = self.smsMenu
        self.navigationItem.leftBarButtonItem = self.settingsButton
        
        self.tabBar = GlacierTabs()
        if let tabs = self.tabBar {
            self.navigationController?.view.addSubview(tabs)
            tabs.delegate = self
            tabs.setPhoneModule()
        }
        
        if let tabBarHeight = self.tabBar?.frame.height {
            self.tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: tabBarHeight, right: 0)
            self.tableView.scrollIndicatorInsets = tableView.contentInset
        }
        
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.tableView.rowHeight = CallHistoryCell.historyCellSize
    }
    
    func createCustomBarButtonView(with image: UIImage) -> UIView {
        let containerView = UIView()
            
        // ImageView for the button image
        let imageView = UIImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(imageView)
            
        // Blue dot
        let blueDot = UIView()
        blueDot.backgroundColor = .red
        blueDot.layer.cornerRadius = 4 // Make it round
        blueDot.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(blueDot)
            
        // Constraints for imageView (optional: adjust size/spacing)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor)
        ])
            
        // Constraints for blue dot (position it at the bottom-right corner of the image)
        NSLayoutConstraint.activate([
            blueDot.widthAnchor.constraint(equalToConstant: 8), // Size of the blue dot
            blueDot.heightAnchor.constraint(equalToConstant: 8), // Size of the blue dot
            blueDot.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -5), // Position it near the bottom-right
            blueDot.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5) // Position it near the right edge
        ])
            
        // Size of the container view to fit the image and blue dot
        containerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(equalToConstant: 36.0),
            containerView.heightAnchor.constraint(equalToConstant: 40.0)
        ])
            
        return containerView
    }
    
    override open func viewWillAppear(_ animated:Bool) {
        super.viewWillAppear(animated)
        //if number has changed, query history again
        TwilioBackendManager.sharedMgr().queryCallHistory()
        self.tabBar?.selectedItem = self.tabBar?.historyItem
        if let acctrec = TwilioBackendManager.sharedMgr().selectedAccount?.grdbRecord {
            let title = acctrec.displayName ?? acctrec.phoneNumber
            self.myNumber = acctrec.phoneNumber
            if self.navigationItem.title != title {
                self.navigationItem.title = title
                if let colorstr = acctrec.color, let appearance = self.navigationController?.navigationBar.standardAppearance {
                    let titleColor = UIColor.UIColorFromString(string: colorstr)
                    appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor : titleColor]
                    self.navigationController?.navigationBar.standardAppearance = appearance
                    self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
                    self.navigationController?.navigationBar.tintColor = titleColor
                }
            }
        }
        
        //check vm status
        self.handleVMStatus()
    }
    
    public func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        self.navigationController?.popToRootViewController(animated: false)
        
        if let appDelegate = Application.shared.delegate as? OTRAppDelegate {
            switch (item.tag) {
            case GlacierTabs.Screen.chats.rawValue:
                appDelegate.window?.rootViewController = appDelegate.splitViewCoordinator.splitViewController
                break
            case GlacierTabs.Screen.sms.rawValue:
                appDelegate.window?.rootViewController = appDelegate.smsSplitViewCoordinator.splitViewController
                break
            case GlacierTabs.Screen.dial.rawValue:
                appDelegate.window?.rootViewController = appDelegate.dialerViewController
                break
            case GlacierTabs.Screen.contacts.rawValue:
                appDelegate.window?.rootViewController = appDelegate.contactsViewController
                break
            default:
                break
            }
        }
    }
    
    func initData() {
        let tmgr = TwilioBackendManager.sharedMgr()
        if self.historyRecords.count == 0 {
            if let num = self.myNumber {
                self.historyRecords = CallRecord.allMessages(num)
            } else {
                self.historyRecords = CallRecord.allMessages()
            }
            self.callRecDict = Dictionary(uniqueKeysWithValues: historyRecords.map { ($0.twilioSid, $0) })
            self.addSpinnerHUD("Retrieving history (be patient)...")
        }
        
        tmgr.setCallHistoryDelegate(self)
        if tmgr.contacts.count == 0 {
            TwilioBackendManager.sharedMgr().fetchContacts(completion: { [weak self] (success) in
                DispatchQueue.main.async {
                    self?.tableView.reloadData()
                }
            })
        }
    }
    
    open func setAccount(_ myNumber:String) {
        self.myNumber = myNumber
        self.historyRecords = CallRecord.allMessages(myNumber)
        self.callRecDict = Dictionary(uniqueKeysWithValues: historyRecords.map { ($0.twilioSid, $0) })
    }
    
    @objc open func vmButtonPressed() {
        let vmViewController = VoicemailViewController.init()
        self.navigationController?.pushViewController(vmViewController, animated: true)
    }
    
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        
        if self.historyRecords.count == 0 && emptySet == false {
            DispatchQueue.main.async {
                self.emptySet = true
                if let emptyView = tableView as? EmptyStateTableView {
                    let img = UIImage.init(named: "glacier", in: GlacierInfo.resourcesBundle, with: nil)
                    let title = "No History"
                    let subtitle = "When you have calls, you'll see them here."
                    emptyView.setState(.noData(image: img, title: title, message: subtitle))
                    emptyView.separatorStyle = .none
                }
            }
        } else if self.historyRecords.count != 0 && emptySet == true {
            DispatchQueue.main.async {
                self.emptySet = false
                if let emptyView = tableView as? EmptyStateTableView {
                    emptyView.setState(.dataAvailable)
                    emptyView.separatorStyle = .singleLine
                }
            }
        }
        
        return self.historyRecords.count
    }
    
    override open func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return super.tableView(tableView, heightForHeaderInSection: section)
    }

    override open func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: CallHistoryCell.reuseIdentifier) as! CallHistoryCell
        
        cell.avatarImageView.image = self.outgoingImage
        cell.avatarImageView.tintColor = UIColor.label
        cell.avatarImageView.layer.borderWidth = 0.0

        cell.contentView.setNeedsUpdateConstraints()
        
        if (self.historyRecords.count == 0) {
            cell.nameLabel.text = "No Calls"
        } else {
            //cell.accountLabel.text = self.callRecords[indexPath.row].contact.phoneNumber
            cell.nameLabel.text = self.historyRecords[indexPath.row].name
            var dateString = self.historyRecords[indexPath.row].startTime
            if let date = inputFormatter.date(from: dateString) {
                dateString = dateFormatter.string(from: date)
            }
            cell.dateLabel.text = dateString
            cell.avatarImageView.image = historyRecords[indexPath.row].isIncoming ? self.incomingImage : self.outgoingImage
            if historyRecords[indexPath.row].isIncoming, historyRecords[indexPath.row].status == missedStatus {
                cell.avatarImageView.image = self.missedImage
            }
        }
        return cell
    }

    override open func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard historyRecords.count > 0 else { return }
        
        let phoneNumber = self.historyRecords[indexPath.row].phoneNumber
        let name = self.historyRecords[indexPath.row].name
        if CallManager.sharedCallManager().checkAudioPermissions() == true {
            AVAudioSession.sharedInstance().requestRecordPermission({ [weak self] (granted) in
                DispatchQueue.main.async {
                    if (granted) { return }
                    let alert = UIAlertController(title: "Allow Audio", message: "Whoops! It looks like you have not permitted Glacier to access your Microphone. To use Glacier calling, please enable the Microphone in the Glacier settings on your device.", preferredStyle: .alert)
                    let enableAction = UIAlertAction(title: "Enable", style: .default, handler: { alert in
                        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(settingsURL)
                        }
                    })
                    let cancelAction = UIAlertAction(title: "Cancel", style: .default, handler: nil)
                    alert.addAction(enableAction)
                    alert.addAction(cancelAction)
                    self?.present(alert, animated: true, completion: nil)
                }
            })
        }
            
        //IOSM-509 prevent accidental hot mic
        let alert = UIAlertController(title: "Start Call?", message: nil, preferredStyle: .alert)
        let callAction = UIAlertAction(title: "Call", style: .default, handler: { alert in
            CallManager.sharedCallManager().makeVoiceCall(phoneNumber, name: name)
        })
        let cancelAction = UIAlertAction(title: "Cancel", style: .default, handler: nil)
        alert.addAction(callAction)
        alert.addAction(cancelAction)
        self.present(alert, animated: true, completion: nil)
    }
    
    open override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return .delete
    }
    
    override open func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    override open func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let callRecord = self.historyRecords[indexPath.row]
            Task {
                do {
                    let didDeleteFromServer = try await TwilioBackendManager.sharedMgr().deleteCallRecord(with: callRecord.twilioSid)
                    
                    guard didDeleteFromServer else { return }
                    let didDeleteFromDB = try await CallRecord.deleteRecord(with: callRecord.uniqueId)
                    
                    guard didDeleteFromDB else { return }
                    self.historyRecords.remove(at: indexPath.row)
                    await MainActor.run {
                        tableView.beginUpdates()
                        tableView.deleteRows(at: [indexPath], with: .automatic)
                        tableView.endUpdates()
                    }
                } catch {
                    print("Error, deleting call record: \(error)")
                    self.handleFailedDelete()
                }
            }
        }
    }
    
    func handleFailedDelete() {
        let alert = UIAlertController(title: "Delete Failed", message: "Could not delete call record", preferredStyle: .alert)
        let cancelAction = UIAlertAction(title: "OK", style: .cancel, handler: nil)
        alert.addAction(cancelAction)
        self.present(alert, animated: true, completion: nil)
    }
}

extension HistoryViewController: CallHistoryDelegateProtocol {
    public func callHistoryUpdated(_ historyData: Data?) {
        guard let data = historyData else {
            self.removeSpinnerHUD()
            return
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data, options : .allowFragments) as? Dictionary<String,Any> {
            
            self.contacts = TwilioBackendManager.sharedMgr().contacts
            var callrecs : [CallRecord] = []
            if let incomingData = json["incomingCalls"] as? [Dictionary<String,Any>] {
                for rec in incomingData {
                    if let sid = rec["sid"] as? String, let to = rec["to"] as? String, let toFormatted = rec["toFormatted"] as? String, let from = rec["from"] as? String, let fromFormatted = rec["fromFormatted"] as? String, let status = rec["status"] as? String, let startTime = rec["startTime"] as? String, let endTime = rec["endTime"] as? String, let duration = rec["duration"] as? String, to.contains("sip") == false, from.contains("sip") == false, let direction = rec["direction"] as? String, direction == "inbound" {
                        
                        let cdr = CallRecord(uniqueId: sid, name:fromFormatted, phoneNumber:fromFormatted, incoming: true, twilioSid: sid, to: to, toFormatted: toFormatted, from: from, fromFormatted: fromFormatted, status: status, startTime: startTime, endTime: endTime, duration: duration)
                        
                        if callRecDict[sid] == nil {
                            let updatedCdr = self.processCallRecord(cdr: cdr)
                            callrecs.append(updatedCdr)
                            callRecDict[sid] = updatedCdr
                        }
                    }
                    
                }
            }
            
            if let outgoingData = json["outgoingCalls"] as? [Dictionary<String,Any>] {
                for rec in outgoingData {
                    if let sid = rec["sid"] as? String, let to = rec["to"] as? String, let toFormatted = rec["toFormatted"] as? String, let from = rec["from"] as? String, let fromFormatted = rec["fromFormatted"] as? String, let status = rec["status"] as? String, let startTime = rec["startTime"] as? String, let endTime = rec["endTime"] as? String, let duration = rec["duration"] as? String, to.contains("sip") == false, from.contains("sip") == false, to.contains("client") == false, let direction = rec["direction"] as? String, direction == "outbound-dial" {
                        
                        let cdr = CallRecord(uniqueId: sid, name:toFormatted, phoneNumber:toFormatted, incoming: false, twilioSid: sid, to: to, toFormatted: toFormatted, from: from, fromFormatted: fromFormatted, status: status, startTime: startTime, endTime: endTime, duration: duration)
                        
                        //if not exists in current records
                        if callRecDict[sid] == nil {
                            let updatedCdr = self.processCallRecord(cdr: cdr)
                            callrecs.append(updatedCdr)
                            callRecDict[sid] = updatedCdr
                        }
                    }
                    
                }
            }
            
            CallRecord.storeCallRecords(callRecords: callrecs, completion: {
                self.removeSpinnerHUD()
                if let num = self.myNumber {
                    self.historyRecords = CallRecord.allMessages(num)
                } else {
                    self.historyRecords = CallRecord.allMessages()
                }
                self.callRecDict = Dictionary(uniqueKeysWithValues: self.historyRecords.map { ($0.twilioSid, $0) })
                
                DispatchQueue.main.async {
                    self.tableView.reloadData()
                    self.updateMenuWithEraseAllOption()
                }
            })
        }
    }
    
    func processCallRecord(cdr: CallRecord) -> CallRecord {
        var modded = cdr
        
        var cdrnumber = CallManager.cleanPhoneNumber(cdr.from)
        if cdr.isIncoming == false {
            cdrnumber = CallManager.cleanPhoneNumber(cdr.to)
        }
            
        for contact in self.contacts {
            let cleanContact = CallManager.cleanPhoneNumber(contact.phoneNumber)
            if TwilioBackendManager.arePhoneNumbersEqualUS(phone1: cdrnumber, phone2: cleanContact) {
                modded.name = contact.name
                modded.phoneNumber = contact.phoneNumber
                break
            }
        }
        
        return modded
    }
}

extension HistoryViewController {
    public func addSpinnerHUD(_ message:String) {
        DispatchQueue.main.async {
            if (self.spinnerHUD == nil) {
                self.spinnerHUD = MBProgressHUD.showAdded(to: self.view, animated: true)
                self.spinnerHUD?.label.text = message
            }
        }
    }
    
    func removeSpinnerHUD() {
        DispatchQueue.main.async {
            if let hud = self.spinnerHUD {
                hud.removeFromSuperview()
                self.spinnerHUD = nil
            }
        }
    }
}

extension HistoryViewController : TwilioAccountDelegateProtocol {
    
    public func setSelectedAccount(_ account: SMSChatAccountModel?) {
        self.navigationItem.title = (account?.grdbRecord?.displayName ?? account?.grdbRecord?.phoneNumber) ?? "SMS"
        if let titleColor = account?.color, let appearance = self.navigationController?.navigationBar.standardAppearance {
            appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor : titleColor]
            self.navigationController?.navigationBar.standardAppearance = appearance
            self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
            self.navigationController?.navigationBar.tintColor = titleColor
        }
        //filter records
        if let number = account?.grdbRecord?.phoneNumber {
            self.setAccount(number)
            TwilioBackendManager.sharedMgr().queryCallHistory()
        }
        
        if !vmEnabled, AWSAcctManager.sharedMgr().getGlacierEnablements()?.voicemailEnabled == true {
            self.vmEnabled = true
            self.navigationItem.rightBarButtonItem = self.vmBtn
        }
    }
    
    public func voicemailUpdated() {
        self.handleVMStatus()
    }
    
    @objc func handleVMStatus() {
        if self.vmEnabled {
            if TwilioBackendManager.sharedMgr().hasNewVM, self.vmBtnNew != nil {
                self.navigationItem.rightBarButtonItem = self.vmBtnNew
            } else {
                self.navigationItem.rightBarButtonItem = self.vmBtn
            }
        }
    }
    
    public func accountsUpdated() {
        let tmgr = TwilioBackendManager.sharedMgr()
        let accounts = tmgr.currentAccounts
        let selected = tmgr.selectedAccount
        var menuItems: [UIMenuElement] = []
        
        for account in accounts {
            let phoneImage = UIImage(systemName:"phone")?.withTintColor(account.color ?? UIColor.orange, renderingMode: .alwaysOriginal)
            
            guard let phonenumber = account.grdbRecord?.phoneNumber else { continue }
            
            var natitle = phonenumber
            if let naname = account.grdbRecord?.displayName {
                natitle = natitle + " " + naname
                if (natitle.count > 21) {
                    natitle = natitle.prefix(18) + "..."
                }
            }
            
            let numberAction = UIAction(title: natitle, image: phoneImage, handler: {(_) in
                TwilioBackendManager.sharedMgr().selectedAccount = account
            })
            
            menuItems.append(numberAction)
        }
        
        DispatchQueue.main.async {
            if (accounts.count == 0) {
                //selectedAccount = nil
                self.navigationItem.title = "No account"
            } else if let selacct = selected {
                self.setSelectedAccount(selacct)
            }
            
            self.smsMenu = UIMenu(title: "Phone Numbers", children: menuItems)
            self.settingsButton.menu = self.smsMenu
        }
    }
    
    private func updateMenuWithEraseAllOption() {
        var menuItems: [UIMenuElement] = self.smsMenu.children
        let clearAllHistoryActionTitle = "Clear all history"
        if !self.historyRecords.isEmpty {
            if menuItems.first(where: {$0.title == clearAllHistoryActionTitle}) == nil {
                let clearHistoryAction = UIAction(title: clearAllHistoryActionTitle, image: UIImage(systemName: "clock"), handler: { _ in
                    self.deleteAllRecords()
                })
                menuItems.append(clearHistoryAction)
            }
        } else {
            if let index = menuItems.firstIndex(where: {$0.title == clearAllHistoryActionTitle}) {
                menuItems.remove(at: index)
            }
        }
        
        self.smsMenu = UIMenu(title: "Phone Numbers", children: menuItems)
        self.settingsButton.menu = self.smsMenu
    }
    
    private func deleteAllRecords() {
        Task {
            do {
                guard let userAccount = ChatAccountModel.currentAccount,
                      let smsChatAccount = TwilioBackendManager.sharedMgr().selectedAccount,
                      let phoneNumber = smsChatAccount.grdbRecord?.phoneNumber else { return }
                
                let didDeleteFromServer = try await TwilioBackendManager.sharedMgr().deleteAllCallRecords(
                    for: userAccount.username,
                    phoneNumber: phoneNumber
                )
                
                guard didDeleteFromServer else { return }
                let didDeleteFromDB = try await CallRecord.deleteAllRecords()
                
                guard didDeleteFromDB else { return }
                await MainActor.run {
                    self.historyRecords.removeAll()
                    self.tableView.reloadData()
                    self.updateMenuWithEraseAllOption()
                }
            } catch {
                print("Error, deleting call record: \(error)")
                self.handleFailedDelete()
            }
        }
    }
}
