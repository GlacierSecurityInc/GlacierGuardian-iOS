//
//  ContactsViewController.swift
//  Glacier
//
//  Created by andyfriedman on 1/20/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import UIKit
import AVFoundation

@objc open class ContactsViewController: UITableViewController, UISearchBarDelegate, UITextFieldDelegate, UITabBarDelegate {
    
    var phoneContacts = [PhoneContact]()
    var accountId : String?
    var sendingNumber : String?
    
    var smsMenu: UIMenu
    var settingsButton: UIBarButtonItem
    
    var vmBtn:UIBarButtonItem?
    var vmBtnNew:UIBarButtonItem?
    var vmEnabled = false
    
    var filteredContacts = [PhoneContact]()
    let tableViewHeader = VerticalStackView.init()
    var modalStyle: UIModalPresentationStyle?
    var defaultImage = UIImage.init(named: "person", in: GlacierInfo.resourcesBundle, with: nil)?.withRenderingMode(.alwaysTemplate)
    var tabBar:GlacierTabs?
    private var searchBar = UISearchBar()
    
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
        
        TwilioBackendManager.sharedMgr().fetchContacts(completion: { [weak self] (success) in
            self?.handleContacts()
        })
        
        self.tableView.register(PhoneContactCell.self, forCellReuseIdentifier: PhoneContactCell.reuseIdentifier())
        
        self.settingsButton.menu = self.smsMenu
        
        self.navigationItem.leftBarButtonItem = self.settingsButton
        
        /*let contacts = TwilioBackendManager.sharedMgr().contacts.filter({ (contact) -> Bool in
            return contact.phoneNumber.count > 6
        })
        phoneContacts = contacts
        self.filteredContacts = contacts*/
        
        self.setupSearchHeaderView()
        self.setupTapGestureRecognizer()
        
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
        self.tableView.rowHeight = BuddyInfoCellHeight
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
    
    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.view.endEditing(true)
        self.searchBar.text = nil
        self.showAllContacts()
    }
    
    override open func viewWillAppear(_ animated:Bool) {
        super.viewWillAppear(animated)
        self.tabBar?.selectedItem = self.tabBar?.contactsItem
        if let acctrec = TwilioBackendManager.sharedMgr().selectedAccount?.grdbRecord {
            let title = acctrec.displayName ?? acctrec.phoneNumber
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
        if let appDelegate = Application.shared.delegate as? GlacierAppDelegate {
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
            case GlacierTabs.Screen.history.rawValue:
                appDelegate.window?.rootViewController = appDelegate.historyViewController
                break
            default:
                break
            }
        }
    }
    
    @objc open func vmButtonPressed() {
        let vmViewController = VoicemailViewController.init()
        self.navigationController?.pushViewController(vmViewController, animated: true)
    }
    
    func handleContacts() {
        let contacts = TwilioBackendManager.sharedMgr().contacts.filter({ (contact) -> Bool in
            return contact.phoneNumber.count > 6
        })
        self.phoneContacts = contacts
        self.filteredContacts = contacts
        DispatchQueue.main.async {
            self.tableView.reloadData()
        }
    }
    
    open func setAccount(_ account:String, myNumber:String) {
        self.accountId = account
        self.sendingNumber = myNumber
    }
    
    private func setupSearchHeaderView() {
        let headerView = UIView(
            frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 56)
        )
        headerView.backgroundColor = UIColor.systemGroupedBackground
        
        searchBar.frame = headerView.bounds
        searchBar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        searchBar.placeholder = "Search"
        searchBar.delegate = self

        headerView.addSubview(searchBar)
        self.tableView.tableHeaderView = headerView
    }
    
    private func setupTapGestureRecognizer() {
        let tapGesture = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTableViewTap)
        )
        tapGesture.cancelsTouchesInView = false
        tableView.addGestureRecognizer(tapGesture)
    }
    
    @objc private func handleTableViewTap() {
        view.endEditing(true)
    }
    
    public func textFieldShouldClear(_ textField: UITextField) -> Bool {
        self.searchBar.text = nil
        self.showAllContacts()
        
        return true
    }
    
    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        let searchString = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchString.isEmpty else {
            self.showAllContacts()
            return
            
        }
        
        self.filteredContacts = self.phoneContacts.filter { $0.phoneNumber.count > 6 && $0.name.lowercased().contains(searchString.lowercased()) }
        self.tableView.reloadData()
    }
    
    private func showAllContacts() {
        self.filteredContacts.removeAll()
        self.filteredContacts.append(contentsOf: self.phoneContacts)
        self.tableView.reloadData()
    }
    
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.filteredContacts.count
    }
    
    override open func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return super.tableView(tableView, heightForHeaderInSection: section)
    }

    override open func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: PhoneContactCell.reuseIdentifier()) as! PhoneContactCell
        cell.delegate = self
        cell.avatarImageView.image = self.defaultImage
        cell.avatarImageView.tintColor = UIColor.label
        cell.avatarImageView.layer.borderWidth = 0.0
        cell.imageViewBorderColor = Colors.color(with: ThreadStatus.offline)
        cell.avatarImageView.layer.cornerRadius = (SMSViewController.kOTRConversationCellHeight-2.0*BuddyImageCellPadding)/2.0
        cell.selectionStyle = .none

        cell.contentView.setNeedsUpdateConstraints()
        if self.filteredContacts.isEmpty {
            cell.nameLabel.text = "No Numbers"
        } else {
            cell.setContact(self.filteredContacts[indexPath.row])
        }
        
        return cell
    }
}

extension ContactsViewController: PhoneContactDelegateProtocol {
    func smsTapped(_ contact: PhoneContact) {
        presentOutboundSMSUnavailableAlert()
    }

    private func presentOutboundSMSUnavailableAlert() {
        let alert = UIAlertController(
            title: "Outbound SMS Unavailable",
            message: "Outbound text messages are temporarily unavailable. New U.S. telecom compliance rules (10DLC) require recipients to opt in before they can receive messages. This is not currently compatible with Guardian users, and we are working with our carrier on an alternative solution.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        alert.addAction(UIAlertAction(title: "Read More", style: .default, handler: { _ in
            if let url = URL(string: "https://www.notion.so/glaciersecurity/SMS-and-10DLC-32cfab645d9380bc9abeffdeceda533d") {
                UIApplication.shared.open(url)
            }
        }))
        present(alert, animated: true, completion: nil)
    }
    
    func phoneTapped(_ contact: PhoneContact) {
        if CallManager.sharedCallManager().checkAudioPermissions() == true {
            AVAudioSession.sharedInstance().requestRecordPermission({ [weak self] (granted) in
                DispatchQueue.main.async {
                    if (granted) { return }
                    let alert = UIAlertController(title: "Allow Audio", message: "Whoops! It looks like you have not permitted Guardian to access your Microphone. To use Guardian calling, please enable the Microphone in the Guardian settings on your device.", preferredStyle: .alert)
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
            
        let alert = UIAlertController(title: "Start Call?", message: nil, preferredStyle: .alert)
        let callAction = UIAlertAction(title: "Call", style: .default, handler: { alert in
            CallManager.sharedCallManager().makeVoiceCall(contact)
        })
        let cancelAction = UIAlertAction(title: "Cancel", style: .default, handler: nil)
        alert.addAction(callAction)
        alert.addAction(cancelAction)
        self.present(alert, animated: true, completion: nil)
    }
}

extension ContactsViewController : TwilioAccountDelegateProtocol {
    public func setSelectedAccount(_ account: SMSChatAccountModel?) {
        self.navigationItem.title = (account?.grdbRecord?.displayName ?? account?.grdbRecord?.phoneNumber) ?? "SMS"
        if let titleColor = account?.color, let appearance = self.navigationController?.navigationBar.standardAppearance {
            appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor : titleColor]
            self.navigationController?.navigationBar.standardAppearance = appearance
            self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
            self.navigationController?.navigationBar.tintColor = titleColor
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
}
