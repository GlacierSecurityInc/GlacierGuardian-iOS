//
//  OTRJoinGroupViewController.swift
//  ChatSecureCore
//
//  Created by Andy Friedman on 11/8/17.
//  Copyright © 2017 Chris Ballinger. All rights reserved.
//
import Foundation
import UIKit
import PureLayout

@objc public protocol OTRJoinGroupViewControllerDelegate {
    func groupSelected(_ composeViewController: OTRJoinGroupViewController, groupName:String) -> Void
    func joinGroupCancelled(_ composeViewController: OTRJoinGroupViewController) -> Void
}

open class OTRJoinGroupViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate
{
    @objc public weak var delegate:OTRJoinGroupViewControllerDelegate? = nil
    @IBOutlet weak var tableView:UITableView!
    
    var existingItems = Set<String>()
    
    var cellData:[String] = []
    var filteredCellData:[String] = []
    private var searchBar = UISearchBar()
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = GlobalTheme.shared.lightThemeColor;
        appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.label]
        self.navigationController?.navigationBar.standardAppearance = appearance
        self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
        
        resetData()
        self.setupSearchHeaderView()
        self.setupTapGestureRecognizer()
        
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: "groupname")
    }
    
    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resetData()
        
        self.view.endEditing(true)
        self.searchBar.text = nil
        self.showAllRooms()
    }
    
    private func resetData() {
        cellData.removeAll()
        let accounts = ChatAccountModel.allXMPPAccounts()
        if (accounts.count > 0) {
            let account = accounts[0]
            let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount:account)
            if (xmpp != nil) {
                if let tempData = xmpp?.roomManager.availableRooms {
                    for gname in tempData {
                        //check if room already joined?
                        
                        if let range = gname.range(of: "@") {
                            let slimname = String(gname[..<range.lowerBound])
                            cellData.append(slimname)
                        }
                    }
                }
            }
        }
        
        filteredCellData.removeAll()
        filteredCellData.append(contentsOf: cellData)
        
        if (cellData.count < 1) {
            cellData.append("No rooms to join")
        }
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
    
    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        let searchString = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchString.isEmpty else {
            self.showAllRooms()
            return
            
        }
        
        self.filteredCellData = self.cellData.filter { $0.lowercased().contains(searchString.lowercased()) }
        self.tableView.reloadData()
    }
    
    private func showAllRooms() {
        self.filteredCellData.removeAll()
        self.filteredCellData.append(contentsOf: self.cellData)
        self.tableView.reloadData()
    }
    
    @objc private func handleTableViewTap() {
        view.endEditing(true)
    }
    
    public func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filteredCellData.count
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if let cell = self.tableView.dequeueReusableCell(withIdentifier: "groupname") {
            cell.textLabel?.text = self.filteredCellData[indexPath.row]
            return cell
        }
        return UITableViewCell()
    }
    
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 50
    }
    
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let gname = self.filteredCellData[indexPath.row] as String
        if (gname.hasPrefix("No rooms")) {
            dismiss(animated: true, completion: nil)
            return 
        }
        
        if let delegate = delegate {
            delegate.groupSelected(self, groupName: gname)
        }
        dismiss(animated: true, completion: nil)
    }
    
    override open func willMove(toParent parent: UIViewController?)
    {
        if parent == nil, let delegate = self.delegate {
            delegate.joinGroupCancelled(self)
        }
    }
}

