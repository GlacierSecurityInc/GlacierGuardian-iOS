//  Glacier
//  Created by andyfriedman on 9/6/22.
//  Copyright © 2022 Glacier. All rights reserved.

import UIKit
import Alamofire
import Contacts
import PureLayout
import GRDB
import MBProgressHUD

@objc public protocol SMSViewControllerDelegate {
    func didSelectThread(_ smsConversation:SMSChatConversationModel, smsViewController: SMSViewController)
    func didSelectCompose(_ smsViewController: SMSViewController, with account:String, number:String)
}

@objc public class SMSViewController: UIViewController, UITableViewDelegate, TwilioAccountDelegateProtocol, SMSNumbersDelegate, UIGestureRecognizerDelegate, UITabBarDelegate {
    
    static let kOTRConversationCellHeight = 80.0

    var numAction: SMSNumbersAction?
    var addRemoveMenu: UIMenu
    var smsMenu: UIMenu
    var settingsButton: UIBarButtonItem
    var addNumber: UIAction?
    var releaseNumber: UIAction?
    var nameNumber: UIAction?
    var copyNumber: UIAction?
    let sessionManager = Alamofire.Session(configuration: URLSessionConfiguration.ephemeral)
    
    let tableView = EmptyStateTableView(frame: .zero, style: .plain, centerOffset: CGPoint(x: 0.0, y: -64.0))
    private var dataSource: SMSConversationDataSource!
    private var convCancellable: DatabaseCancellable?
    
    var purchasedNumber:String?
    var purchasedName:String?
    var longIndex:IndexPath?
    
    private var observed = false
    var spinnerHUD: MBProgressHUD?
    
    var filteredConversations = [SMSChatConversation]()
    @objc public var delegate: SMSViewControllerDelegate?
    var tabBar:GlacierTabs? //IOSM#90
    
    var vmBtn:UIBarButtonItem?
    var vmBtnNew:UIBarButtonItem?
    var vmEnabled = false
    var addNumberOpen = false
    var composeBtn:UIBarButtonItem!
    
    var shouldHaveToolTip = false
    
    public init() {
        let lblColor = UIColor.label
        let settingsIcon = UIImage(named: "OTRSettingsIcon-1", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        
        settingsButton = UIBarButtonItem(image: settingsIcon, style: UIBarButtonItem.Style.plain, target: nil, action:nil)
        settingsButton.tintColor = lblColor
        
        let initial = UIAction(title: "No numbers to display", handler: { (_) in  })
        addRemoveMenu = UIMenu(title: "", options: .displayInline, children: [initial])
        
        let items = [self.addRemoveMenu]
        smsMenu = UIMenu(title: "Phone Numbers", children: items)
        super.init(nibName:nil, bundle:nil)
        
        self.addNumber = UIAction(title: "Add Number", image: UIImage(systemName: "plus"), handler: { (_) in
            self.handleAddNumber()
        })
        self.releaseNumber = UIAction(title: "Release Number", image: UIImage(systemName: "trash"), handler: { (_) in
            self.setNumbersWithAction(SMSNumbersAction.release)
        })
        self.nameNumber = UIAction(title: "Name a Number", image: UIImage(systemName: "person"), handler: { (_) in
            self.setNumbersWithAction(SMSNumbersAction.name)
        })
        self.copyNumber = UIAction(title: "Copy Number", image: UIImage(systemName: "doc.on.doc"), handler: { (_) in
            self.doCopy()
        })
        
        let composeIcon = UIImage(named: "new_message", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        composeBtn = UIBarButtonItem(image: composeIcon, style: UIBarButtonItem.Style.plain, target: self, action: #selector(composeButtonPressed(_:)))
        composeBtn.tintColor = lblColor
        
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
        let tmgr = TwilioBackendManager.sharedMgr()
        let accounts = tmgr.currentAccounts
        let selected = tmgr.selectedAccount
        
        let vmIcon = UIImage(systemName: "recordingtape")?.imageMasked(with: UIColor.label)
        
        let customView = createCustomBarButtonView(with: vmIcon!)
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(vmButtonPressed))
        customView.isUserInteractionEnabled = true
        customView.addGestureRecognizer(tapGesture)
        vmBtnNew = UIBarButtonItem(customView: customView)
        vmBtnNew?.style = UIBarButtonItem.Style.plain
        
        if (accounts.count > 0 && selected?.grdbRecord?.phoneNumber != nil) {
            self.navigationItem.title = selected?.grdbRecord?.displayName ?? selected?.grdbRecord?.phoneNumber
            
            if AWSAcctManager.sharedMgr().getGlacierEnablements()?.voicemailEnabled == true {
                self.vmEnabled = true
            }
        } else if accounts.count > 0 {
            self.navigationItem.title = accounts.first?.grdbRecord?.displayName ?? accounts.first?.grdbRecord?.phoneNumber
            
        } else {
            self.navigationItem.title = "SMS"
        }
        
        let backitem = UIBarButtonItem(title: " ", style: .plain, target: nil, action: nil)
        self.navigationItem.backBarButtonItem = backitem
        
        self.tableView.delegate = self
        self.configureDataSource()
        self.tableView.register(OTRConversationCell.self, forCellReuseIdentifier: OTRConversationCell.reuseIdentifier())
        
        self.tableView.accessibilityIdentifier = "smsTableView";
        self.tableView.translatesAutoresizingMaskIntoConstraints = false
        self.tableView.rowHeight = SMSViewController.kOTRConversationCellHeight
        self.tableView.tableFooterView = UIView.init()
        self.tableView.separatorStyle = .none
        self.view.addSubview(self.tableView)
        
        let lblColor = UIColor.label
        var titleColor = lblColor
        if let tcolor = selected?.color {
            titleColor = tcolor
        } else if let ccolor = accounts.first?.color {
            titleColor = ccolor
        }
        
        let appearance = UINavigationBarAppearance.init()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = GlobalTheme.shared.lightThemeColor
        appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor : titleColor]
        self.navigationController?.navigationBar.standardAppearance = appearance
        self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
        self.navigationController?.navigationBar.tintColor = titleColor
        
        //IOSM#85
        if !self.shouldHaveToolTip && self.settingsButton.menu == nil {
            self.settingsButton.menu = self.smsMenu
        }
        
        self.navigationItem.leftBarButtonItem = self.settingsButton
        self.navigationItem.rightBarButtonItems = [composeBtn]
        
        //IOSM#90
        self.tabBar = GlacierTabs()
        if let tabs = self.tabBar {
            self.navigationController?.view.addSubview(tabs)
            tabs.delegate = self
            tabs.setPhoneModule()
        }
        
        if let tabBarHeight = self.tabBar?.frame.height {
            self.tableView.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor).isActive = true
            self.tableView.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -tabBarHeight).isActive = true
            if let navwidth = self.navigationController?.view.frame.size.width {
                self.tableView.widthAnchor.constraint(equalToConstant: CGFloat(navwidth)).isActive = true
            }
        }
        
        self.setupLongPress()
        TwilioBackendManager.sharedMgr().fetchContacts(completion: {_ in })
        
        if self.observed == false {
            self.addSpinnerHUD("Retrieving data...")
        } else {
            self.observeConversations()
        }
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
            
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor)
        ])
            
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
    
    private func configureDataSource() {
        self.dataSource = SMSConversationDataSource(tableView: tableView, cellProvider: { [weak self] (tableView, indexPath, conversation) ->  UITableViewCell?  in
            
            let cell = tableView.dequeueReusableCell(withIdentifier: OTRConversationCell.reuseIdentifier(), for: indexPath) as? OTRConversationCell
            cell?.selectionStyle = UITableViewCell.SelectionStyle.default
            cell?.avatarImageView.layer.cornerRadius = (SMSViewController.kOTRConversationCellHeight-2.0*OTRBuddyImageCellPadding)/2.0
            
            let thread = SMSChatConversationModel(conversation: conversation)
            if let ccell = cell {
                self?.setSMSThread(ccell, smsConversation: thread)
            }
            
            return cell ?? UITableViewCell()
        })
        self.dataSource.accountId = TwilioBackendManager.sharedMgr().selectedAccount?.uniqueId
        self.tableView.dataSource = self.dataSource
    }
    
    //IOSM#90
    public func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        self.navigationController?.popToRootViewController(animated: false)
        if let appDelegate = Application.shared.delegate as? OTRAppDelegate {
            switch (item.tag) {
            case GlacierTabs.Screen.chats.rawValue:
                appDelegate.window?.rootViewController = appDelegate.splitViewCoordinator.splitViewController
                break
            case GlacierTabs.Screen.dial.rawValue:
                appDelegate.window?.rootViewController = appDelegate.dialerViewController
                break
            case GlacierTabs.Screen.contacts.rawValue:
                appDelegate.window?.rootViewController = appDelegate.contactsViewController
                break
            case GlacierTabs.Screen.history.rawValue:
                appDelegate.window?.rootViewController = appDelegate.historyViewController
                break
            default:
                break
            }
        }
    }
    
    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        TwilioBackendManager.sharedMgr().getToken()
        self.navigationController?.isToolbarHidden = true
        self.tableView.tableHeaderView = nil
        self.tabBar?.isHidden = false
        self.tabBar?.selectedItem = self.tabBar?.smsItem //IOSM#90
        
        //check vm status
        self.handleVMStatus()
    }
    
    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if self.shouldHaveToolTip {
            self.setToolTipOnLoad()
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
            if self.observed == false {
                self.observeConversations()
            }
            
            if (accounts.count == 0) {
                self.navigationItem.title = "SMS"
            } else if let selacct = selected {
                self.setSelectedAccount(selacct)
            }
            
            if menuItems.count == 0 && tmgr.glacierSMS?.addUserToPurchaseNumbers == false { //IOSM#85
                self.shouldHaveToolTip = true
                self.settingsButton.menu = nil
                self.settingsButton.addToolTip(description: "You are not authorized to add a number. Please contact your administrator.")
            } else {
                self.shouldHaveToolTip = false
                self.settingsButton.removeToolTip()
                self.setAddRemoveMenu()
                menuItems.append(self.addRemoveMenu)
                self.smsMenu = UIMenu(title: "Phone Numbers", children: menuItems)
                self.settingsButton.menu = self.smsMenu
            }
        }
    }
    
    public func availableNumbersUpdated(_ availableNumbers: [String]) {
        DispatchQueue.main.async {
            guard let appDelegate = Application.shared.delegate as? OTRAppDelegate, appDelegate.window?.rootViewController == appDelegate.smsSplitViewCoordinator.splitViewController else {
                return
            }
            
            if self.addNumberOpen {
                //passthedata?  //for now the modal is it's own delegate and this not needed
            } else if availableNumbers.count > 0 {
                var availableNames: [String?] = []
                for _ in availableNumbers {
                    availableNames.append(nil)
                }
                
                let smsNumbersViewController = SMSNumbersViewController()
                smsNumbersViewController.delegate = self
                self.numAction = SMSNumbersAction.add
                smsNumbersViewController.setNumbers(availableNumbers, names: availableNames, action:SMSNumbersAction.add)
                let modalNavigationController = UINavigationController(rootViewController: smsNumbersViewController)
                modalNavigationController.modalPresentationStyle = .formSheet
                self.addNumberOpen = true
                
                self.present(modalNavigationController, animated: true, completion: nil)
            }
        }
    }
    
    func handleAddNumber() {
        let tmgr = TwilioBackendManager.sharedMgr()
        if (tmgr.currentAccounts.count > 4) {
            let alert = UIAlertController(title: "Unable to Add Number", message: "There is a limit of 5 numbers. Remove one or more numbers to add another.", preferredStyle: .alert)
            let cancelAction = UIAlertAction(title: "OK", style: .default, handler: nil)
            alert.addAction(cancelAction)
            present(alert, animated: true, completion: nil)
            return
        }
        
        TwilioBackendManager.sharedMgr().queryForAvailableNumbers(areaCode:nil, contains: nil)
    }
    
    public func numbersControllerClosed() {
        self.addNumberOpen = false
    }
    
    public func setSelectedAccount(_ account:SMSChatAccountModel?) {
        self.dataSource?.accountId = account?.uniqueId
        self.navigationItem.title = (account?.grdbRecord?.displayName ?? account?.grdbRecord?.phoneNumber) ?? "SMS"
            //change nav title color
        if let titleColor = account?.color, let appearance = self.navigationController?.navigationBar.standardAppearance {
            appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor : titleColor]
            self.navigationController?.navigationBar.standardAppearance = appearance
            self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
            self.navigationController?.navigationBar.tintColor = titleColor
        }
        
        if !vmEnabled, AWSAcctManager.sharedMgr().getGlacierEnablements()?.voicemailEnabled == true {
            self.vmEnabled = true
        }
        
        self.observeConversations()
    }
    
    public func voicemailUpdated() {
        self.handleVMStatus()
    }
    
    @objc func handleVMStatus() {
        if self.vmEnabled {
            if TwilioBackendManager.sharedMgr().hasNewVM, self.vmBtnNew != nil {
                self.navigationItem.rightBarButtonItems = [composeBtn, self.vmBtnNew!]
            } else {
                self.navigationItem.rightBarButtonItems = [composeBtn, self.vmBtn!]
            }
        }
    }
    
    func setToolTipOnLoad() {
        self.settingsButton.removeToolTip()
        self.settingsButton.menu = nil
        self.settingsButton.addToolTip(description: "You are not authorized to add a number. Please contact your administrator.")
    }
    
    //pragma - mark GestureRecognizerDelegate methods
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
    
    private func setupLongPress() {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(didLongPress(_:)))
        longPress.minimumPressDuration = 1.0 // 1 second press
        longPress.delegate = self
        longPress.cancelsTouchesInView = false
        self.tableView.addGestureRecognizer(longPress)
        
        let singlePress = UITapGestureRecognizer(target: self, action: #selector(didSinglePress(_:)))
        singlePress.cancelsTouchesInView = false
        singlePress.delegate = self
        singlePress.require(toFail: longPress)
        self.tableView.addGestureRecognizer(singlePress)
    }
    
    @objc private func didSinglePress(_ gestureRecognizer: UITapGestureRecognizer) {
        if (gestureRecognizer.state == UIGestureRecognizer.State.began) {
            let touchPoint = gestureRecognizer.location(in: self.tableView)
            if let indexPath = self.tableView.indexPathForRow(at: touchPoint) {
                self.tableView(self.tableView, didSelectRowAt: indexPath)
            }
        }
    }
    
    @objc private func didLongPress(_ longPressGestureRecognizer: UILongPressGestureRecognizer) {
        if (longPressGestureRecognizer.state == UIGestureRecognizer.State.began) {
            let touchPoint = longPressGestureRecognizer.location(in: self.tableView)
            if let indexPath = self.tableView.indexPathForRow(at: touchPoint) {
                self.longIndex = indexPath
                let menu = UIMenuController.shared
                let displayNameItem = UIMenuItem(title: "Set Display Name", action: #selector(setDisplayName))
                menu.menuItems = [displayNameItem]
                
                let cell = self.tableView.cellForRow(at: indexPath)
                cell?.becomeFirstResponder()
                
                menu.update()
                menu.showMenu(from: self.tableView, rect: self.tableView.rectForRow(at: indexPath))
            }
        }
    }
    
    @objc func setDisplayName() {
        UIMenuController.shared.menuItems = nil
        
        if let ipath = self.longIndex, let conv = self.threadFor(indexPath: ipath) {
            self.longIndex = nil
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = NSTextAlignment.left
            
            let alert = UIAlertController(title: NSLocalizedString("Display name", comment: "Display name for conversation"), message: nil, preferredStyle: UIAlertController.Style.alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("Add name", comment: "Add name button"), style: UIAlertAction.Style.default, handler: {(action: UIAlertAction!) in
                if let displayName = alert.textFields?.first?.text, displayName.count > 0 {
                    conv.grdbRecord?.preferredName = displayName
                } else {
                    conv.grdbRecord?.preferredName = conv.grdbRecord?.remoteNumber
                }
                conv.save()
            }))
            
            let msg = "\nWould you like to give this number a name for simplicity? This will not be stored to contacts, only you will see this name, and it will disappear if you log out."
            let messageText = NSMutableAttributedString(
                string: msg,
                attributes: [
                    NSAttributedString.Key.paragraphStyle: paragraphStyle,
                    NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13)
                ]
            )
            alert.setValue(messageText, forKey: "attributedMessage")
            
            alert.addAction(UIAlertAction(title: NSLocalizedString("No thanks", comment: "No button"), style: UIAlertAction.Style.cancel, handler: nil))
            alert.addTextField(configurationHandler: {(textField: UITextField!) in
                textField.placeholder = "Contact name"
                if let dname = conv.grdbRecord?.preferredName, let firstChar = dname.first, firstChar.isLetter {
                    textField.text = dname
                }
                textField.isSecureTextEntry = false
            })
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    func setAddRemoveMenu() {
        var bottomActions = [UIAction]()
        
        let tmgr = TwilioBackendManager.sharedMgr()
        if tmgr.glacierSMS?.addUserToPurchaseNumbers == true, let addNum = self.addNumber {
            bottomActions.append(addNum)
        }
        
        if tmgr.glacierSMS?.addUserToPurchaseNumbers == true && tmgr.currentAccounts.count > 0, let releaseNum = self.releaseNumber {
                bottomActions.append(releaseNum)
        }
        
        if tmgr.currentAccounts.count > 0, let nameNum = self.nameNumber, let copyNum = self.copyNumber {
            bottomActions.append(nameNum)
            bottomActions.append(copyNum)
        }
                
        self.addRemoveMenu = UIMenu(title: "", options: .displayInline, children: bottomActions)
    }
    
    public func numberSelected(_ selectedNumber:String, selectedName:String?) {
        let tmgr = TwilioBackendManager.sharedMgr()
        if self.numAction == SMSNumbersAction.release {
            self.addSpinnerHUD("Releasing number (be patient)...")
            tmgr.releaseNumber(selectedNumber)
        } else if self.numAction == SMSNumbersAction.name {
            tmgr.nameANumber(selectedNumber, selectedName: selectedName)
        } else if self.numAction == SMSNumbersAction.add {
            self.addSpinnerHUD("Initializing number (be patient)...")
            tmgr.purchaseNumber(selectedNumber, selectedName: selectedName)
        }
        self.numAction = nil
        if self.numAction != SMSNumbersAction.name {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                self.removeSpinnerHUD()
            }
        }
    }
    
    func setNumbersWithAction(_ action:SMSNumbersAction) {
        self.numAction = action
        
        let tmgr = TwilioBackendManager.sharedMgr()
        let smsNumbersViewController = SMSNumbersViewController()
        smsNumbersViewController.delegate = self
        var currentNumbers:[String] = []
        var currentNames:[String?] = []
        for acct in tmgr.currentAccounts {
            if let number = acct.grdbRecord?.phoneNumber {
                currentNumbers.append(number)
                if let dis = acct.grdbRecord?.displayName {
                    currentNames.append(dis)
                }
            }
        }
        smsNumbersViewController.setNumbers(currentNumbers, names: currentNames, action: action)
        let modalNavigationController = UINavigationController(rootViewController: smsNumbersViewController)
        modalNavigationController.modalPresentationStyle = .formSheet
        
        self.present(modalNavigationController, animated: true, completion: nil)
    }
    
    func doCopy() {
        let alert = UIAlertController(title: "Copy to Clipboard?", message: "Copying this number to your device will allow any other apps on your device to access it.", preferredStyle: .alert)
    
        alert.addAction(UIAlertAction(title: "Copy", style: .default) { _ in
            UIPasteboard.general.string = TwilioBackendManager.sharedMgr().selectedAccount?.grdbRecord?.phoneNumber
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: {(action: UIAlertAction!) in
            self.dismiss(animated: true, completion: nil)
        }))
    
        self.present(alert, animated: true)
    }
    
    @objc open func vmButtonPressed() {
        let vmViewController = VoicemailViewController.init()
        self.navigationController?.pushViewController(vmViewController, animated: true)
    }
    
    @objc open func composeButtonPressed(_ sender: AnyObject?) {
        if let acct = TwilioBackendManager.sharedMgr().selectedAccount, let number = acct.grdbRecord?.phoneNumber {
            self.delegate?.didSelectCompose(self, with: acct.uniqueId, number: number)
        }
    }
    
    func threadFor(indexPath: IndexPath) -> SMSChatConversationModel? {
        if let conversation = self.dataSource.itemIdentifier(for: indexPath) {
            return SMSChatConversationModel(conversation: conversation)
        }
        return nil
    }
    
    
    open func tableView(_ tableView: UITableView, shouldShowMenuForRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    open func tableView(_ tableView: UITableView, canPerformAction action: Selector, forRowAt indexPath: IndexPath, withSender sender: Any?) -> Bool {
        return (action == #selector(setDisplayName))
    }

    open func tableView(_ tableView: UITableView, performAction action: Selector, forRowAt indexPath: IndexPath, withSender sender: Any?) {
        //required
    }
    
    func setSMSThread(_ cell:OTRConversationCell, smsConversation: SMSChatConversationModel) {
        cell.avatarImageView.image = smsConversation.avatar ?? UIImage.init(named: "person", in: GlacierInfo.resourcesBundle, with: nil)?.withRenderingMode(.alwaysTemplate)
        cell.avatarImageView.tintColor = UIColor.label
        cell.avatarImageView.layer.borderWidth = 0.0
        cell.imageViewBorderColor = Colors.color(with:ThreadStatus.offline)

        cell.contentView.setNeedsUpdateConstraints()
        
        cell.nameLabel.text = smsConversation.grdbRecord?.preferredName ?? smsConversation.grdbRecord?.remoteNumber
        
        smsConversation.lastMessage(completion: {lastMessage in
            DispatchQueue.main.async {
                var messageText = lastMessage?.grdbRecord?.msgText ?? ""
                if lastMessage?.isMediaMessage() == true {
                    messageText = "📷 " + PICTURE_MESSAGE_STRING()
                }
                
                var messageTextPrefix = ""
                if let lastMsg = lastMessage, !lastMsg.isIncoming() {
                    let you = GROUP_INFO_YOU().localizedCapitalized
                    messageTextPrefix = you + ": "
                }
                cell.conversationLabel.text = messageTextPrefix + messageText
                cell.updateDateString(lastMessage?.grdbRecord?.messageDate)
            }
            if let lastDate = lastMessage?.grdbRecord?.messageDate, let convDate = smsConversation.getLatestMessageDate(), lastDate > convDate {
                smsConversation.grdbRecord?.latestMessageDate = lastDate
                smsConversation.save()
            }
        })
        
        cell.nameLabel.textColor = UIColor.label
        cell.dateLabel.textColor = UIColor.label
    }

    open func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if let conversation = self.dataSource.itemIdentifier(for: indexPath) {
            let thread = SMSChatConversationModel(conversation: conversation)
            self.delegate?.didSelectThread(thread, smsViewController: self)
            TwilioBackendManager.sharedMgr().verifyConversation(thread)
            self.tableView.deselectRow(at: indexPath, animated: false)
        }
    }
    
    open func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return SMSViewController.kOTRConversationCellHeight
    }
 
    open func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return SMSViewController.kOTRConversationCellHeight
    }
    
    private func updateDataSource(from conversations: [SMSChatConversation]) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, SMSChatConversation>()
        snapshot.appendSections([0])
        snapshot.appendItems(conversations, toSection: 0)
        snapshot.reloadItems(conversations)
            
        if let ds = self.dataSource {
            ds.itemCnt = snapshot.numberOfItems
            ds.apply(snapshot, animatingDifferences: false)
        }
            // Restore selection
    }
    
    private func observeConversations() {
        let request: QueryInterfaceRequest<SMSChatConversation>
        let selected = TwilioBackendManager.sharedMgr().selectedAccount
        self.dataSource?.accountId = selected?.uniqueId
        
        if let phonenum = selected?.grdbRecord?.phoneNumber {
            request = SMSChatConversation.all().filter(Column("localNumber") == phonenum).order(Column("latestMessageDate").desc)
        } else {
            request = SMSChatConversation.all().order(Column("latestMessageDate").desc) //.order
        }
        
        self.observed = true
        self.removeSpinnerHUD()
            
        convCancellable = ValueObservation
            .tracking(request.fetchAll(_:))
            .start(
                in: DBManager.sharedDB().grdbStorage.pool,
                // Immediate scheduling feeds the data source right on subscription,
                // and avoids an undesired animation when the application starts.
                scheduling: .immediate,
                onError: { error in fatalError("Unexpected error: \(error)") },
                onChange: { [weak self] conversations in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        self.updateDataSource(from: conversations)
                        self.updateMenuWithEraseAllOption()
                    }
                })
    }
    
    private func updateMenuWithEraseAllOption() {
        var menuItems: [UIMenuElement] = self.smsMenu.children
        guard let ds = self.dataSource, menuItems.count > 1, let actionsMenu = menuItems[1] as? UIMenu else { return }
        
        var actionsMenuItems = actionsMenu.children
        let clearAllHistoryActionTitle = "Clear all messages"
        if ds.itemCnt > 0 {
            if actionsMenuItems.first(where: {$0.title == clearAllHistoryActionTitle}) == nil {
                let clearHistoryAction = UIAction(title: clearAllHistoryActionTitle, image: UIImage(systemName: "message"), handler: { _ in
                    self.deleteAllConversations()
                })
                actionsMenuItems.append(clearHistoryAction)
            }
        } else {
            if let index = actionsMenuItems.firstIndex(where: {$0.title == clearAllHistoryActionTitle}) {
                actionsMenuItems.remove(at: index)
            }
        }
        
        menuItems.remove(at: 1)
        menuItems.append(UIMenu(title: "", options: .displayInline, children: actionsMenuItems))
        self.smsMenu = UIMenu(title: "Phone Numbers", children: menuItems)
        self.settingsButton.menu = self.smsMenu
    }
    
    private func deleteAllConversations() {
        guard let ds = self.dataSource,
              ds.itemCnt > 0 else {
            return
        }
        
        DispatchQueue.global().async {
            let conversationsCount = ds.itemCnt
            var deleteAttemptsCount = 0
            var successfulDeleteCount = 0
            
            for i in 0..<conversationsCount {
                let indexPath = IndexPath(row: i, section: 0)
                if let conversation = ds.itemIdentifier(for: indexPath) {
                    let smsConversation = SMSChatConversationModel(conversation: conversation)
                    TwilioBackendManager.sharedMgr().deleteConversation(smsConversation: smsConversation, completion: { success in
                        deleteAttemptsCount += 1
                        if success {
                            successfulDeleteCount += 1
                            // Let's delete conversation from local DB as well
                            smsConversation.remove {}
                        }
                        
                        if deleteAttemptsCount == conversationsCount, successfulDeleteCount != conversationsCount {
                            DispatchQueue.main.async {
                                self.handleFailedDelete()
                            }
                        }
                    })
                }
            }
        }
    }
    
    func handleFailedDelete() {
        let alert = UIAlertController(title: "Delete Failed", message: "Could not delete conversation", preferredStyle: .alert)
        let cancelAction = UIAlertAction(title: "OK", style: .cancel, handler: nil)
        alert.addAction(cancelAction)
        self.present(alert, animated: true, completion: nil)
    }
}

extension UIFont {
    //This is used for making unread messages bold
    func withTraits(traits: UIFontDescriptor.SymbolicTraits...) -> UIFont {
        guard let descriptor = self.fontDescriptor.withSymbolicTraits(UIFontDescriptor.SymbolicTraits(traits)) else { return UIFont() }
        return UIFont(descriptor: descriptor, size: 0)
    }
    
    func bold() -> UIFont {
        return withTraits(traits: .traitBold)
    }
}

extension SMSViewController {
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

// MARK: - UITableViewDataSource
/// Subclass of UITableViewDiffableDataSource that supports row deletion
private class SMSConversationDataSource: UITableViewDiffableDataSource<Int, SMSChatConversation> {
    
    var accountId:String?
    var emptySet = false
    var itemCnt = 0
    
    override public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if accountId != nil {
            if section == 0 {
                if itemCnt == 0 && emptySet == false {
                    DispatchQueue.main.async {
                        self.emptySet = true
                        if let emptyView = tableView as? EmptyStateTableView {
                            let img = UIImage.init(named: "glacier", in: GlacierInfo.resourcesBundle, with: nil)
                            let title = "No Conversations"
                            let subtitle = "When you have conversations, you'll see them here."
                            emptyView.setState(.noData(image: img, title: title, message: subtitle))
                            emptyView.separatorStyle = .none
                        }
                    }
                } else if itemCnt != 0 && emptySet == true {
                    DispatchQueue.main.async {
                        self.emptySet = false
                        if let emptyView = tableView as? EmptyStateTableView {
                            emptyView.setState(.dataAvailable)
                            emptyView.separatorStyle = .none
                        }
                    }
                } else if emptySet == true, let emptyView = tableView as? EmptyStateTableView, let msg = emptyView.dataStateSubtitleLabel.text, msg.starts(with: "Use") {
                    DispatchQueue.main.async {
                        let img = UIImage.init(named: "glacier", in: GlacierInfo.resourcesBundle, with: nil)
                        let title = "No Conversations"
                        let subtitle = "When you have conversations, you'll see them here."
                        emptyView.setState(.noData(image: img, title: title, message: subtitle))
                    }
                }
            }
            
            return itemCnt
        } else {
            if itemCnt == 0 && emptySet == false {
                DispatchQueue.main.async {
                    self.emptySet = true
                    if let emptyView = tableView as? EmptyStateTableView {
                        let img = UIImage.init(named: "glacier", in: GlacierInfo.resourcesBundle, with: nil)
                        let title = "No Conversations"
                        let subtitle = "Use menu to add or select a phone number."
                        emptyView.setState(.noData(image: img, title: title, message: subtitle))
                        emptyView.separatorStyle = .none
                    }
                }
            }
        }
        return 0
    }
    
    override open func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    override open func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if (editingStyle == .delete) {
            if let conversation = self.itemIdentifier(for: indexPath) {
                let conv = SMSChatConversationModel(conversation: conversation)
                DispatchQueue.global().async {
                    TwilioBackendManager.sharedMgr().deleteConversation(smsConversation: conv, completion: {success in
                        if success == false {
                            DispatchQueue.main.async {
                                let vc = OTRAppDelegate.appDelegate.smsViewController
                                vc.handleFailedDelete()
                            }
                        }
                    })
                }
            }
        }
    }
}

extension UIImage {
    func scalePreservingAspectRatio(targetSize: CGSize) -> UIImage {
        // Determine the scale factor that preserves aspect ratio
        let widthRatio = targetSize.width / size.width
        let heightRatio = targetSize.height / size.height

        let scaleFactor = min(widthRatio, heightRatio)

        // Compute the new image size that preserves aspect ratio
        let scaledImageSize = CGSize(
            width: size.width * scaleFactor,
            height: size.height * scaleFactor
        )

        // Draw and return the resized UIImage
        let renderer = UIGraphicsImageRenderer(
            size: scaledImageSize
        )

        let scaledImage = renderer.image { _ in
            self.draw(in: CGRect(
                origin: .zero,
                size: scaledImageSize
            ))
        }

        return scaledImage
    }
}
