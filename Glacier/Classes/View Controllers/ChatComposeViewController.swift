//
//  ChatComposeViewController.swift
//  Glacier
//
//  Created by andyfriedman on 12/14/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import UIKit
import PureLayout
import MBProgressHUD

@objc public protocol ChatComposeViewControllerDelegate {
    /**
     This method is called when the view controller 'done' button is pressed or a single buddy is selected. Sends all the selected buddies the accountId to use and an optional name for groups.
     */
    @objc func controller(_ viewController: ChatComposeViewController, didSelectBuddies buddies:[String], accountId:String?, name:String?) -> Void
    
    func enterConversation(withName name:String, isPublic:Bool)
    
    /**
     This method is called when the view controller's cacnel button is pressed and should be dismissed and no action taken.
     */
    func controllerDidCancel(_ viewController: ChatComposeViewController) -> Void
}

@objc open class ChatComposeViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, UISearchResultsUpdating, UISearchControllerDelegate, UISearchBarDelegate, OTRComposeGroupViewControllerDelegate, OTRJoinGroupViewControllerDelegate
{
    @objc public weak var delegate:ChatComposeViewControllerDelegate? = nil
    
    var tableView:UITableView
    let tableViewHeader = OTRVerticalStackView.init()
    var tableViewBottomConstraint:NSLayoutConstraint?
    var searchController:ComposeSearchController?
    var selectedBuddiesIdSet = Set<String>()
    
    var myBuddies:[ChatBuddy] = []
    var filteredBuddies:[ChatBuddy] = []
    var doneBarButtonItem:UIBarButtonItem
    var groupBarButtonItem:UIBarButtonItem
    
    var selectionModeIsSingle = true
    
    /*override public init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }*/
    
    public init() {
        self.tableView = UITableView(frame: CGRect.zero, style: .plain)
        let checkImage = UIImage(named: "ic-check", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        self.doneBarButtonItem = UIBarButtonItem(image: checkImage, style: .plain, target: nil, action: #selector(doneButtonPressed(_:)))
        self.groupBarButtonItem = UIBarButtonItem(title: GROUP_CHAT_STRING(), style: .plain, target: nil, action: #selector(groupButtonPressed(_:)))
        super.init(nibName: nil, bundle: nil)
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        let backColor = UIKit.UIColor.systemBackground
        let lblColor = UIKit.UIColor.label
        self.view.backgroundColor = backColor
        
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = GlobalTheme.shared.lightThemeColor;
        appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIKit.UIColor.label]
        self.navigationController?.navigationBar.tintColor = UIKit.UIColor.label
        self.navigationController?.navigationBar.standardAppearance = appearance
        self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
        
        let cancelBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelButtonPressed(_:)))
        cancelBarButtonItem.tintColor = lblColor
        self.navigationItem.leftBarButtonItem = cancelBarButtonItem
        
        self.title = COMPOSE_STRING()
        self.navigationItem.leftBarButtonItem = cancelBarButtonItem
        self.navigationItem.rightBarButtonItem = self.groupBarButtonItem
        self.navigationItem.title = "New Chat" //IOSM#55 and commented above
        
        self.doneBarButtonItem.target = self
        self.groupBarButtonItem.target = self
        
        /////////// TableView ///////////
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.tableView.translatesAutoresizingMaskIntoConstraints = false
        self.tableView.contentInsetAdjustmentBehavior = .never
        self.tableView.rowHeight = OTRBuddyInfoCellHeight
        self.view.addSubview(self.tableView)

        self.tableViewHeader.backgroundColor = UIColor.systemGroupedBackground
        self.tableView.tableHeaderView = self.tableViewHeader
        
        self.tableView.register(OTRBuddyInfoCell.self, forCellReuseIdentifier: OTRBuddyInfoCell.reuseIdentifier())
        //self.tableView.autoPinEdgesToSuperviewEdges()
        self.tableView.autoPinEdgesToSuperviewEdges(with: .zero, excludingEdge: .top)
        self.tableView.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor).isActive = true
        //if let searchY = self.navigationController?.navigationBar.frame.height {
            //self.tableView.topAnchor.constraint(equalToConstant: searchY).isActive = true
        //}

        self.setupSearchController()
        self.extendedLayoutIncludesOpaqueBars = true
        
        // Add the "Join Group" button
        let cellJoinGroup = UITableViewCell(style: .default, reuseIdentifier: nil)
        cellJoinGroup.textLabel?.text = JOIN_GROUP_STRING()
        cellJoinGroup.accessoryType = .disclosureIndicator
        self.tableViewHeader.addStackedSubview(cellJoinGroup, identifier: JOIN_GROUP_STRING(), gravity: OTRVerticalStackView.Gravity.bottom, height: 80, callback: { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.joinGroup(cellJoinGroup)
        })
        
        let accounts = ChatAccountModel.allXMPPAccounts()
        guard accounts.count > 0, let xacct = accounts.first, let acctgrec = xacct.grdbRecord else {return}
        
        //getBuddiesAsync and then update screen?
        ChatBuddy.getAllBuddies(for: acctgrec, completion: { [weak self] (buddies) in
            self?.myBuddies = buddies
            self?.filteredBuddies = buddies
            self?.tableView.reloadData()
            self?.queryMissingKeys()
        })
    }
    
    //IOSM-519 query missing keys
    func queryMissingKeys() {
        let accounts = ChatAccountModel.allXMPPAccounts()
        if accounts.count == 0 {return}
        
        var budjids:[XMPPJID] = []
        let hud = MBProgressHUD.showAdded(to: self.view, animated: true)
        hud.label.text = "Fetching secure keys"
        
        //NSInteger num = self.myBuddies.count;
        for bud in self.myBuddies {
            if ChatOmemoDevice.countOMEMODevices(for: bud.uniqueId) == 0 {
                let buddy = ChatBuddyModel(buddy: bud)
                if let jid = buddy.bareJID {
                    budjids.append(jid)
                }
            }
        }
        
        if budjids.count == 0 {
            hud.removeFromSuperview()
            return
        }
        
        if let xacct = accounts.first, let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: xacct) {
            for budjid in budjids {
                xmpp.omemoSignalCoordinator?.omemoModule?.fetchDeviceIds(for: budjid, elementId: nil)
            }
        }
        
        //remove indeterminate progress after a few seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            hud.removeFromSuperview()
            self.tableView.reloadData()
        }
    }
    
    override open func viewWillAppear(_ animated:Bool) {
        NotificationCenter.default.addObserver(self,
                selector: #selector(keyboardWillShow(_:)),
                name: UIResponder.keyboardWillShowNotification,
                object: nil)
        NotificationCenter.default.addObserver(self,
                selector: #selector(keyboardWillHide(_:)),
                name: UIResponder.keyboardWillHideNotification,
                object: nil)

        super.viewWillAppear(true)
    }

    override open func viewDidAppear(_ animated:Bool) {
        self.adjustSearchBarSize()
        super.viewDidAppear(true)
    }

    override public func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        // Resize UISearchBar manually - it doesn't do it on its own on device turn.
        let rotationHandler: ((UIViewControllerTransitionCoordinatorContext) -> Void) = { _ in
            self.adjustSearchBarSize()
        }
        coordinator.animate(alongsideTransition: rotationHandler, completion: rotationHandler)
        super.viewWillTransition(to: size, with: coordinator)
    }

    override open func viewWillDisappear(_ animated:Bool) {
        NotificationCenter.default.removeObserver(self)
        super.viewWillDisappear(true)
    }
    
    public func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if self.isSearchResultsControllerTableView(tableView) {
            return self.filteredBuddies.count
        }
        return self.myBuddies.count
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if let cell = tableView.dequeueReusableCell(withIdentifier: OTRBuddyInfoCell.reuseIdentifier(), for: indexPath) as? OTRBuddyInfoCell,
            let buddy = self.threadOwnerAt(indexPath: indexPath, tableView: tableView) {
            
            //IOSM-519 gray and not selectable if no bundle/keys
            let deviceCount = ChatOmemoDevice.countOMEMODevices(for: buddy.uniqueId)
            let buddyModel = ChatBuddyModel(buddy: buddy)
            cell.setBuddyThread(buddyModel, account: nil)
            
            //IOSM-519
            if (deviceCount == 0) {
                cell.isUserInteractionEnabled = false //not selectable, gray
                cell.accountLabel.text = "No secure keys available"
                cell.accountLabel.textColor = UIColor.gray
                cell.nameLabel.textColor = UIColor.gray
            } else { //IOSM-537
                cell.isUserInteractionEnabled = true
            }
            
            if self.selectedBuddiesIdSet.contains(buddy.uniqueId) {
                cell.accessoryType = .checkmark
            } else {
                cell.accessoryType = .none
            }
            
            return cell
        }
        return UITableViewCell()
    }
    
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if let buddy = self.threadOwnerAt(indexPath: indexPath, tableView: tableView) {
            if self.selectionModeIsSingle == true {
                let buddySet = Set([buddy.uniqueId])
                self.completeSelectingBuddies(buddySet, groupName: nil)
            } else {
                self.selectedThreadOwner(buddy.uniqueId)
                tableView.reloadRows(at: [indexPath], with: .automatic)
            }
        }
    }
    
    public func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return OTRBuddyInfoCellHeight
    }
    
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return OTRBuddyInfoCellHeight
    }

    public func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return UITableViewCell.EditingStyle.delete
    }
    
    //IOSM#55
    /*public func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        if let thread = self.threadOwnerAt(indexPath: indexPath, tableView: tableView) {
            return UITableView.editActions(forThread: thread)
        }
        return nil
    }*/
    
    func selectedThreadOwner(_ buddyId:String) {
        if buddyId.count == 0 {
            return
        }
        
        if self.selectedBuddiesIdSet.contains(buddyId) {
            self.selectedBuddiesIdSet.remove(buddyId)
        } else {
            self.selectedBuddiesIdSet.insert(buddyId)
        }
        
        //Check length of selected buddies and if none then disable button
        if self.selectedBuddiesIdSet.count > 0 {
            self.navigationItem.rightBarButtonItem?.isEnabled = true
        } else {
            self.switchSelectionMode()
        }
    }
    
    func joinGroup(_ sender:Any?){
        let storyboard = UIStoryboard(name: "OTRJoinGroup", bundle: GlacierInfo.resourcesBundle)
        if let vc = storyboard.instantiateInitialViewController() as? OTRJoinGroupViewController {
            vc.delegate = self
            self.navigationController?.pushViewController(vc, animated: true)
        }
    }
    
    func threadOwnerAt(indexPath:IndexPath, tableView:UITableView) -> ChatBuddy?
    {
        if self.isSearchResultsControllerTableView(tableView) {
            return self.filteredBuddies[indexPath.row]
        }
        return self.myBuddies[indexPath.row]
    }
    
    //#pragma - mark UIScrollViewDelegate
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        self.view.endEditing(true)
    }
    
    public func groupBuddiesSelected(_ composeViewController: OTRComposeGroupViewController, buddyUniqueIds: [String], groupName: String) {
        let bset = Set(buddyUniqueIds)
        self.completeSelectingBuddies(bset, groupName:groupName)
    }
    
    public func groupSelectionCancelled(_ composeViewController: OTRComposeGroupViewController) {
        
    }
    
    /** Intended to be called if selecting one buddy or after a group chat is created*/
    func completeSelectingBuddies(_ buddies:Set<String>, groupName:String?) {
        //TODO: Naive choosing account just any buddy but should really check that account is connected or show picker
        guard let buddyKey = buddies.first, let accountId = ChatBuddyModel.getBuddy(uniqueId: buddyKey)?.accountUniqueId else {
            DDLogError("completeSelectingBuddies error: No account found!")
            return
        }
        self.delegate?.controller(self, didSelectBuddies: Array(buddies), accountId: accountId, name: groupName)
    }
    
    @objc func groupButtonPressed(_ sender:Any?) {
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.alignment = NSTextAlignment.left
        
        let string = "\nInvite-Only groups: Up to 10 members, managed by the owner.\n\nOpen groups: Unlimited members, history saved.\n\nGroup name can’t have special characters."
        let atrStr = NSMutableAttributedString(
            string: string,
            attributes: [
                NSAttributedString.Key.paragraphStyle: paraStyle,
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13)
            ]
        )
        
        let alert = UIAlertController(title: "New Group", message: string, preferredStyle: .alert)
        alert.setValue(atrStr, forKey: "attributedMessage")
        
        let privateAction = UIAlertAction(title: NSLocalizedString("Create Invite-Only Group", comment: "Invite Only button"), style: .default, handler: { (action: UIAlertAction) -> Void in
            let storyboard = UIStoryboard(name: "OTRComposeGroup", bundle: GlacierInfo.resourcesBundle)
            if let vc = storyboard.instantiateInitialViewController() as? OTRComposeGroupViewController {
                vc.delegate = self
                let firstTextField = alert.textFields?.first
                var name = firstTextField?.placeholder
                if firstTextField?.text?.count ?? 0 > 1 {
                    name = firstTextField?.text
                }
                
                if let name = name, self.groupAlreadyExists(name) {
                    self.handleGroupExists()
                } else {
                    vc.groupName = name
                    vc.delegate = self
                    self.navigationController?.pushViewController(vc, animated: true)
                }
            }
        })
        privateAction.isEnabled = false
        
        let openAction = UIAlertAction(title: NSLocalizedString("Create Open Group", comment: "Open Group button"), style: .default, handler: { (action: UIAlertAction) -> Void in
            let firstTextField = alert.textFields![0] as UITextField
            var name = firstTextField.placeholder
            if ((firstTextField.text?.count)! > 1) {
                name = firstTextField.text
            }
            self.delegate?.enterConversation(withName:name!, isPublic:true)
        })
        openAction.isEnabled = false
        
        alert.addAction(privateAction)
        alert.addAction(openAction)
        alert.addAction(UIAlertAction(title: CANCEL_STRING(), style: .cancel, handler: nil))
        alert.addTextField(configurationHandler: { (textField) in
            textField.placeholder = OTRRoomNames.getRoomName()
            NotificationCenter.default.addObserver(
                forName: UITextField.textDidChangeNotification,
                object: textField,
                queue: .main
            ) { _ in
                guard let text = textField.text else { return }
                let allowedCharacters = CharacterSet.alphanumerics.union(.whitespaces)
                let hasNoSpecials = text.rangeOfCharacter(from: allowedCharacters.inverted) == nil
                let notEmptyAfterTrim = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let isValidGroupName = hasNoSpecials && notEmptyAfterTrim && !text.isEmpty
                
                privateAction.isEnabled = isValidGroupName
                openAction.isEnabled = isValidGroupName
            }
        })
        present(alert, animated: true, completion: nil)
    }
    
    func switchSelectionMode() {
        self.selectionModeIsSingle = !self.selectionModeIsSingle
        
        // Change from Join Group / Add Buddy
        let path = IndexPath(row: 0, section: 0)
        self.tableView.reloadRows(at: [path], with: .none)
        
        //Update right bar button item
        if self.selectionModeIsSingle {
            self.navigationItem.rightBarButtonItem = self.groupBarButtonItem
        } else {
            self.navigationItem.rightBarButtonItem = self.doneBarButtonItem
            self.navigationItem.rightBarButtonItem?.isEnabled = false
        }
    }
    
    func handleGroupExists() {
        DispatchQueue.main.async {
            let alertController = UIAlertController(title: "Group Exists", message: "Group already exists, please join the existing group or select a different name.", preferredStyle: .alert)
            let cancelAction = UIAlertAction(title: OK_STRING(), style: .cancel, handler: nil)
            alertController.addAction(cancelAction)
            self.present(alertController, animated: true, completion: nil)
        }
    }

    func groupAlreadyExists(_ groupName: String) -> Bool {
        let accounts = ChatAccountModel.allXMPPAccounts()
        guard accounts.count > 0, let xacct = accounts.first, let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: xacct), let groups = xmpp.roomManager.allRooms else {return false}
        
        var exists = false
        for name in groups {
            let slimName = name.components(separatedBy: "@").first
            if groupName == slimName {
                exists = true
                break
            }
        }

        return exists
    }
    
    @objc func doneButtonPressed(_ sender:Any?) {
        if self.selectedBuddiesIdSet.count > 1 {
            //Group so need user to select name
            let alertController = UIAlertController(title: GROUP_NAME_STRING(), message: ENTER_GROUP_NAME_STRING(), preferredStyle: .alert)
            let okAction = UIAlertAction(title: OK_STRING(), style: .cancel, handler: {[weak self] _ in
                //let name = alertController.textFields?.first?.text
                if let self = self {
                    self.completeSelectingBuddies(self.selectedBuddiesIdSet, groupName: nil)
                }
            })
            let cancelAction = UIAlertAction(title: CANCEL_STRING(), style: .cancel, handler: nil)
            alertController.addAction(okAction)
            alertController.addAction(cancelAction)
            
            alertController.addTextField(configurationHandler: { (textField) in
                textField.placeholder = GROUP_NAME_STRING()
                NotificationCenter.default.addObserver(forName:UITextField.textDidChangeNotification, object: textField, queue: OperationQueue.main, using: { _ in
                    okAction.isEnabled = (textField.text?.count ?? 0) > 0
                })
            })
            
            self.present(alertController, animated: true, completion: nil)
        } else {
            self.completeSelectingBuddies(self.selectedBuddiesIdSet, groupName: nil)
        }
    }
    
    @objc func cancelButtonPressed(_ sender:Any?) {
        // Call dismiss from the split view controller instead
        self.delegate?.controllerDidCancel(self)
    }
    
    // Make sure bar stays at the top
    /*public func position(for bar:UIBarPositioning) -> UIBarPosition {
        return UIBarPosition.top
    }*/
    
    //IOSM#9 (next 7, all search functions)
    func setupSearchController() {
        //self.tableViewHeader.backgroundColor = UIColor.systemGroupedBackground
        //self.tableView.tableHeaderView = self.tableViewHeader
        
        let searchResultsController = UITableViewController.init(style: UITableView.Style.plain)
        searchResultsController.tableView.register(OTRBuddyInfoCell.self, forCellReuseIdentifier: OTRBuddyInfoCell.reuseIdentifier())
        
        searchResultsController.tableView.dataSource = self
        searchResultsController.tableView.delegate = self
        searchResultsController.tableView.estimatedRowHeight = 80
        searchResultsController.tableView.rowHeight = UITableView.automaticDimension
        searchResultsController.tableView.contentInsetAdjustmentBehavior = .never
        
        self.searchController = ComposeSearchController.init(searchResultsController: searchResultsController)
        if let mStyle = self.navigationController?.modalPresentationStyle {
            self.searchController?.setModalStyle(navModalStyle: mStyle)
        }
        self.searchController?.searchResultsUpdater = self
        self.searchController?.obscuresBackgroundDuringPresentation = false
        self.searchController?.hidesNavigationBarDuringPresentation = false
        self.searchController?.delegate = self
        
        self.definesPresentationContext = true

        if let sbar = self.searchController?.searchBar {
            sbar.searchBarStyle = UISearchBar.Style.minimal
            sbar.delegate = self
            self.tableViewHeader.isScrollEnabled = false
            self.tableViewHeader.addStackedSubview(sbar)
        }
    }
    
    func isSearchResultsControllerTableView(_ tableView:UITableView) -> Bool {
        if let src = self.searchController?.searchResultsController as? UITableViewController, tableView == src.tableView {
            return true
        }
        return false
    }
    
    // MARK: UISearchResultsUpdating
    public func updateSearchResults(for searchController: UISearchController) {
        if let searchString = self.searchController?.searchBar.text?.trimmingCharacters(in: CharacterSet.whitespaces), searchString.count > 0 {
            self.filteredBuddies = self.myBuddies.filter({ (buddy) -> Bool in
                return buddy.displayName?.lowercased().contains(searchString.lowercased()) ?? false
            })

            if let resultsController = self.searchController?.searchResultsController as? UITableViewController {
                  resultsController.tableView.reloadData()
            }
        }
    }

    // MARK: UISearchControllerDelegate

    public func willDismissSearchController(_ searchController:UISearchController) {
        //Make sure all the checkmarks are correctly updated
        self.tableView.reloadData()
    }

    public func didDismissSearchController(_ searchController:UISearchController) {
        // Needs to be done, when device was rotated and search bar had focus.
        // The search bar will be in the wrong size now, otherwise.
        self.adjustSearchBarSize()
    }
    
    public func didPresentSearchController(_ searchController:UISearchController) {
        if let searchBar = self.searchController?.searchBar, let tabs = (self.searchController?.searchResultsController as? UITableViewController)?.tableView, let mStyle = self.navigationController?.modalPresentationStyle, mStyle == .formSheet {
            let offset = searchBar.frame.height
            //tabs.setContentOffset(CGPoint(x: 0, y: -offset), animated: true)
        }
    }
    
    /**
     * Resize our UISearchBar, so it fills its superview, exactly.
     */
    func adjustSearchBarSize() {
        if let searchBar = self.searchController?.searchBar, let frame = searchBar.superview?.bounds {
            searchBar.frame = frame
        }
    }
    
    //#pragma - mark keyBoardAnimation Methods
    @objc open func keyboardWillShow(_ notification: NSNotification) {
        self.animateTableViewWithKeyboardNotification(notification)
    }
    
    @objc open func keyboardWillHide(_ notification: NSNotification) {
        self.animateTableViewWithKeyboardNotification(notification)
    }

    func animateTableViewWithKeyboardNotification(_ notification:NSNotification) {
        let userInfo = notification.userInfo
        
        // Get keyboard size and animation.
        if let endFrameValue = (userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue{
            let keyboardEndFrame = self.view.convert(endFrameValue, from: nil)
            
            if let durationValue = userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber {
                let animationDuration = Double(truncating: durationValue)
                if let curveValue = userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber, let animationCurve = UIView.AnimationCurve(rawValue:curveValue.intValue) {
                    
                    let viewHeight = CGRectGetMaxY(self.view.frame)
                    let keyboardY = CGRectGetMinY(keyboardEndFrame)
                    
                    var height = viewHeight - keyboardY
                    //If height is less than 0 or it's hiding set to 0
                    if notification.name == UIResponder.keyboardWillHideNotification || height < 0 {
                        height = 0
                    }
                    
                    self.animateTableViewTo(keyboardHeight: height, animationCurve:animationCurve, animationDuration:animationDuration)
                }
            }
        }
    }

    func animateTableViewTo(keyboardHeight:CGFloat, animationCurve:UIView.AnimationCurve, animationDuration:TimeInterval) {
        self.tableViewBottomConstraint?.constant = -keyboardHeight
        let animations = {
            self.view.layoutIfNeeded()
        }
        
        let adjustedCurve = UIView.AnimationOptions(rawValue: (UInt(animationCurve.rawValue) << 16))
        UIView.animate(withDuration: animationDuration, delay: 0.0, options:[adjustedCurve], animations: animations)
    }

    @objc public func groupSelected(_ composeViewController: OTRJoinGroupViewController, groupName: String) {
        var publicgroup = false
        if let xacct = ChatAccountModel.firstAccount(), let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount:xacct), let roomsWithNames = xmpp.roomManager.allRoomsWithNames {
            if let domain = xacct.domain {
                let after = String(format: "conference.%@", domain)
                let gname = String(format: "%@@%@", groupName, after)
                if let roomwith = roomsWithNames.object(forKey: gname) as? String {
                    if !roomwith.contains("private") {
                        publicgroup = true
                    }
                }
            }
        }
        
        self.delegate?.enterConversation(withName:groupName, isPublic:publicgroup)
        /*guard let xacct = ChatAccountModel.firstAccount() else {return}
        
        let components = groupName.components(separatedBy: "@")
        var gname = groupName
        if components.count != 2, let domain = xacct.domain {
            let after = String(format: "conference.%@", domain)
            gname = String(format: "%@@%@", groupName, after)
        }
        
        guard let roomJid = XMPPJID(string: gname) else { return }
        let joinRoom:((_ account:ChatAccountModel) -> Void) = { (account) in
            if let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account) {
                xmpp.roomManager.joinRoom(roomJid, withNickname: account.displayName, subject: nil, password: nil, completion: nil)
                xmpp.roomManager.publishJoinedRoom(roomJid, withName: account.displayName)
                self.dismiss(animated: true)
            }
        }
        joinRoom(xacct)*/
    }
    
    @objc public func joinGroupCancelled(_ composeViewController: OTRJoinGroupViewController) {
        //
    }
}
