//
//  SMSComposeViewController.swift
//  Glacier
//
//  Created by andyfriedman on 9/22/22.
//  Copyright © 2022 Glacier. All rights reserved.
//

import UIKit

@objc public protocol SMSComposeViewControllerDelegate: NSObjectProtocol {
    func controller(_ viewController: SMSComposeViewController, didSelectBuddies buddies: [String]?, accountId: String?, name: String?)
    func controllerDidCancel(_ viewController: SMSComposeViewController)
}

@objc open class SMSComposeViewController: UITableViewController, UISearchBarDelegate, UITextFieldDelegate {
    
    var delegate:SMSComposeViewControllerDelegate?
    var smsContacts = TwilioBackendManager.sharedMgr().contacts.filter({ (contact) -> Bool in
        return contact.phoneNumber.count > 6
    })
    var accountId : String?
    var sendingNumber : String?
    
    var filteredContacts:[PhoneContact]?
    let tableViewHeader = VerticalStackView.init()
    var modalStyle: UIModalPresentationStyle?
    var defaultImage = UIImage.init(named: "person", in: GlacierInfo.resourcesBundle, with: nil)?.withRenderingMode(.alwaysTemplate)
    private var searchBar = UISearchBar()
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = GlobalTheme.shared.lightThemeColor;
        appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.label]
        self.navigationController?.navigationBar.tintColor = UIColor.label
        self.navigationController?.navigationBar.standardAppearance = appearance
        self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
        
        self.navigationItem.title = "New Conversation"
        self.tableView.register(BuddyInfoCell.self, forCellReuseIdentifier: BuddyInfoCell.reuseIdentifier())
        
        let cancelBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelButtonPressed(_:)))
        cancelBarButtonItem.tintColor = UIColor.label
        self.navigationItem.leftBarButtonItem = cancelBarButtonItem
        
        let plusBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(plusButtonPressed(_:)))
        plusBarButtonItem.tintColor = UIColor.label
        self.navigationItem.rightBarButtonItem = plusBarButtonItem
        
        self.filteredContacts = self.smsContacts.filter({ (contact) -> Bool in
            return contact.phoneNumber.count > 6
        })
        
        self.setupSearchHeaderView()
        self.setupTapGestureRecognizer()
        
        tableView.delegate = self
        tableView.dataSource = self
    }
    
    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.view.endEditing(true)
        self.searchBar.text = nil
        self.showAllContacts()
    }
    
    open func setAccount(_ account:String, myNumber:String) {
        self.accountId = account
        self.sendingNumber = myNumber
    }
    
    @objc open func cancelButtonPressed(_ sender: AnyObject?) {
        //self.dismiss(animated: true, completion: nil)
        self.delegate?.controllerDidCancel(self)
    }
    
    @objc open func plusButtonPressed(_ sender: AnyObject?) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = NSTextAlignment.left
        
        let alert = UIAlertController(title: NSLocalizedString("New Number", comment: "New Number"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Chat", comment: "Chat"), style: .default, handler: {(action: UIAlertAction!) in
            if let phoneNumber = alert.textFields?.first?.text {
                self.newSMSTapped(phoneNumber)
            }
        }))
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel"), style: .cancel, handler: nil))
        
        alert.addTextField(configurationHandler: {(textField: UITextField!) in
            textField.placeholder = "Type a phone number"
            textField.keyboardType = .asciiCapableNumberPad
            textField.isSecureTextEntry = false
        })
        self.present(alert, animated: true, completion: nil)
    }
    
    @objc func newSMSTapped(_ phoneNumber:String) { //_ sender:AnyObject){
        
        guard phoneNumber.count > 9, self.accountId != nil else {
            return
        }
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = NSTextAlignment.left
        
        let alert = UIAlertController(title: NSLocalizedString("Display name", comment: "Display name for conversation"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Add name", comment: "Add name button"), style: .default, handler: {(action: UIAlertAction!) in
            if let displayName = alert.textFields?.first?.text {
                self.proceedWithSMSToNumber(displayName, number: phoneNumber)
            }
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
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("No thanks", comment: "No button"), style: .cancel, handler: {(action: UIAlertAction!) in
            self.proceedWithSMSToNumber(nil, number: phoneNumber)
        }))
        alert.addTextField(configurationHandler: {(textField: UITextField!) in
            textField.placeholder = "Contact name"
            textField.isSecureTextEntry = false
        })
        self.present(alert, animated: true, completion: nil)
    }
    
    private func proceedWithSMSToNumber(_ displayName:String?, number:String) {
        if let acct = self.accountId, let sendingNum = self.sendingNumber {
            let remoteNumber = CallManager.cleanPhoneNumber(number)
            
            //let convId = UUID().uuidString
            var conversation = TwilioBackendManager.sharedMgr().getExistingConversation(localNumber: sendingNum, remoteNumber: remoteNumber)
            
            if conversation == nil {
                let newConversation = SMSChatConversationModel(remoteNumber: remoteNumber, localNumber: sendingNum, accountId: acct)
                newConversation.grdbRecord?.preferredName = number
                
                if let dname = displayName {
                    newConversation.grdbRecord?.preferredName = dname
                    newConversation.avatar = GlacierImages.avatarImage(withUsername: dname)
                } else {
                    let lasttwo = String(number.suffix(2)).insertingSpace(every: 1)
                    newConversation.avatar = GlacierImages.avatarImage(withUsername: lasttwo)
                }
                
                newConversation.grdbRecord?.isNew = true
                newConversation.save()
                
                conversation = newConversation
                TwilioBackendManager.sharedMgr().createAndJoinConversation(friendlyName: sendingNum, smsConversation: newConversation)
            }
            
            if let conv = conversation {
                //TwilioBackendManager.sharedMgr().createAndJoinConversation(friendlyName: sendingNum, smsConversation: conv)
                self.delegate?.controller(self, didSelectBuddies: [conv.uniqueId], accountId: acct, name: nil)
            }
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
        
        self.filteredContacts = self.smsContacts.filter { $0.phoneNumber.count > 6 && $0.name.lowercased().contains(searchString.lowercased()) }
        self.tableView.reloadData()
    }
    
    private func showAllContacts() {
        self.filteredContacts?.removeAll()
        self.filteredContacts?.append(contentsOf: self.smsContacts)
        self.tableView.reloadData()
    }
    
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let contacts = self.filteredContacts else {
            return 0
        }
        return contacts.count
    }
    
    override open func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return super.tableView(tableView, heightForHeaderInSection: section)
    }

    override open func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let contacts = self.filteredContacts,
              let cell = tableView.dequeueReusableCell(withIdentifier: BuddyInfoCell.reuseIdentifier()) as? BuddyInfoCell else {
            return UITableViewCell()
        }
        
        cell.avatarImageView.image = self.defaultImage
        cell.avatarImageView.tintColor = UIColor.label
        cell.avatarImageView.layer.borderWidth = 0.0
        cell.imageViewBorderColor = Colors.color(with: ThreadStatus.offline)
        cell.avatarImageView.layer.cornerRadius = (SMSViewController.kOTRConversationCellHeight-2.0*BuddyImageCellPadding)/2.0
        cell.contentView.setNeedsUpdateConstraints()
        
        if contacts.isEmpty {
            cell.nameLabel.text = "No Numbers"
        } else {
            let contactDetails = contacts[indexPath.row]
            cell.accountLabel.text = contactDetails.phoneNumber
            cell.nameLabel.text = contactDetails.name
            if let avatar = contactDetails.avatar {
                cell.avatarImageView.image = avatar
            }
        }
        
        return cell
    }

    override open func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let contacts = self.filteredContacts else { return }
        let contactDetails = contacts[indexPath.row]
        let number = contactDetails.phoneNumber
        let name = contactDetails.name
        let avatar = contactDetails.avatar
        self.handleNewSms(number, name: name, avatar: avatar)
        
        self.dismiss(animated: true)
    }
    
    func handleNewSms(_ number:String, name:String, avatar:UIImage?) {
        if number.count > 9, let acct = self.accountId, let sendingNum = self.sendingNumber {
            let remoteNumber = CallManager.cleanPhoneNumber(number)
            
            var conversation = TwilioBackendManager.sharedMgr().getExistingConversation(localNumber: sendingNum, remoteNumber: remoteNumber)
            
            if conversation == nil {
                let newConversation = SMSChatConversationModel(remoteNumber: remoteNumber, localNumber: sendingNum, accountId: acct)
                newConversation.grdbRecord?.preferredName = name
                newConversation.grdbRecord?.isNew = true
                
                if let ava = avatar {
                    newConversation.avatar = ava
                } else {
                    newConversation.avatar = GlacierImages.avatarImage(withUsername: name)
                }
                
                newConversation.save()
                conversation = newConversation
                TwilioBackendManager.sharedMgr().createAndJoinConversation(friendlyName: sendingNum, smsConversation: newConversation)
            }
            
            if let conv = conversation {
                //TwilioBackendManager.sharedMgr().createAndJoinConversation(friendlyName: sendingNum, smsConversation: conv)
                self.delegate?.controller(self, didSelectBuddies: [conv.uniqueId], accountId: acct, name: nil)
            }
        } else {
            //alert user that something went wrong?
        }
    }
}

struct PhoneContact
{
    var name:String
    var phoneNumber:String
    var avatar:UIImage?
}

extension UITextField {
    func setOnTextChangeListener(onTextChanged :@escaping () -> Void){
        self.addAction(UIAction(){ action in
            onTextChanged()
        }, for: .editingChanged)
    }
}

class SMSComposeSearchController: UISearchController {
    var modalStyle:UIModalPresentationStyle?
    func setModalStyle(navModalStyle: UIModalPresentationStyle) {
        self.modalStyle = navModalStyle
    }
    //page sheet is jacked up
    override func viewWillLayoutSubviews() {
        if let superguy = self.searchBar.superview, self.modalStyle == .formSheet {
            superguy.frame.origin = .zero
        }
        super.viewWillLayoutSubviews()
    }
}
