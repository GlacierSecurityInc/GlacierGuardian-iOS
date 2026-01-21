//
//  SMSNumbersViewController.swift
//  Glacier
//
//  Created by andyfriedman on 9/16/22.
//  Copyright © 2022 Glacier. All rights reserved.
//

import UIKit
import MBProgressHUD

@objc public protocol SMSNumbersDelegate: NSObjectProtocol {
    func numberSelected(_ selectedNumber:String, selectedName:String?)
}

public enum SMSNumbersAction {
    case add
    case release
    case name
    case copy
}

@objc open class SMSNumbersViewController: UITableViewController, UISearchBarDelegate {//}, UISearchResultsUpdating, UISearchControllerDelegate {
    
    var numbers: [String] = []
    var names: [String?] = []
    var delegate:SMSNumbersDelegate?
    var numAction = SMSNumbersAction.add
    
    var prefilteredNumbers = [String]()
    let tableViewHeader = OTRVerticalStackView.init()
    var modalStyle: UIModalPresentationStyle?
    
    var searchBar: UISearchBar?
    var spinnerHUD: MBProgressHUD?
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        self.navigationItem.title = "Phone Numbers"
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: "smsnumbers")
        
        let cancelBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelButtonPressed(_:)))
        cancelBarButtonItem.tintColor = UIColor.label
        self.navigationItem.leftBarButtonItem = cancelBarButtonItem
        
        if self.numAction == .add {
            // Set up the search bar
            searchBar = UISearchBar()
            searchBar?.delegate = self
            searchBar?.placeholder = "Area code or partial number"
            searchBar?.backgroundColor = UIColor.systemGroupedBackground
            searchBar?.searchTextField.keyboardType = .phonePad
            //searchBar?.returnKeyType = .search
            //searchBar.frame = CGRect(x: 20, y: 100, width: self.view.frame.width - 40, height: 40)
            
            let searchButton = UIButton(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
            searchButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4.0, leading: 8.0, bottom: 4.0, trailing: 8.0)
            searchButton.titleLabel?.font = UIFont(name: kFontAwesomeFont, size: 22)
            searchButton.titleLabel?.textAlignment = NSTextAlignment.center
            searchButton.setTitleColor(.appleBlue(), for: UIControl.State.normal)
            if self.traitCollection.userInterfaceStyle == .dark {
                searchButton.setTitleColor(.white, for: UIControl.State.normal)
            }
            let searchIconChar = 0xf002
            searchButton.setTitle(String(format: "%C", searchIconChar), for: .normal)
            searchButton.addTarget(self, action: #selector(doSearch), for: .touchUpInside)
            searchButton.translatesAutoresizingMaskIntoConstraints = false
            //view.addSubview(searchButton)
            
            let searchView = UIView(frame: CGRect(x: 0, y: 0, width: self.view.frame.width, height: 50))
            searchView.addSubview(searchBar!)
            searchView.addSubview(searchButton)
            
            searchBar?.autoPinEdge(toSuperviewEdge: .leading, withInset: 0)
            searchBar?.autoPinEdge(toSuperviewEdge: .trailing, withInset: 40)
            searchBar?.autoPinEdge(toSuperviewEdge: .top, withInset: 0)
            searchBar?.autoPinEdge(toSuperviewEdge: .bottom, withInset: 0)
            //searchBar?.autoSetDimension(.height, toSize: 50.0)
            searchBar?.translatesAutoresizingMaskIntoConstraints = false
            
            searchButton.autoPinEdge(.leading, to: .trailing, of: searchBar!)
            searchButton.autoPinEdge(toSuperviewEdge: .trailing, withInset: 10)
            searchButton.autoPinEdge(toSuperviewEdge: .top, withInset: 0)
            searchButton.autoPinEdge(toSuperviewEdge: .bottom, withInset: 0)
            searchButton.translatesAutoresizingMaskIntoConstraints = false
            
            searchBar?.searchBarStyle = UISearchBar.Style.minimal
            self.tableViewHeader.isScrollEnabled = false
            self.tableViewHeader.backgroundColor = UIColor.systemGroupedBackground
            self.tableViewHeader.addStackedSubview(searchView) //searchBar!)
            self.tableView.tableHeaderView = self.tableViewHeader
            
            searchView.autoPinEdge(toSuperviewEdge: .leading, withInset: 0)
            searchView.autoPinEdge(toSuperviewEdge: .trailing, withInset: 0)
            searchView.autoSetDimension(.height, toSize: 50.0)
            searchView.translatesAutoresizingMaskIntoConstraints = false
            
            TwilioBackendManager.sharedMgr().setSMSDelegate(self)
            self.prefilteredNumbers = numbers
        }
        
        tableView.delegate = self
        tableView.dataSource = self
    }
    
    open override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        if self.numAction == SMSNumbersAction.add {
            TwilioBackendManager.sharedMgr().removeLastSMSDelegate()
        }
    }
    
    open func setNumbers(_ numbers:[String], names:[String?], action:SMSNumbersAction) {
        self.numbers = numbers
        self.prefilteredNumbers = numbers
        self.names = names
        self.numAction = action
        
        self.tableView.reloadData()
    }
    
    @objc open func cancelButtonPressed(_ sender: AnyObject?) {
        self.dismiss(animated: true, completion: nil)
    }
    
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        //if self.isSearchResultsControllerTableView(tableView) {
        //    return self.filteredNumbers.count
        //}
        return self.numbers.count
    }
    
    override open func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return super.tableView(tableView, heightForHeaderInSection: section)
    }

    override open func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "smsnumbers")!
        if (self.numbers.count == 0) {
            cell.textLabel?.text = "No Numbers"
        } else {
            let num = self.numbers[indexPath.row]
            if self.numAction != SMSNumbersAction.add, let name = self.names[indexPath.row] {
                if num == name {
                    cell.textLabel?.text = num
                } else {
                    cell.textLabel?.text = num + "  -  " + name
                }
            } else {
                cell.textLabel?.text = num
            }
        }
        return cell
    }

    override open func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let number = self.numbers[indexPath.row]
        
        if self.numAction == SMSNumbersAction.release {
            self.confirmRelease(number, selectedName: self.names[indexPath.row])
            return
        } else if self.numAction == SMSNumbersAction.copy {
            self.doCopy(number)
            return
        }
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = NSTextAlignment.left
        
        let alert = UIAlertController(title: NSLocalizedString("Display name", comment: "Display name for SMS number"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Add name", comment: "Add name button"), style: .default, handler: {(action: UIAlertAction!) in
            if let displayName = alert.textFields?.first?.text {
                if self.numAction == SMSNumbersAction.name {
                    if let del = self.delegate {
                        del.numberSelected(number, selectedName: displayName)
                    }
                    self.dismiss(animated: true, completion: nil)
                } else {
                    self.confirmNumberSelected(number, selectedName: displayName)
                }
            }
        }))
        
        let msg = "\nWould you like to give this number a name for simplicity? Only you will see this name, and it will disappear if you log out."
        let messageText = NSMutableAttributedString(
            string: msg,
            attributes: [
                NSAttributedString.Key.paragraphStyle: paragraphStyle,
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13)
            ]
        )
        alert.setValue(messageText, forKey: "attributedMessage")
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("No thanks", comment: "No button"), style: .cancel, handler: {(action: UIAlertAction!) in
            if self.numAction == SMSNumbersAction.name {
                if let del = self.delegate {
                    del.numberSelected(number, selectedName: nil)
                }
                self.dismiss(animated: true, completion: nil)
            } else {
                self.confirmNumberSelected(number, selectedName: nil)
            }
        }))
        alert.addTextField(configurationHandler: {(textField: UITextField!) in
            textField.placeholder = "SMS name"
            textField.isSecureTextEntry = false
        })
        self.present(alert, animated: true, completion: nil)
    }
    
    /*public func textFieldShouldClear(_ textField: UITextField) -> Bool {
        //use this to reset UI if desired
        return true
    }*/
    
    @objc func doSearch() {
        self.searchBarSearchButtonClicked(self.searchBar!)
    }
    // MARK: - UISearchBarDelegate
        
    public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard let searchText = searchBar.text else { return }
            
        // Perform the search action when search button is clicked
        if !searchText.isEmpty {
            if searchText.count == 3 {
                TwilioBackendManager.sharedMgr().queryForAvailableNumbers(areaCode:searchText, contains: nil)
            } else {
                TwilioBackendManager.sharedMgr().queryForAvailableNumbers(areaCode:nil, contains: searchText)
            }
            self.addSpinnerHUD("Retrieving data...")
        }
            
        // Dismiss the keyboard
        searchBar.resignFirstResponder()
    }
    
    func confirmRelease(_ selectedNumber:String, selectedName:String?) {
        var msgnum = selectedNumber
        if let name = selectedName, name != msgnum {
            msgnum = msgnum + "  -  " + name
        }
        let msg = "Are you sure you want to release " + msgnum + "?"
        
        let alert = UIAlertController(title: "Confirm release number", message: msg, preferredStyle: .alert)
        let release = UIAlertAction(title: "Release", style: .default) {
            (result : UIAlertAction) -> Void in
            if let del = self.delegate {
                del.numberSelected(selectedNumber, selectedName: selectedName)
            }
            self.dismiss(animated: true, completion: nil)
        }
        let cancel = UIAlertAction(title: "Cancel", style: .cancel, handler: {(action: UIAlertAction!) in
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(release)
        alert.addAction(cancel)
        self.present(alert, animated: true, completion: nil)
    }
    
    func doCopy(_ selectedNumber:String) {
        let alert = UIAlertController(title: "Copy to Clipboard?", message: "Copying this number to your device will allow any other apps on your device to access it.", preferredStyle: .alert)
    
        alert.addAction(UIAlertAction(title: "Copy", style: .default) { _ in
            UIPasteboard.general.string = selectedNumber
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: {(action: UIAlertAction!) in
            self.dismiss(animated: true, completion: nil)
        }))
    
        self.present(alert, animated: true)
    }
    
    func confirmNumberSelected(_ selectedNumber:String, selectedName:String?) {
        let alert = UIAlertController(title: "Confirm new number", message: "Are you sure you want to add a new phone number?", preferredStyle: .alert)
        let add = UIAlertAction(title: "Add", style: UIAlertAction.Style.default) {
            (result : UIAlertAction) -> Void in
            if let del = self.delegate {
                del.numberSelected(selectedNumber, selectedName: selectedName)
            }
            self.dismiss(animated: true, completion: nil)
        }
        let cancel = UIAlertAction(title: "Cancel", style: .cancel, handler: {(action: UIAlertAction!) in
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(add)
        alert.addAction(cancel)
        self.present(alert, animated: true, completion: nil)
    }
}

extension SMSNumbersViewController : TwilioAccountDelegateProtocol {
    public func availableNumbersUpdated(_ availableNumbers: [String]) {
        self.numbers = availableNumbers
        
        DispatchQueue.main.async {
            if let hud = self.spinnerHUD {
                hud.removeFromSuperview()
                self.spinnerHUD = nil
            }
            self.tableView.reloadData()
        }
    }
}

extension SMSNumbersViewController {
    public func addSpinnerHUD(_ message:String) {
        DispatchQueue.main.async {
            if (self.spinnerHUD == nil) {
                self.spinnerHUD = MBProgressHUD.showAdded(to: self.view, animated: true)
                self.spinnerHUD?.label.text = message
            }
        }
    }
}
