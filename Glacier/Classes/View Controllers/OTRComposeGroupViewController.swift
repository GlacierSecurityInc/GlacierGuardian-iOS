//
//  OTRComposeGroupViewController.swift
//  ChatSecure
//
//  Created by N-Pex on 2017-08-15.
//  Copyright © 2017 Chris Ballinger. All rights reserved.
//

import Foundation
import UIKit
import PureLayout

@objc public protocol OTRComposeGroupViewControllerDelegate {
    func groupBuddiesSelected(_ composeViewController: OTRComposeGroupViewController,  buddyUniqueIds:[String], groupName:String) -> Void
    func groupSelectionCancelled(_ composeViewController: OTRComposeGroupViewController) -> Void
}

open class OTRComposeGroupViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, OTRComposeGroupBuddyCellDelegate, UISearchResultsUpdating, UISearchControllerDelegate, UISearchBarDelegate
{
    @objc public weak var delegate:OTRComposeGroupViewControllerDelegate? = nil
    
    //@IBOutlet weak var collectionView:UICollectionView!
    //@IBOutlet weak var collectionViewHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var tableView:UITableView!
    @IBOutlet weak var doneButton: UIBarButtonItem!
    
    var searchController:ComposeSearchController?
    let tableViewHeader = OTRVerticalStackView.init()
    var modalStyle: UIModalPresentationStyle?
    
    var myBuddies:[ChatBuddy] = []
    var filteredBuddies:[ChatBuddy] = []
    
    var selectedItems:[ChatBuddy] = []
    //var prototypeCell:OTRComposeGroupBuddyCell?
    var existingItems = Set<String>()
    //var waitingForExcludedItems = false
    @objc public var groupName:String?
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        self.tableView.contentInsetAdjustmentBehavior = .never
        
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = GlobalTheme.shared.lightThemeColor;
        appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.label]
        self.navigationController?.navigationBar.tintColor = UIColor.label
        self.navigationController?.navigationBar.standardAppearance = appearance
        self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
        
        self.tableView.delegate = self
        self.tableView.dataSource = self
        
        self.setupSearchController()
        
        let accounts = ChatAccountModel.allXMPPAccounts()
        guard accounts.count > 0, let xacct = accounts.first, let acctgrec = xacct.grdbRecord else {return}
        //getBuddiesAsync and then update screen?
        ChatBuddy.getAllBuddies(for: acctgrec, completion: { [weak self] (buddies) in
            self?.myBuddies = buddies
            self?.filteredBuddies = buddies
            self?.tableView?.reloadData()
        })
 
        self.doneButton.isEnabled = (selectedItems.count > 0)
        self.tableView.register(OTRBuddyInfoCheckableCell.self, forCellReuseIdentifier: OTRBuddyInfoCheckableCell.reuseIdentifier())
    }
    
    // (next 7, all search functions)
    func setupSearchController() {
        
        self.tableViewHeader.backgroundColor = UIColor.systemGroupedBackground
        self.tableView.tableHeaderView = self.tableViewHeader
        
        let searchResultsController = UITableViewController.init(style: UITableView.Style.plain)
        searchResultsController.tableView.register(OTRBuddyInfoCheckableCell.self, forCellReuseIdentifier: OTRBuddyInfoCheckableCell.reuseIdentifier())
        
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
        self.tableView?.reloadData()
    }

    public func didDismissSearchController(_ searchController:UISearchController) {
        // Needs to be done, when device was rotated and search bar had focus.
        // The search bar will be in the wrong size now, otherwise.
        self.adjustSearchBarSize()
    }
    
    public func didPresentSearchController(_ searchController:UISearchController) {
        if let searchBar = self.searchController?.searchBar, let tabs = (self.searchController?.searchResultsController as? UITableViewController)?.tableView, let mStyle = self.navigationController?.modalPresentationStyle, mStyle == .formSheet {
            let offset = searchBar.frame.height
            tabs.setContentOffset(CGPoint(x: 0, y: -offset), animated: true)
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
    
    func threadOwnerAt(indexPath:IndexPath, tableView:UITableView) -> ChatBuddy?
    {
        if self.isSearchResultsControllerTableView(tableView) {
            return self.filteredBuddies[indexPath.row]
        }
        return self.myBuddies[indexPath.row]
    }
    
    @IBAction open func didPressDone(_ sender: Any) {
        guard selectedItems.count > 0, let delegate = self.delegate else { return }
        var buddyIds:[String] = []
        //var generatedGroupName = ""
        for buddy in selectedItems {
            buddyIds.append(buddy.uniqueId)
        }
        
        if (groupName == nil) {
            groupName = OTRRoomNames.getRoomName()
        }
        delegate.groupBuddiesSelected(self, buddyUniqueIds: buddyIds, groupName: groupName!)
        groupName = nil;
        dismiss(animated: true, completion: nil)
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
        if let cell = tableView.dequeueReusableCell(withIdentifier: OTRBuddyInfoCheckableCell.reuseIdentifier(), for: indexPath) as? OTRBuddyInfoCheckableCell,
            let buddy = self.threadOwnerAt(indexPath: indexPath, tableView: tableView), let acctId = buddy.accountUniqueId {
            let account:ChatAccountModel? = ChatAccountModel.getXMPPAccount(uniqueId: acctId)
            // gray and not selectable if no keys
            let devices:[ChatOmemoDevice] = ChatOmemoDevice.allOMEMODevices(for: buddy.uniqueId)

            let buddyModel = ChatBuddyModel(buddy: buddy)
            cell.setBuddyThread(buddyModel, account: account)
            cell.setChecked(checked: selectedItems.contains(buddy))
            var isExistingOccupant = false
            if existingItems.contains(buddy.uniqueId) {
                isExistingOccupant = true
            }
            
            let tColor = UIColor.label
            cell.nameLabel.textColor = isExistingOccupant ? UIColor.gray : tColor
            cell.accountLabel.textColor = isExistingOccupant ? UIColor.gray : tColor
            cell.identifierLabel.textColor = isExistingOccupant ? UIColor.gray : tColor
            cell.accountLabel.text = nil;
            
            if (isExistingOccupant) {
                cell.isUserInteractionEnabled = false
                cell.setChecked(checked: true)
            } else if (devices.count == 0) {
                cell.isUserInteractionEnabled = false
                cell.accountLabel.text = "No secure keys available"
                cell.accountLabel.textColor = UIColor.gray
                cell.nameLabel.textColor = UIColor.gray
            } else {
                cell.isUserInteractionEnabled = true
            }
            
            return cell
        }
        return UITableViewCell()
    }
    
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return OTRBuddyInfoCellHeight
    }
    
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if let buddy = self.threadOwnerAt(indexPath: indexPath, tableView: tableView) {
            if !selectedItems.contains(buddy) {
                selectedItems.append(buddy)
            } else if let index = selectedItems.firstIndex(of: buddy) {
                selectedItems.remove(at: index)
            }
            self.doneButton.isEnabled = (selectedItems.count > 0)
            tableView.reloadRows(at: [indexPath], with: .automatic)
            //updateFiltering()
        }
    }
    
    public func didRemoveBuddy(_ buddy: ChatBuddy) {
        if let index = selectedItems.firstIndex(of: buddy) {
            selectedItems.remove(at: index)
            self.doneButton.isEnabled = (selectedItems.count > 0)
            //updateFiltering()
            tableView.reloadData()
        }
    }

    /*open func updateFiltering() {
        if (selectedItems.count == 0) {
            filterOnAccount(accountUniqueId: nil)
        } else if (selectedItems.count == 1) {
            filterOnAccount(accountUniqueId: selectedItems[0].accountUniqueId)
        }
    }*/
    
    open func setExisting(roomOccupants:Set<String>, room:ChatRoomModel?) {
        self.existingItems = roomOccupants
        
        // query keys as needed
        ChatBuddyModel.getAllBuddies(completion: { [weak self] (buddies) in
            DispatchQueue.global().async {
                var budjids:[XMPPJID] = []
                for buddy in buddies {
                    let devices = ChatOmemoDevice.allOMEMODevices(for: buddy.uniqueId)
                    if let bjid = buddy.bareJID, devices.count == 0 {
                        budjids.append(bjid)
                    }
                }
                
                let accounts = ChatAccountModel.allXMPPAccounts()
                if accounts.count > 0, let xacct = accounts.first, let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: xacct) {
                    for (_, item) in budjids.enumerated() {
                        xmpp.omemoSignalCoordinator?.omemoModule?.fetchDeviceIds(for: item, elementId: nil)
                    }
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.tableView?.reloadData()
                }
            }
        })
    }
    
    override open func willMove(toParent parent: UIViewController?)
    {
        if parent == nil, let delegate = self.delegate {
            delegate.groupSelectionCancelled(self)
        }
    }
}

class ComposeSearchController: UISearchController {
    var modalStyle:UIModalPresentationStyle?
    func setModalStyle(navModalStyle: UIModalPresentationStyle) {
        self.modalStyle = navModalStyle
    }
//page sheet is jackled up
    override func viewWillLayoutSubviews() {
        if let superguy = self.searchBar.superview, self.modalStyle == .formSheet {
            superguy.frame.origin = .zero
            let sframe = superguy.frame //currently 44, should be 56
            if sframe.origin.y != sframe.height {
                superguy.frame.origin.y = sframe.height
            }
        }
        super.viewWillLayoutSubviews()
    }
}
