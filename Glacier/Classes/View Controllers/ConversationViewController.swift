//
//  ConversationViewController.swift
//  Glacier
//
//  Created by andyfriedman on 5/4/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import GRDB
import KVOController
import SAMKeychain
import XMPPFramework
import Kingfisher
import SwiftUI
//import Authenticator

@objc public protocol ConversationViewControllerDelegate {
    func didSelectThread(_ threadOwner:ChatThreadModel, conversationViewController: ConversationViewController)
    func didSelectCompose(_ conversationViewController: ConversationViewController)
}

@objc public class ConversationViewController: UIViewController, UITableViewDelegate, UIGestureRecognizerDelegate, UITabBarDelegate, LocationManagerDelegate {
    
    //let tableView = UITableView(frame: .zero, style: .plain)
    let tableView = EmptyStateTableView(frame: .zero, style: .plain)
    
    private var dataSource: ConversationDataSource!
    private var convCancellable: DatabaseCancellable?
    //var curSnapshot = NSDiffableDataSourceSnapshot<Int, ChatThread>()
    
    static let kOTRConversationCellHeight:CGFloat = 80.0
    
    var composeBarButtonItem:UIBarButtonItem?
    var connStatusLabel:UILabel?
    var connStatusView:UIView?
    var aloginHandler:OTRXMPPLoginHandler?

    var statusTapGestureRecognizer:UITapGestureRecognizer?
    var statusTimer:Timer?
    var statusCtr = 0
    var selectedRow = 0
    var accountType:String?
    var welcoming = false
    var waitingForMigration = false

    var currentacct:ChatAccountModel?

    // for single signon via AWS
    var amplifyAuth:UIHostingController<AuthView>?

    var retryCtr = 0
    var connectionSuccess = false
    var tryingGlacierAcct = false
    var currentmgr:XMPPManager?

    var hasPresentedOnboarding = false
    let navTitleView:TitleView //IOSM#60
    private var hasPresentedCompromiseAlert = false
    
    @objc public var delegate: ConversationViewControllerDelegate?
    var tabBar:GlacierTabs //IOSM#90
    
    override public init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        self.navTitleView = TitleView()
        self.tabBar = GlacierTabs()
        self.waitingForMigration = !DBStorageCoordinator.existsGlacierGRDB()
        KingfisherManager.shared.cache = GlacierImageCache.shared()
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc override open func viewDidLoad() {
        super.viewDidLoad()
       
        ///////////// Setup Navigation Bar //////////////
        let lblColor = UIColor.label
        
        if #available(iOS 18, *) {
            //leave title blank, will be back button
        } else {
            self.title = " "
        }
        let settingsIcon = UIImage(named: "OTRSettingsIcon-1", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        let settingsBarButtonItem = UIBarButtonItem(image:settingsIcon, style:UIBarButtonItem.Style.plain, target:self, action:nil)
        self.navigationItem.leftBarButtonItem = settingsBarButtonItem
        
        //IOSM#90 add menu for settings and profile
        var actions:[UIAction] = []
        let settingsImage = UIImage(systemName: "gearshape")
        let profileImage = UIImage(systemName: "person")
        actions.append(UIAction(title: "Profile", image: profileImage, handler: {(_) in
            self.goToProfile()
        }))
        actions.append(UIAction(title: "Settings", image: settingsImage, handler: {(_) in
            self.navigationController?.pushViewController(OTRAppDelegate.appDelegate.settingsViewController, animated: true)
        }))
        
        let settingsMenu = UIMenu(title:"", children:actions)
        settingsBarButtonItem.menu = settingsMenu
        
        let composeIcon = UIImage(named: "new_message", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        self.composeBarButtonItem = UIBarButtonItem(image: composeIcon, style: UIBarButtonItem.Style.plain, target: self, action: #selector(composeButtonPressed(_:)))
        self.composeBarButtonItem?.tintColor = lblColor
        self.navigationItem.rightBarButtonItems = [self.composeBarButtonItem!]
        
        //IOSM#60
        self.navigationItem.titleView = self.navTitleView
        self.navTitleView.titleLabel.text = "Chats"
        self.navTitleView.titleLabel.centerXAnchor.constraint(equalTo: self.navTitleView.centerXAnchor).isActive = true
        
        self.resetStatusTimer()
        //let redoIconChar: UniChar = 0xf01e
        //self.repeatStr = String(format: "%C", redoIconChar)
        
        self.statusTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleStatusGesture))
        self.statusTapGestureRecognizer?.numberOfTapsRequired = 1
        
        let appearance = UINavigationBarAppearance.init()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = GlobalTheme.shared.lightThemeColor
        appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor : lblColor]
        self.navigationController?.navigationBar.standardAppearance = appearance
        self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
        self.navigationController?.navigationBar.tintColor = lblColor
        
        self.navigationController?.isToolbarHidden = true
        self.connectionSuccess = false
        self.retryCtr = 0
        
        ////////// Create TableView /////////////////
        
        self.tableView.delegate = self
        self.tableView.register(OTRConversationCell.self, forCellReuseIdentifier: OTRConversationCell.reuseIdentifier())
        
        self.tableView.accessibilityIdentifier = "conversationTableView";
        self.tableView.translatesAutoresizingMaskIntoConstraints = false
        self.tableView.rowHeight = ConversationViewController.kOTRConversationCellHeight
        self.tableView.tableFooterView = UIView.init()
        self.tableView.separatorStyle = .none
        self.view.addSubview(self.tableView)
        
        self.tableView.register(OTRBuddyApprovalCell.self, forCellReuseIdentifier: OTRBuddyApprovalCell.reuseIdentifier())
        self.tableView.register(OTRBuddyInfoCell.self, forCellReuseIdentifier: OTRBuddyInfoCell.reuseIdentifier())
        
        self.navigationController?.view.addSubview(self.tabBar)
        self.tabBar.delegate = self
        self.tabBar.selectedItem = self.tabBar.chatsItem
        
        let tabBarHeight = self.tabBar.frame.height
        //let bottomSafeArea = self.view.safeAreaInsets.bottom
        self.tableView.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor).isActive = true
        self.tableView.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -tabBarHeight).isActive = true
        if let navwidth = self.navigationController?.view.frame.size.width {
            self.tableView.widthAnchor.constraint(equalToConstant: CGFloat(navwidth)).isActive = true
        }
        
        //self.tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: tabBarHeight, right: 0)
        //self.tableView.scrollIndicatorInsets = tableView.contentInset
        
        //[self.tableView reloadData];
        
        if let account = self.getFirstAccount() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.configureDataSource()
                self.observeConversations()
            }
            
            if let mgr = OTRProtocolManager.shared.xmppManager(forChatAccount: account) {
                currentmgr = mgr
                self.kvoController.observe(currentmgr, keyPath:"loginStatus", options: [.new, .old], action: #selector(connectionStateDidChange))
            }
            OTRAppDelegate.appDelegate.smsEnabled = account.smsEnabled
            self.tabBar.setSMSEnabled(account.smsEnabled)
        } else {
            DDLogWarn("Account isn't setup yet! Skipping KVO...")
        }
        
        self.setupLongAndTapPress()
        //self.view.addSubview(self.tabBar)
        
        AWSAcctManager.sharedMgr().addOrgDelegate(LocationManager.shared())
        LocationManager.shared().setLocationManagerDelegate(self)
        if self.getFirstAccount() != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                LocationManager.shared().uiReadyForLocation()
            }
        }
    }
    
    public func showDeniedAlert(_ alert: UIAlertController) {
        DispatchQueue.main.async {
            self.present(alert, animated: true)
        }
    }
    
    open override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    @objc func handleDatabaseInitialization() {
        self.waitingForMigration = false
        if currentmgr == nil, let account = self.getFirstAccount(), let mgr = OTRProtocolManager.shared.xmppManager(forChatAccount: account) {
            currentmgr = mgr
            self.kvoController.observe(currentmgr, keyPath:"loginStatus", options: [.new, .old], action: #selector(connectionStateDidChange))
            DispatchQueue.main.async {
                self.composeBarButtonItem?.isEnabled = ChatAccountModel.countXMPPAccounts() > 0
                self.convCancellable?.cancel()
                self.convCancellable = nil
                self.dataSource = nil
                self.configureDataSource()
                self.observeConversations()
            }
            OTRAppDelegate.appDelegate.smsEnabled = account.smsEnabled
            self.tabBar.setSMSEnabled(account.smsEnabled)
            
            //ready for LocationManager request
        }
        
        self.showOnboardingIfNeeded()
    }
    
    @objc func configureDataSource() {
        self.dataSource = ConversationDataSource(tableView: tableView, cellProvider: { (tableView, indexPath, chatThread) ->  UITableViewCell? in
            
            var bcell:OTRBuddyImageCell?
            if let cell = tableView.dequeueReusableCell(withIdentifier: OTRConversationCell.reuseIdentifier(), for: indexPath) as? OTRConversationCell {
                bcell = cell
                bcell?.selectionStyle = .default
                bcell?.avatarImageView.layer.cornerRadius = (ConversationViewController.kOTRConversationCellHeight-2.0*OTRBuddyImageCellPadding)/2.0
            }
            
            if chatThread.isGroupThread {
                if let roomthread = ChatRoom.roomFromThread(chatThread), let icell = bcell {
                    let roomModel = ChatRoomModel(room: roomthread)
                    icell.setRoomThread(roomModel)
                } else if let backuproom = ChatRoomModel.getXMPPRoom(uniqueId: chatThread.uniqueId), let icell = bcell {
                    icell.setRoomThread(backuproom)
                } else {
                    DispatchQueue.global().async {
                        chatThread.remove {}
                    }
                }
            } else {
                if let buddythread = ChatBuddy.buddyFromThread(chatThread), let icell = bcell {
                    let buddyModel = ChatBuddyModel(buddy: buddythread)
                    icell.setBuddyThread(buddyModel)
                } else if let backupbud = ChatBuddyModel.getBuddy(uniqueId: chatThread.uniqueId), let icell = bcell {
                    icell.setBuddyThread(backupbud)
                } else {
                    DispatchQueue.global().async {
                        chatThread.remove {}
                    }
                }
            }
            
            return bcell ?? UITableViewCell()
        })
        
        //self.dataSource.accountId = self.selectedAccount?.uniqueId
        self.dataSource.waitingForMigration = self.waitingForMigration
        self.tableView.dataSource = self.dataSource
    }
    
    @objc override open func viewWillAppear(_ animated:Bool) {
        super.viewWillAppear(animated)
        self.tabBar.selectedItem = self.tabBar.chatsItem
        self.tabBar.isHidden = false
        
        //[self.tableView reloadData];
        self.tableView.tableHeaderView = nil
        
        //IOSM#60
        self.resetStatusTimer()
        self.setConnectionStatus()
        
        self.smsNotified()
        
        NotificationCenter.default.addObserver(self, selector: #selector(enteringBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
        
        NotificationCenter.default.addObserver(self, selector: #selector(enteringForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
        
        NotificationCenter.default.addObserver(self, selector: #selector(smsNotified), name: NSNotification.Name(rawValue: SMSEnabledNotificationName), object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(connectionStateDidChange), name: NSNotification.Name(rawValue: NetworkStatusNotificationName), object: nil)
        
        //NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: NSNotification.Name(rawValue: ReloadDataNotificationName), object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleCompromisedStatus), name: SecurityCenter.didCheckCompromised, object: nil)
        
        
        self.addStatusGestures(false)
        if (self.accountType == nil) {
            let glacierDefaults = UserDefaults(suiteName: kGlacierGroup)
            self.accountType = glacierDefaults?.string(forKey: "connection")
        }
        
        self.composeBarButtonItem?.isEnabled = ChatAccountModel.countXMPPAccounts() > 0
    }

    @objc func enteringForeground(_ notification:NSNotification) {
        self.resetStatusTimer()
        self.tryingGlacierAcct = false
        self.setConnectionStatus()
        self.showOnboardingIfNeeded()
    }

    @objc func enteringBackground(_ notification:NSNotification) {
        self.statusTimer?.invalidate()
        self.statusTimer = nil
        self.statusCtr = 0
        self.setConnectionStatus()
        
        //IOSM#60
        self.navTitleView.titleConnectingView.stopAnimating()
        self.navTitleView.titleLabel.text = "Chats"
        self.removeLocalVPNFiles()
    }

    @objc override open func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated)
        self.showOnboardingIfNeeded()
    }

    @objc override open func viewWillDisappear(_ animated:Bool) {
        super.viewWillDisappear(animated)
        self.navTitleView.titleConnectingView.stopAnimating() //IOSM#60
        self.tableView.tableHeaderView = nil
        
        NotificationCenter.default.removeObserver(self)
        
        //if (_welcoming) {
        self.statusCtr = 0
        self.statusTimer?.invalidate()
        self.statusTimer = nil
        self.setConnectionStatus()
        self.welcoming = false
        //} //IOSM#60 and below
        self.navTitleView.titleLabel.text = "Chats"
        
        self.removeLocalVPNFiles()
    }
    
    func removeLocalVPNFiles() {
        //AWSAcctManager.sharedMgr().removeLocalVPNFiles()
    }
    
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    
    private func setupLongAndTapPress() {
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
                let menu = UIMenuController.shared
                let markAllRead = UIMenuItem(title: "Mark All Read", action: #selector(markAllRead))
                menu.menuItems = [markAllRead]
                
                let cell = self.tableView.cellForRow(at: indexPath)
                cell?.becomeFirstResponder()
                
                menu.update()
                menu.showMenu(from: self.tableView, rect: self.tableView.rectForRow(at: indexPath))
            }
        }
    }
    
    func getFirstAccount() -> ChatAccountModel? {
        if (currentacct != nil) {
            return currentacct
        }
        
        let accounts = ChatAccountModel.allXMPPAccounts()
        if accounts.count >= 1 {
            currentacct = accounts.first
        }
        
        return currentacct
    }
    
    func goToProfile() {
        guard let chatAccount = ChatAccountModel.currentAccount else { return }
        let profileView = UserProfileView(
            account: chatAccount,
            shouldShowReadReceiptsSetting: false,
            canEditDetails: true
        )
        let hostingVC = UIHostingController(rootView: profileView)
        hostingVC.modalPresentationStyle = .formSheet
        present(hostingVC, animated: true)
    }
    
    @objc open func composeButtonPressed(_ sender: AnyObject?) {
        self.delegate?.didSelectCompose(self)
    }
    
    //IOSM-570
    func doRetryLogin() {
        self.resetStatusTimer()
        self.addStatusGestures(false)
        self.retryLogin()
    }

    @objc func resetStatusTimer() {
        self.statusTimer?.invalidate()
        self.statusCtr = 0
        self.statusTimer = nil
        self.statusTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector:#selector(updateStatusTimer), userInfo:nil, repeats:true)
    }

    @objc func updateStatusTimer()
    {
        //DDLogWarn(@"*** statusCtr %d", _statusCtr);
        if (self.statusCtr < 22) {
            self.statusCtr+=1
        } else {
            self.statusTimer?.invalidate()
            self.statusTimer = nil
        }
        
        if (statusCtr % 2 == 0) {
            self.setConnectionStatus()
        }
    }
    
    func addStatusGestures(_ turnon:Bool) {
        if (turnon) {
            self.connStatusView?.addGestureRecognizer(self.statusTapGestureRecognizer!)
            self.connStatusView?.isUserInteractionEnabled = true
        } else {
            self.connStatusView?.removeGestureRecognizer(self.statusTapGestureRecognizer!)
            self.connStatusView?.isUserInteractionEnabled = false
        }
    }

    @objc func handleStatusGesture() {
        if let statusString = self.connStatusLabel?.text {
            if (statusString.hasSuffix("login") || statusString.hasSuffix("again")) {
                self.doRetryLogin()
            } else if statusString.hasPrefix("No account") {
                self.doLogout()
            }
        }
    }
    
    @objc func markAllRead() {
        OTRAppDelegate.appDelegate.markAllRead()
    }
    
    @objc func connectionStateDidChange() {
        self.setConnectionStatus()
    }
             
    func setConnectionStatus() {
        DispatchQueue.main.async {
            if let firstAcct = self.getFirstAccount() {
                if OTRProtocolManager.shared.existsProtocol(forAccountId: firstAcct.uniqueId) {
                    if OTRProtocolManager.shared.isAccountIdConnected(firstAcct.uniqueId) {
                        self.connStatusLabel?.text = ""
                        self.tableView.tableHeaderView = nil
                        self.navTitleView.titleLabel.text = "Chats"
                        self.navTitleView.titleConnectingView.stopAnimating()
                        self.statusCtr = 20
                        OTRAppDelegate.appDelegate.finishedConnecting()
                    }
                    else {
                        self.handleConnectingStatus(true, accountExists:true)
                    }
                } else {
                    // this occurs when in process of trying to create new account
                    // or first opening app with no VPN connectivity
                    self.handleConnectingStatus(false, accountExists:true)
                }
            } else {
                //DDLogWarn(@"*** no account yet with statusCtr %d", _statusCtr);
                self.handleConnectingStatus(false, accountExists:false)
            }
        }
    }
    
    func handleConnectingStatus(_ protocolExists:Bool, accountExists:Bool) {
        //DDLogWarn(@"*** handleConnectingStatus with statusCtr %d", _statusCtr);
        if self.statusTimer == nil { //IOSM#60
            return
        }
        
        if OTRAppDelegate.appDelegate.isProxyDetected() == true {
            self.navTitleView.titleLabel.text = "Proxy Detected"
            return
        }
        
        if self.statusCtr < 4 {
            self.connStatusLabel?.text = ""
            self.tableView.tableHeaderView = nil
        } else if self.statusCtr < 6 {
            self.navTitleView.titleLabel.text = "Chats"
            self.navTitleView.titleConnectingView.startAnimating() //IOSM#60
        } else {
            //DDLogWarn(@"*** handleConnectingStatus with _networkStatus connected and statusCtr %d", _statusCtr);
            if (protocolExists) { // network is up, but problems logging into xmpp server
                if self.statusCtr < 14 {
                    self.navTitleView.titleLabel.text = "Waiting for network" //Connecting...
                } else {
                    self.navTitleView.titleLabel.text = "Trying Again"
                    self.navTitleView.titleConnectingView.stopAnimating() //IOSM#60
                    self.doRetryLogin()
                }
                return
            } else  {
                self.tableView.tableHeaderView = self.connStatusView
                self.connStatusLabel?.center = self.connStatusView!.center
                if (accountExists) { // can happen during account initialization
                    if (self.statusCtr < 10) {
                        self.navTitleView.titleConnectingView.stopAnimating()
                        self.connStatusLabel?.text = "Initializing account"
                    } else {
                        self.connStatusLabel?.text = "Problems initializing"
                    }
                } else { // no account
                    if (self.statusCtr < 15) {
                        self.navTitleView.titleConnectingView.stopAnimating()
                        self.connStatusLabel?.text = "Initializing account"
                    } else {
                        self.connStatusLabel?.text = "No account"
                    }
                }
            }
        }
    }
    
    func doLogout() {
        AWSAcctManager.sharedMgr().teardownCognito()
        
        self.addStatusGestures(false)
        self.connectionSuccess = false
        self.retryCtr = 0
        
        // unregister push, doesn't affect Apple, but mod_push removes subscriptions
        if let curmgr = self.currentmgr, let acct = self.getFirstAccount(), let domain = acct.pushPubsubEndpoint, let serverJID = XMPPJID(user: nil, domain: domain, resource: nil) {
            curmgr.serverCheck.pushModule.disablePush(forServerJID: serverJID, node: acct.pushPubsubNode, elementId: nil)
        }
        
        let glacierDefaults = UserDefaults(suiteName: kGlacierGroup)
        glacierDefaults?.removePersistentDomain(forName: kGlacierGroup)
        
        self.statusCtr = 0
        self.statusTimer?.invalidate()
        self.statusTimer = nil
        
        if let account = self.getFirstAccount() {
            OTRProtocolManager.shared.setLoggingOut(true)
            OTRProtocolManager.shared.removeProtocol(forAccount: account)
            account.removeXMPPAccount()
            self.currentacct = nil
            
            WireGuardManager.shared().turnOffCore()
            DispatchQueue.main.async {
                OTRAppDelegate.appDelegate.bypassNetworkCheck(true)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
                OTRProtocolManager.shared.setLoggingOut(false)
            }
        }
        
        var error: NSError?
        if let idresult = SAMKeychain.password(forService: kGlacierGroup, account: kGlacierAcct, error: &error) {
            SAMKeychain.deletePassword(forService: kGlacierGroup, account: idresult, accessGroup: kGlacierGroup, error: &error)
            SAMKeychain.deletePassword(forService: kGlacierGroup, account: kGlacierAcct, accessGroup: kGlacierGroup, error: nil)
        }
        if let error = error {
            DDLogError("Error deleting password from keychain: \(error.localizedDescription) \(error.userInfo)")
        }
        
        error = nil
        if let idresult = SAMKeychain.password(forService: kGlacierGroup, account: kCognitoAcct, error: &error) {
            SAMKeychain.deletePassword(forService: kGlacierGroup, account: idresult, accessGroup: kGlacierGroup, error: &error)
            SAMKeychain.deletePassword(forService: kGlacierGroup, account: kCognitoAcct, accessGroup: kGlacierGroup, error: nil)
        }
        if let error = error {
            DDLogError("Error deleting Cognito password from keychain: \(error.localizedDescription) \(error.userInfo)")
        }
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            if let curmgr = self.currentmgr {
                self.kvoController.unobserve(curmgr)
                self.currentmgr?.clearMemory()
                self.currentmgr = nil
            }
            self.currentacct = nil
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                DBManager.deleteAll()
                DDLogWarn("*** Cleared DB")
                //[GlacierLog glogWithLogMsg:@"*** Cleared DB" detail:@"all"];
            }
        }
        
        self.hasPresentedOnboarding = false
        self.showOnboardingIfNeeded()
    }
    
    @objc func resetAfterLogout(_ account:ChatAccountModel?) {
        self.navigationController?.popToRootViewController(animated: false)
        let glacierDefaults = UserDefaults(suiteName: kGlacierGroup)
        glacierDefaults?.removePersistentDomain(forName: kGlacierGroup)
        
        var error: NSError?
        if let idresult = SAMKeychain.password(forService: kGlacierGroup, account: kCognitoAcct, accessGroup: kGlacierGroup, error: &error) {
            SAMKeychain.deletePassword(forService: kGlacierGroup, account: idresult, accessGroup: kGlacierGroup, error: &error)
            SAMKeychain.deletePassword(forService: kGlacierGroup, account: kCognitoAcct, accessGroup: kGlacierGroup, error: nil)
        }
        if let error = error {
            DDLogError("Error deleting Cognito password from keychain: \(error.localizedDescription) \(error.userInfo)")
        }
        
        AWSAcctManager.sharedMgr().teardownCognito()
        
        let swiftUIAuth = AuthView()
        amplifyAuth = UIHostingController(rootView: swiftUIAuth)
        self.present(amplifyAuth!, animated: true)
        
        self.addStatusGestures(false)
        self.connectionSuccess = false
        self.retryCtr = 0
        
        self.statusCtr = 0
        self.statusTimer?.invalidate()
        self.statusTimer = nil
        OTRAppDelegate.appDelegate.smsEnabled = false
        self.tabBar.setSMSEnabled(false)
        
        //IOSM-538
        //self.tableView.emptyDataSetSource = self.dataSource
        //self.tableView.emptyDataSetDelegate = self.dataSource
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let account = account {
                //[GlacierLog glogWithLogMsg:@"resetAfterLogout removing account" detail:account.uniqueId];
                OTRProtocolManager.shared.setLoggingOut(true)
            
                OTRProtocolManager.shared.removeProtocol(forAccount: account)
                account.removeXMPPAccount()
                
                WireGuardManager.shared().turnOffCore()
                DispatchQueue.main.async {
                    OTRAppDelegate.appDelegate.bypassNetworkCheck(true)
                }
                
                var error: NSError?
                if let idresult = SAMKeychain.password(forService: kGlacierGroup, account: kGlacierAcct, error: &error) {
                    SAMKeychain.deletePassword(forService: kGlacierGroup, account: idresult, accessGroup: kGlacierGroup, error: &error)
                    SAMKeychain.deletePassword(forService: kGlacierGroup, account: kGlacierAcct, accessGroup: kGlacierGroup, error: nil)
                }
                if let error = error {
                    DDLogError("Error deleting password from keychain: \(error.localizedDescription) \(error.userInfo)")
                }
                
                self.clearDBKeychain()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let curmgr = self.currentmgr {
                    self.kvoController.unobserve(curmgr)
                    self.currentmgr?.clearMemory()
                    self.currentmgr = nil
                }
                self.currentacct = nil
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                    //DBStorageCoordinator.removeAllFiles()
                    DBManager.sharedDB().resetDB()
                    DispatchQueue.main.async {
                        OTRAppDelegate.appDelegate.resetSMS()
                    }
                    //DBManager.deleteAll()
                    DDLogWarn("*** Cleared DB")
                    //[GlacierLog glogWithLogMsg:@"*** Cleared DB" detail:@"all"];
                }
            }
        }
        
        self.hasPresentedOnboarding = true
    }
    
    private func clearDBKeychain() {
        var error: NSError?
        if let idresult = SAMKeychain.password(forService: kOTRServiceName, account: GRDBDatabasePassphraseAccountName, accessGroup:kGlacierKeyGroup, error: &error) {
            SAMKeychain.deletePassword(forService: kOTRServiceName, account: GRDBDatabasePassphraseAccountName, accessGroup: kGlacierKeyGroup, error: nil)
        }
        if let error = error {
            DDLogError("Error deleting DB password from keychain: \(error.localizedDescription) \(error.userInfo)")
        }
        
        if let idresult = SAMKeychain.password(forService: kGlacierSalt, account: GRDBDatabasePassphraseAccountName, accessGroup:kGlacierKeyGroup, error: &error) {
            SAMKeychain.deletePassword(forService: kGlacierSalt, account: GRDBDatabasePassphraseAccountName, accessGroup:kGlacierKeyGroup, error: nil)
        }
        if let error = error {
            DDLogError("Error deleting DB salt from keychain: \(error.localizedDescription) \(error.userInfo)")
        }
        
        if let idresult = SAMKeychain.passwordData(forService: kGlacierMediaSalt, account: GRDBDatabasePassphraseAccountName, accessGroup:kGlacierKeyGroup, error: &error) {
            SAMKeychain.deletePassword(forService: kGlacierMediaSalt, account: GRDBDatabasePassphraseAccountName, accessGroup:kGlacierKeyGroup, error: nil)
        }
        if let error = error {
            DDLogError("Error deleting media salt from keychain: \(error.localizedDescription) \(error.userInfo)")
        }
        
        if let idresult = SAMKeychain.passwordData(forService: kGlacierKeySpec, account: GRDBDatabasePassphraseAccountName, accessGroup:kGlacierKeyGroup, error: &error) {
            SAMKeychain.deletePassword(forService: kGlacierKeySpec, account: GRDBDatabasePassphraseAccountName, accessGroup:kGlacierKeyGroup, error: nil)
        }
        if let error = error {
            DDLogError("Error deleting DB keyspec from keychain: \(error.localizedDescription) \(error.userInfo)")
        }
        
        if let idresult = SAMKeychain.password(forService: kGlacierMediaKeySpec, account: GRDBDatabasePassphraseAccountName, accessGroup:kGlacierKeyGroup, error: &error) {
            SAMKeychain.deletePassword(forService: kGlacierMediaKeySpec, account: GRDBDatabasePassphraseAccountName, accessGroup:kGlacierKeyGroup, error: nil)
        }
        if let error = error {
            DDLogError("Error deleting media keyspec from keychain: \(error.localizedDescription) \(error.userInfo)")
        }
    }
    
    @objc func lookForAccountInfoIfNeeded() {
        if self.getFirstAccount() == nil {
            self.navigationController?.popToRootViewController(animated: true)
            self.tryGlacierGroupAccount()
        }
    }
    
    func showOnboardingIfNeeded() {
        if (self.hasPresentedOnboarding || self.waitingForMigration) { return }
        var hasAccounts = false
        
        if ChatAccountModel.countXMPPAccounts() > 0 {
            hasAccounts = true
        }
        
        self.continueOnboarding(hasAccounts)
    }
    
    func continueOnboarding(_ hasAccounts:Bool) {
        //If there is any number of accounts launch into default conversation view otherwise onboarding time
        if (!hasAccounts) {
            if !(self.tryGlacierGroupAccount()) {
                self.setWelcomeController(false)
            }
        } else if PushController.getPushPreference() == .undefined {
            PushController.setPushPreference(.enabled)
            PushController.registerForPushNotifications()
        }
            
        self.hasPresentedOnboarding = true
    }
    
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if self.connStatusLabel != nil {
            self.setConnectionStatus()
            return
        }
        let txtColor = UIColor.label
        let bckColor = UIColor.systemGray3
        
        self.connStatusLabel = UILabel(frame: CGRectMake(5, 5, 100, 30))
        self.connStatusLabel?.font = UIFont(name: kFontAwesomeFont, size: 11.0)
        self.connStatusLabel?.text = "Connecting..."
        self.connStatusLabel?.textColor = txtColor
        self.connStatusLabel?.backgroundColor = bckColor
        self.connStatusLabel?.textAlignment = .center
        
        self.connStatusView = self.connStatusLabel
        self.setConnectionStatus()
    }
    
    @objc func tryGlacierGroupAccount() -> Bool {
        return self.tryGlacierGroupAccount(false)
    }
    

    // user account info can be shared among Glacier apps. Check for existing account info.
    func tryGlacierGroupAccount(_ altroute:Bool) -> Bool {
        if (self.tryingGlacierAcct) {
            return true // let the process finish
        }
        
        let glacierDefaults = UserDefaults(suiteName: kGlacierGroup)
        let uservalue = glacierDefaults?.string(forKey: "username")
        var passvalue = glacierDefaults?.string(forKey: "password")
        var displayvalue = glacierDefaults?.string(forKey: "displayname")
        
        var error: NSError?
        var deletionId:String?
        if let idvalue = SAMKeychain.password(forService: kGlacierGroup, account: kGlacierAcct, accessGroup:kGlacierGroup, error: &error) {
            passvalue = SAMKeychain.password(forService: kGlacierGroup, account: idvalue, accessGroup:kGlacierGroup, error: &error)
            deletionId = idvalue
        }
        if let error = error {
            DDLogError("Error retreiving password from keychain: \(error.localizedDescription) \(error.userInfo)")
            passvalue = glacierDefaults?.string(forKey: "password")
        }
        
        if  let uservalue = uservalue, let passvalue = passvalue {
            let account = ChatAccountModel(username: "")
            // load account from glacier storage
            let components = uservalue.components(separatedBy: "@")
            if (components.count != 2) {
                DispatchQueue.main.async {
                    self.badLoginAlert()
                }
                return false
            }
            
            account.grdbRecord?.username = uservalue
            if displayvalue == nil || displayvalue?.count == 0 {
                displayvalue = components.first
            }
            account.domain = components.last
            
            //IOSM#48
            if let org = glacierDefaults?.string(forKey: "orgid") {
                account.grdbRecord?.org = org
            }
            
            self.tryingGlacierAcct = true
            self.resetStatusTimer()
            
            self.setConnectionStatus()
            
            account.password = passvalue
            account.displayName = displayvalue!
            
            let includesDomain = components.count == 2
            
            if (account.password == nil) {
                DDLogError("Password nil, how is this possible?");
                //[GlacierLog glogWithLogMsg:@"Error logging in, Password in account is nil" detail:account.uniqueId];
            }
            DispatchQueue.main.async {
                OTRAppDelegate.appDelegate.setDomain(account.domain!)
                self.doLogin(account, includesDomain:includesDomain)
            }
            
            return true
        }
        return false
    }
    
    func doLogin(_ xaccount:ChatAccountModel, includesDomain:Bool) {
        if (self.aloginHandler == nil) {
            self.aloginHandler = OTRXMPPLoginHandler()
        }
        
        self.aloginHandler?.finishConnecting(withAccount: xaccount, completion: { (account:ChatAccountModel, error:Error?) in
            
            if let error = error as? NSError{
                // Unset/remove password from keychain if account
                // is unsaved / doesn't already exist. This prevents the case
                // where there is a login attempt, but it fails and
                // the account is never saved. If the account is never
                // saved, it's impossible to delete the orphaned password
                
                let pass = account.password
                if let existingAccount = ChatAccountModel.getXMPPAccount(uniqueId: account.uniqueId) {
                    do {
                        try account.removeKeychainPassword(nil)
                    } catch {
                        DDLogDebug("doLogin, removeKeychainPassword with error: \(error)")
                    }
                    //[GlacierLog glogWithLogMsg:@"doLogin, Removed password" detail:account.uniqueId];
                
                    OTRProtocolManager.shared.removeProtocol(forAccount: account)
                    if let logHandle = self.aloginHandler {
                        NotificationCenter.default.removeObserver(logHandle)
                    }
                    self.aloginHandler = nil
                }
                
                let certAlert = UIAlertController.certificateWarningAlert(error: error, saveHandler: { (action:UIAlertAction) in
                    if let certData = error.userInfo[OTRXMPPSSLCertificateDataKey] as? Data, let hostname = error.userInfo[OTRXMPPSSLHostnameKey] as? String {
                        OTRCertificatePinning.addCertificateData(certData, withHostName: hostname)
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        self.tryingGlacierAcct = false
                        xaccount.password = pass
                        self.doLogin(xaccount, includesDomain:includesDomain)
                    }
                })
                
                // try login once more if failed the first time
                if self.retryCtr == 1 {
                    self.doLoginAlert()
                }
                self.retryCtr+=1
                    
                if (certAlert != nil) {
                    if let certData = error.userInfo[OTRXMPPSSLCertificateDataKey], let hostname = error.userInfo[OTRXMPPSSLHostnameKey] as? String {
                        OTRCertificatePinning.add(certData as! SecCertificate, withHostName: hostname)
                    }
                }
                    
                self.statusTimer?.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    self.tryingGlacierAcct = false
                    xaccount.password = pass
                    self.doLogin(xaccount, includesDomain:includesDomain)
                }
                
            } else if (!self.connectionSuccess) {
                self.connectionSuccess = true
                
                OTRAppDelegate.appDelegate.resetDoubleNotificationHandlerIfNeeded()
                xaccount.loginDate = Date()
                xaccount.grdbRecord?.lastHistoryFetchDate = Date()
                
                if let orgdata = AWSAcctManager.sharedMgr().getGlacierEnablements() {
                    xaccount.trackingEnabled = orgdata.trackingEnabled
                    xaccount.forceTracking = orgdata.forceTracking
                    xaccount.trackingInterval = orgdata.trackingInterval
                    xaccount.grdbRecord?.apiKey = orgdata.apikey
                }
                
                xaccount.saveXMPPAccount()
                self.currentmgr = OTRProtocolManager.shared.xmppManager(forChatAccount:account)
                
                if let curmgr = self.currentmgr {
                    self.kvoController.observe(curmgr, keyPath:"loginStatus", options: [.new, .old], action: #selector(self.connectionStateDidChange))
                    DispatchQueue.main.async {
                        self.composeBarButtonItem?.isEnabled = true
                    }
                }
                
                self.doSecurityCheck(false) //IOSM#48
                //OTRAppDelegate.appDelegate.smsViewController.doSMSCheck()
                TwilioBackendManager.sharedMgr().queryForNumbers()
                
                self.convCancellable?.cancel()
                self.convCancellable = nil
                self.dataSource = nil
                self.configureDataSource()
                self.observeConversations()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if let curmgr = self.currentmgr {
                        PushController.setPushPreference(.enabled)
                        PushController.registerForPushNotifications()
                        curmgr.serverCheck.refresh()
                        curmgr.serverCheck.pushModule.refresh()
                    }
                    
                    self.requestCallPermissions() //IOSM-464
                    LocationManager.shared().uiReadyForLocation()
                    
                    OTRProtocolManager.shared.setLoggingOut(false)
                }
                self.tryingGlacierAcct = false
            } else {
                self.tryingGlacierAcct = false
            }
        })
    }
    
    //IOSM#19
    @objc func doSecurityCheck(_ refresh:Bool) {
        if self.getFirstAccount() != nil {
            
            OTRAppDelegate.appDelegate.doSettingsController()
            //if not on login screen. Determine if authView is around
            OTRAppDelegate.appDelegate.settingsViewController.checkSecurity()
            /*if !refresh && OTRAppDelegate.appDelegate.settingsViewController.needsSecurityAlert() {
                UIApplication.shared.showLocalNotificationWith(identifier: nil, body: "Warning: Your device may be compromised", badge: 0, userInfo: nil, recurring: false)
            }
                
            //IOSM#99
            let securityAwareness = OTRAppDelegate.appDelegate.settingsViewController.needsSecurityAwareness()
            self.tabBar.setSecurityAlert(securityAwareness)*/
        }
    }
    
    @objc func handleCompromisedStatus(_ notification: NSNotification) {
        let compromised = notification.userInfo?["compromised"] as? Bool ?? false
        let detail = notification.userInfo?["detail"] as? String ?? "none"
        let proxyDetected = detail == "proxied"
        
        if !proxyDetected {
            self.hasPresentedCompromiseAlert = false
        }
        if compromised, OTRAppDelegate.appDelegate.settingsViewController.needsSecurityAlert() {
            let warningMessage = proxyDetected ? "Device Proxy Detected" : "Warning: Your device may be compromised"
            let isActive = UIApplication.shared.applicationState == .active
            let shouldShowAlert = proxyDetected && isActive && !self.hasPresentedCompromiseAlert

            if shouldShowAlert {
                let okAction = UIAlertAction(title: "OK", style: .default)
                let alert = UIAlertController(title: "Security Warning", message: warningMessage, preferredStyle: .alert)
                alert.addAction(okAction)
                self.present(alert, animated: true)
                self.hasPresentedCompromiseAlert = true
            } else {
                UIApplication.shared.showLocalNotificationWith(identifier: nil, body: warningMessage, badge: 0, userInfo: nil, recurring: false)
            }
        }
            
        //IOSM#99
        let securityAwareness = OTRAppDelegate.appDelegate.settingsViewController.needsSecurityAwareness()
        self.tabBar.setSecurityAlert(securityAwareness)
    }

    func requestCallPermissions() {
        if AVAudioSession.sharedInstance().recordPermission != .granted {
            AVAudioSession.sharedInstance().requestRecordPermission( {(granted:Bool) in
                //
            })
        }
                                                 
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { (granted:Bool) in
                //
            })
        }
    }

    func badLoginAlert() {
        let okButtonItem = UIAlertAction(title: "OK", style: .cancel, handler: {(action: UIAlertAction!) in
            self.doLogout()
        })
        //If repeated issues, likely account setup problem or no path to network
        let alert = UIAlertController(title: "Warning", message: "Problems logging in. Your account appears to be an invalid format. Please contact your Glacier account representative.", preferredStyle: .alert)
        alert.addAction(okButtonItem)
        self.present(alert, animated: true, completion: nil)
    }
    
    func retryLogin() {
        let currentStatus = OTRNetworkConnectionStatus.connected
        let userInfo = [NewNetworkStatusKey: currentStatus]
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: NetworkStatusNotificationName), object: self, userInfo: userInfo)
        }
    }
    
    func doLoginAlert() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            if (!self.connectionSuccess) {
                let cancelButtonItem = UIAlertAction(title: CANCEL_STRING(), style: .cancel, handler: nil)
                let okButtonItem = UIAlertAction(title: "Yes", style: .default, handler: {(action: UIAlertAction!) in
                    self.doLogout()
                })
                
                //If repeated issues, likely account setup problem or no path to network
                let alert = UIAlertController(title: "Warning", message: "Problems logging in. Do you want to reset and try again? For assistance contact your Glacier account representative.", preferredStyle: .alert)
                alert.addAction(cancelButtonItem)
                alert.addAction(okButtonItem)
                self.present(alert, animated: true, completion: nil)
            }
        }
    }

    @objc func setWelcomeController(_ closeable:Bool) {
        self.welcoming = true
        let acct = self.getFirstAccount()?.bareJID?.user
        
        //try opening the SwiftUI Authenticator
        let openAuth = {
            var authView:AuthView?
            if let acctname = acct {
                authView = AuthView(acctname)
            } else {
                authView = AuthView()
            }
            guard let swiftUIAuth = authView else { return } // swiftUIView is View
            self.amplifyAuth = UIHostingController(rootView: swiftUIAuth)
            self.present(self.amplifyAuth!, animated: true)
        }
        
        if closeable == true {
            DispatchQueue.main.async {
                openAuth()
                let alert = UIAlertController(title: "Some services unavailable", message: "You may need to re-open Glacier or sign in again to access updated VPN profiles and some Security Hub data. This does not affect normal messaging.\n\nSwipe down to skip for now and sign in later.", preferredStyle: .alert)
                let okButtonItem = UIAlertAction(title: "OK", style: .default, handler: nil)
                alert.addAction(okButtonItem)
                self.amplifyAuth?.present(alert, animated: true, completion: nil)
            }
        } else {
            openAuth()
        }
    }
    
    public func endAuthLogin() {
        self.welcoming = false//?
        amplifyAuth?.dismiss(animated: true)
        self.lookForAccountInfoIfNeeded()
    }
    
    //IOSM#90
    public func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        self.navigationController?.popToRootViewController(animated: false)
        if let appDelegate = Application.shared.delegate as? OTRAppDelegate {
            switch (item.tag) {
            case GlacierTabs.Screen.sms.rawValue:
                appDelegate.window?.rootViewController = appDelegate.smsSplitViewCoordinator.splitViewController
                break
            case GlacierTabs.Screen.dial.rawValue:
                //appDelegate.goGlacierVoice()
                appDelegate.window?.rootViewController = appDelegate.dialerViewController
                break
            case GlacierTabs.Screen.security.rawValue:
                appDelegate.window?.rootViewController = appDelegate.securityHubViewController
                break
            case GlacierTabs.Screen.settings.rawValue:
                //appDelegate.window?.rootViewController = appDelegate.settingsViewController
                self.navigationController?.pushViewController(appDelegate.settingsViewController, animated: true)
                break
            default:
                break
            }
        }
    }

    @objc func smsNotified() {
        //NSLog("***** smsNotified")
        self.tabBar.setSMSEnabled(OTRAppDelegate.appDelegate.smsEnabled)
        self.tabBar.selectedItem = self.tabBar.chatsItem
    }
    
    func connectVideoCall(_ call:TwilioCall) {
        guard let account = self.getFirstAccount() else { return }
        
        // need to keep separate accounts for receiver at least if outgoing
        //if its a group it should probably be handled by the group, not individually?
        //if call currently connected and open don't need to do anything here
        var calltitle = call.calltitle
        var buddy:ChatBuddyModel?
        if calltitle == nil {
            var jid = XMPPJID(string: call.caller!)
            if (call.outgoing) {
                //NSArray *receivers = [call.receiver componentsSeparatedByString:@","];
                jid = XMPPJID(string: call.receiver!)
            }
            buddy = ChatBuddyModel.fetchBuddyModel(jid: jid!, accountUniqueId: account.uniqueId)
            if (buddy != nil) {
                calltitle = buddy?.displayName
            }
        }
        
        guard let calltitle = calltitle else { return }
        
        //IOSM-503 concatenate names if needed
        let appDelegate = UIApplication.shared.delegate as? OTRAppDelegate
        appDelegate?.openVideoCallController(calltitle)
        if let callVC = appDelegate?.callWindow?.rootViewController?.presentedViewController as? VideoCallViewController {
            callVC.doConnectCall(call, with:calltitle)
        } /*else {
            appDelegate?.openVideoCallController(calltitle)
        }*/
        
        if let csysMessage = call.systemMessage {
            DispatchQueue.global().async {
                //IOSM-503
                var thread:ChatThreadModel?
                var message:MessageProtocol?
                
                if let buddy = buddy {
                    thread = ChatThreadModel.getChatThread(uniqueId: buddy.uniqueId)
                    message = buddy.outgoingMessage(text: csysMessage)
                } else {
                    let after = "conference.\(account.domain!)"
                    //let groupname = calltitle.suffix(calltitle.count-1)
                    let groupjid = "\(calltitle)@\(after)"
                    let databaseRoomKey = ChatRoomModel.createUniqueId(account.uniqueId, jid: groupjid)
                    if let room = ChatRoomModel.getXMPPRoom(uniqueId: databaseRoomKey) {
                        thread = ChatThreadModel.getChatThread(uniqueId: room.uniqueId)
                        message = room.outgoingMessage(text: csysMessage)
                    }
                }
                 
                if let thread = thread, let message = message {
                    message.messageSecurity = .plaintext
                    
                    if let systemMsg = message as? OutgoingChatMessage {
                        systemMsg.grdbRecord?.systemUpdate = true
                        systemMsg.grdbRecord?.dateSent = Date()
                        systemMsg.grdbRecord?.readDate = Date()
                        systemMsg.grdbRecord?.originalText = csysMessage
                        systemMsg.save(withThread: thread)
                    } else if let systemMsg = message as? ChatRoomMessageModel {
                        systemMsg.grdbRecord?.state = ChatRoomMessageState.sent.rawValue
                        systemMsg.grdbRecord?.systemUpdate = true
                        systemMsg.grdbRecord?.originalText = csysMessage
                        systemMsg.save(withThread: thread)
                    }
                    //thread.saveThread()
                }
            }
        }
    }

    func addSystemMessage(_ message:String, with callerJid:String, with username:String) {
        
        let str = "\(message) from \(username)"
        if message.starts(with: ChatRoomMessage.StringConstants.incomingCall.text) == false {
            UIApplication.shared.showLocalNotificationWith(identifier: nil, body: str, badge: 0, userInfo: nil, recurring: false)
        }
        
        DispatchQueue.global().async {
            guard let account = self.getFirstAccount(), let jid = XMPPJID(string: callerJid), let buddy = ChatBuddyModel.fetchBuddyModel(jid: jid, accountUniqueId: account.uniqueId), let cthread = ChatThreadModel.getChatThread(uniqueId: buddy.uniqueId), let systemMsg = buddy.outgoingMessage(text: message) as? OutgoingChatMessage else { return }
            
            //let systemMsg = buddy.outgoingMessage(text: message) as? OutgoingChatMessage
            systemMsg.messageSecurity = .plaintext
            systemMsg.grdbRecord?.systemUpdate = true
            systemMsg.grdbRecord?.dateSent = Date()
            systemMsg.grdbRecord?.readDate = Date()
            systemMsg.grdbRecord?.originalText = message
            cthread.lastMessageIdentifier = systemMsg.messageKey
            cthread.grdbRecord?.modified = Date()
            systemMsg.save(withThread: cthread)
            //buddy.saveThread()
            //ChatThread.touch(uniqueId: buddy.uniqueId)
        }
    }

    func addSystemGroupMessage(_ messagetext:String, with groupTitle:String) {
        guard let xacct = self.getFirstAccount() else { return }
        
        let str = "\(messagetext) from \(groupTitle)"
        UIApplication.shared.showLocalNotificationWith(identifier: nil, body: str, badge: 0, userInfo: nil, recurring: false)

        let after = "conference.\(xacct.domain!)"
        let groupjid = "\(groupTitle)@\(after)"
        let databaseRoomKey = ChatRoomModel.createUniqueId(xacct.uniqueId, jid: groupjid)
        if let room = ChatRoomModel.getXMPPRoom(uniqueId: databaseRoomKey), let systemMsg = room.outgoingMessage(text: messagetext) as? ChatRoomMessageModel, let cthread = ChatThreadModel.getChatThread(uniqueId: databaseRoomKey) {
            //let systemMsg = room.outgoingMessage(text: messagetext) as? ChatRoomMessageModel
            systemMsg.messageSecurity = .plaintext
            cthread.lastMessageIdentifier = systemMsg.messageKey
            cthread.grdbRecord?.modified = Date()
                    
            systemMsg.grdbRecord?.state = ChatRoomMessageState.sent.rawValue
            systemMsg.grdbRecord?.systemUpdate = true
            systemMsg.grdbRecord?.originalText = messagetext
            systemMsg.save(withThread: cthread)
            //room.saveThread()
        }
    }
    
    func threadFor(indexPath:IndexPath) -> ChatThreadModel? {
        var threadModel:ChatThreadModel?
        if let thread = self.dataSource.itemIdentifier(for: indexPath) {
            threadModel = ChatThreadModel(thread: thread)
        }
        return threadModel
    }
    
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return ConversationViewController.kOTRConversationCellHeight
    }
    
    public func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return ConversationViewController.kOTRConversationCellHeight
    }
    
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if let thread = self.threadFor(indexPath: indexPath) {
            // Bail out if it's a subscription request
            //if let bthread = thread as? ChatBuddyModel, bthread.askingForApproval {
            //    return
            //}
            
            //if let cell = self.tableView.cellForRow(at: indexPath) as? OTRConversationCell {
            //    cell.markRead()
            //}
            
            self.delegate?.didSelectThread(thread, conversationViewController: self)
            if ChatViewController.IS_IPHONE {
                tableView.deselectRow(at: indexPath, animated: false)
            } else {
                self.selectedRow = indexPath.row
            }
            
        }
    }
    
    public func tableView(_ tableView: UITableView, shouldShowMenuForRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    public func tableView(_ tableView: UITableView, canPerformAction action: Selector, forRowAt indexPath: IndexPath, withSender sender: Any?) -> Bool {
        return action == #selector(markAllRead)
    }

    public func tableView(_ tableView: UITableView, performAction action: Selector, forRowAt indexPath: IndexPath, withSender sender: Any?) {
        //required
    }
    
    public func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        if let thread = self.threadFor(indexPath: indexPath) {
            return UITableView.editActions(forThread: thread)
        }
        return nil
    }
    
    private func updateDataSource(from conversations: [ChatThread]) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, ChatThread>()
        snapshot.appendSections([0])
        snapshot.appendItems(conversations, toSection: 0)
        snapshot.reloadItems(conversations)
            
        if let ds = self.dataSource {
            //if numrows == 0, conversations.count > 0 {
            //    ds.applySnapshotUsingReloadData(snapshot, completion: nil)
            //} else {
            ds.itemCnt = snapshot.numberOfItems
            ds.apply(snapshot, animatingDifferences: false, completion: {
                if ChatViewController.IS_IPHONE == false {
                    // Restore selection
                    self.tableView.selectRow(at: IndexPath(row: self.selectedRow, section: 0), animated: false, scrollPosition: .none)
                }
            })
            
        }
    }
    
    private func observeConversations() {
        let request: QueryInterfaceRequest<ChatThread>
        request = ChatThread.all().order(Column("messageDate").desc)
        
        convCancellable = ValueObservation
            .tracking(request.fetchAll(_:))
            .start(
                in: DBManager.sharedDB().grdbStorage.pool,
                // Immediate scheduling feeds the data source right on subscription,
                // and avoids an undesired animation when the application starts.
                scheduling: .immediate,
                onError: { error in fatalError("Unexpected error: \(error)") },
                onChange: { [weak self] conversations in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        self.updateDataSource(from: conversations)
                    }
                })
        
        //if there are conversations, select 1st
        if ChatViewController.IS_IPHONE == false {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if self.dataSource.itemCnt > 0 {
                    let ip = IndexPath(row: self.selectedRow, section: 0)
                    self.tableView(self.tableView, didSelectRowAt: ip)
                }
            }
        }
    }
}

// MARK: - UITableViewDataSource
/// Subclass of UITableViewDiffableDataSource that supports row deletion
class ConversationDataSource: UITableViewDiffableDataSource<Int, ChatThread> {
    
    //var accountId:String?
    var waitingForMigration = false
    var emptySet = false
    var itemCnt = 0
    
    override public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        //if let acctid = accountId {
        //let numRows = self.curSnapshot.numberOfItems //  ChatThread.countConversations()
            if section == 0 {
                if itemCnt == 0 && emptySet == false {//!waitingForMigration && emptySet == false {
                    DispatchQueue.main.async {
                        //tableView.emptyDataSetSource = self
                        //tableView.emptyDataSetDelegate = self
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
                        //tableView.emptyDataSetSource = nil
                        //tableView.emptyDataSetDelegate = nil
                        self.emptySet = false
                        if let emptyView = tableView as? EmptyStateTableView {
                            emptyView.setState(.dataAvailable)
                            emptyView.separatorStyle = .none //.singleLine
                        }
                    }
                }
            }
            
            return itemCnt
        //}
        //return 0
    }
    
    override public func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    /*override open func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }*/
    
    /// Asks the data source for the title of the dataset.
    /// The dataset uses a fixed font style by default, if no attributes are set. If you want a different font style, return a attributed string.
    /*public func title(forEmptyDataSet scrollView: UIScrollView) -> NSAttributedString? {
        let text = "No Conversations"
        
        let attributes = [NSAttributedString.Key.font: UIFont.boldSystemFont(ofSize: 18.0), NSAttributedString.Key.foregroundColor: UIColor.darkGray]
        
        return NSAttributedString(string: text, attributes: attributes)
    }
    
    /// Asks the data source for the description of the dataset.
    /// The dataset uses a fixed font style by default, if no attributes are set. If you want a different font style, return a attributed string.
    public func description(forEmptyDataSet scrollView: UIScrollView) -> NSAttributedString? {
        let text = "When you have conversations, you'll see them here."
        
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = NSLineBreakMode.byWordWrapping
        paragraph.alignment = NSTextAlignment.center
        
        let attributes = [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14.0),
                          NSAttributedString.Key.foregroundColor: UIColor.lightGray,
                          NSAttributedString.Key.paragraphStyle: paragraph]
        
        return NSAttributedString(string: text, attributes: attributes)
    }
    
    /// Asks the data source for the image of the dataset.
    public func image(forEmptyDataSet scrollView: UIScrollView) -> UIImage? {
        return UIImage.init(named: "glacier", in: GlacierInfo.resourcesBundle, with: nil)
    }*/
}
