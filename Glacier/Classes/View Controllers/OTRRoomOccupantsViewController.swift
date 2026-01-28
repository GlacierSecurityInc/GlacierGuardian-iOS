//
//  OTRRoomOccupantsViewController.swift
//  ChatSecure
//
//  Created by David Chiles on 10/28/15.
//  Copyright © 2015 Chris Ballinger. All rights reserved.
//

import Foundation
import UIKit
import PureLayout
import BButton
import MBProgressHUD
import GRDB
import XMPPFramework

@objc public protocol OTRRoomOccupantsViewControllerDelegate {
    func didLeaveRoom(_ roomOccupantsViewController: OTRRoomOccupantsViewController) -> Void
}

private struct CellIdentifier {
    /// Storyboard Cell Identifiers
    static let HeaderCellGroupName = StoryboardCellIdentifier.groupName.rawValue
    static let HeaderCellShare = StoryboardCellIdentifier.share.rawValue
    static let HeaderCellAddFriends = StoryboardCellIdentifier.addFriends.rawValue
    static let HeaderCellPinned = StoryboardCellIdentifier.pinned.rawValue
    static let HeaderCellMute = StoryboardCellIdentifier.mute.rawValue
    static let HeaderCellMembers = StoryboardCellIdentifier.members.rawValue
    static let FooterCellLeave = StoryboardCellIdentifier.leave.rawValue
}


/// Cell identifiers only used in code
private enum DynamicCellIdentifier: String {
    case occupant = "occupant"
    case omemoToggle = "cellGroupOMEMOToggle"
    case omemoConfig = "cellGroupOMEMOConfig"
}

/// Cell identifiers from the OTRRoomOccupants.storyboard
private enum StoryboardCellIdentifier: String {
    case groupName = "cellGroupName"
    case share = "cellGroupShare"
    case addFriends = "cellGroupAddFriends"
    case pinned = "cellGroupPinned" // (and all pinned below)
    case mute = "cellGroupUnmute"
    case members = "cellGroupMembers"
    case leave = "cellGroupLeave"
}

private class GenericHeaderCell: UITableViewCell {
    static let cellHeight: CGFloat = 44
    override func prepareForReuse() {
        super.prepareForReuse()
        textLabel?.text = nil
        accessoryView = nil
    }
}

fileprivate let headerSection = 0
fileprivate let occupantsSection = 0
//fileprivate let footerSection = 1

//fileprivate var footerRows:[String] = [
//    CellIdentifier.FooterCellLeave
//]

open class OTRRoomOccupantsViewController: UIViewController {
    @objc public weak var delegate:OTRRoomOccupantsViewControllerDelegate? = nil

    @IBOutlet open weak var tableView:UITableView!
    @IBOutlet weak var largeAvatarView:UIImageView!
    @IBOutlet open weak var tableView2: UITableView!
    let table2ViewHeader = OTRVerticalStackView.init()
    
    private var headerRows:[String] = [
        CellIdentifier.HeaderCellGroupName,
        CellIdentifier.HeaderCellAddFriends,
        CellIdentifier.HeaderCellPinned,
        CellIdentifier.HeaderCellMute,
        //CellIdentifier.HeaderCellMembers,
        CellIdentifier.FooterCellLeave
    ]
    
    let disabledCellAlphaValue:CGFloat = 0.5
    let imageCellPadding:CGFloat = 12.0

    // For matching navigation bar and avatar
    var navigationBarShadow:UIImage?
    var navigationBarBackground:UIImage?
    var topBounceView:UIView?

    private var dataSource: RoomOccupantsSource!
    private var occCancellable: DatabaseCancellable?
    
    open var roomUniqueId: String?
    var notificationToken:NSObjectProtocol? = nil
    
    var pins:XMPPPinned?
    
    open var room:ChatRoomModel? {
        return self.xmppRoom()
    }
    
    private func xmppRoom() -> ChatRoomModel? {
        guard let roomUniqueId = self.roomUniqueId else {
            return nil
        }
        return ChatRoomModel.getXMPPRoom(uniqueId: roomUniqueId)
    }
    
    open var crownImage:UIImage?
    
    @objc public init(roomKey:String) {
        super.init(nibName: nil, bundle: nil)
        self.roomUniqueId = roomKey
        guard let _ = self.room else {
            return
        }
        //self.fetchMembersList()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    open func setRoomKey(_ roomKey:String) {
        self.roomUniqueId = roomKey
        guard let _ = self.room else {
            return
        }
        self.fetchMembersList()
    }
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        if let room = self.room {
            if (room.avatarSeedNum < 0) {
                room.avatarSeedNum = room.nextAvatarNum(with:-1)
                //room.saveThread()
            }
            //let seedNum = room.avatarSeedNum
            //let image = OTRGroupAvatarGenerator.avatarImage(withSeedNum: seedNum, width: Int(largeAvatarView.frame.width), height: Int(largeAvatarView.frame.height))
            largeAvatarView.image = room.avatarImage//image
        }
        
        self.crownImage = UIImage(named: "crown", in: GlacierInfo.resourcesBundle, compatibleWith: nil)?.withRenderingMode(.alwaysTemplate)
        
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView2.delegate = self
        //self.configureDataSource()
        self.tableView2.register(OTRBuddyInfoCheckableCell.self, forCellReuseIdentifier: DynamicCellIdentifier.occupant.rawValue)
        //self.observeRoomOccupants()
        
        let memberLabel = UILabel(frame: CGRectMake(5, 5, 100, 30))
        memberLabel.font = UIFont(name: kFontAwesomeFont, size: 11.0)
        memberLabel.text = "     Members"
        memberLabel.textAlignment = .left
        self.tableView2.tableHeaderView = memberLabel
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.configureDataSource()
            self.observeRoomOccupants()
        }
        
        self.updateUIBasedOnOwnRole()
    }
    
    private func configureDataSource() {
        self.dataSource = RoomOccupantsSource(tableView: self.tableView2, cellProvider: { [weak self] (tableView, indexPath, occupant) ->  UITableViewCell?  in
            guard let self else { return UITableViewCell()}
            //if indexPath.section == 0 {
            //    return self.createHeaderCell(type: headerRows[indexPath.row], at: indexPath)
            //} else if indexPath.section > 1 {
            //if indexPath.section > 0 {
            //    return self.createFooterCell(type: footerRows[indexPath.row], at: indexPath)
            //}
            
            let cell:OTRBuddyInfoCheckableCell = tableView.dequeueReusableCell(withIdentifier: DynamicCellIdentifier.occupant.rawValue, for: indexPath) as! OTRBuddyInfoCheckableCell
            if let crown = self.crownImage {
                cell.setCheckImage(image: crown)
            }
            
            var buddy:ChatBuddyModel? = nil
            var accountObject:ChatAccountModel? = nil
            
            let roomOccupant = ChatRoomOccupantModel(occupant: occupant)
            guard let room = self.room,
                let account = room.accountUniqueId
                else {
                    DDLogError("Could not configure RoomOccupant cell!")
                    return cell
            }
            
            if let bud = roomOccupant.buddy() {
                buddy = ChatBuddyModel(buddy: bud)
            }
            accountObject = ChatAccountModel.getXMPPAccount(uniqueId: account)

            var isYou = false
            if let accountJid = accountObject?.bareJID?.bare,
                roomOccupant.realJID?.bare == accountJid {
                isYou = true
            }
            if let buddy = buddy {
                cell.setBuddyThread(buddy, account: nil)
                cell.accessoryView = nil
            } else if let jid = roomOccupant.realJID ?? roomOccupant.jid {
                // Create temporary buddy for anonymous room members
                let buddy = ChatBuddyModel(jid: jid, accountId: account)
                //buddy.trustLevel = .untrusted
                var status = ThreadStatus.offline
                if let jid = roomOccupant.jid,
                   BuddyCache.shared().jidOnline(jid: jid.full, room: room)  {
                    status = .available
                }
                BuddyCache.shared().setThreadStatus(status, buddyId: buddy.uniqueId, resource: roomOccupant.jid?.bare)
                cell.setBuddyThread(buddy, account: nil)
            }
            
            if isYou {
                if let accountObject = accountObject {
                    cell.avatarImageView.image = accountObject.avatarImage
                }
                cell.nameLabel.text?.append(" (" + GROUP_INFO_YOU() + ")")
            }
            
            if roomOccupant.affiliation == .owner || roomOccupant.affiliation == .admin {
                cell.setChecked(checked: true)
            } else {
                cell.setChecked(checked: false)
            }
            if roomOccupant.role == .none {
                // Not present in the room
                cell.nameLabel.textColor = UIColor.lightGray
                cell.identifierLabel.textColor = UIColor.lightGray
                cell.accountLabel.textColor = UIColor.lightGray
            }
            cell.selectionStyle = .none
            return cell
        })
        
        self.dataSource.roomId = self.roomUniqueId
        self.tableView2.dataSource = self.dataSource
    }
    
    private func updateDataSource(from occupants: [ChatRoomOccupant]) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, ChatRoomOccupant>()
        snapshot.appendSections([0])
        snapshot.appendItems(occupants, toSection: 0)
        snapshot.reloadItems(occupants)
            
        if let ds = self.dataSource {
            ds.itemCnt = snapshot.numberOfItems
            ds.apply(snapshot, animatingDifferences: false)
        }//, completion: {
            // Restore selection
            //if let index = conversations.firstIndex(where: { $0.uniqueId == convId }) {
            //    self.tableView.selectRow(at: IndexPath(row: index, section: 0), animated: false, scrollPosition: .none)
            //}
        //})
        
        self.updateUIBasedOnOwnRole()
        //self.view.setNeedsLayout()
    }
    
    private func observeRoomOccupants() {
        let request: QueryInterfaceRequest<ChatRoomOccupant>
        
        //self.roomUniqueId
        guard let roomId = self.roomUniqueId else { return }
        request = ChatRoomOccupant.all().filter(Column("roomUniqueId") == roomId)//.group(Column("realJid")) //.order(Column("realJid"))
            
        occCancellable = ValueObservation
            .tracking(request.fetchAll(_:))
            .start(
                in: DBManager.sharedDB().grdbStorage.pool,
                // Immediate scheduling feeds the data source right on subscription,
                // and avoids an undesired animation when the application starts.
                scheduling: .immediate,
                onError: { error in fatalError("Unexpected error: \(error)") },
                onChange: { [weak self] occupants in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        self.updateDataSource(from: occupants)
                    }
                })
    }
    
    func ownOccupant() -> ChatRoomOccupantModel? {
        guard let room = self.room, let accountId = room.accountUniqueId, let roomJid = room.roomJID, let ownJid = room.ourJID else { return nil }
        
        return ChatRoomOccupantModel.occupant(jid: ownJid, realJID: ownJid, roomJID: roomJid, accountId: accountId, createIfNeeded: false)
    }
    
    func updateUIBasedOnOwnRole() {
        // Update the header section
        let set = IndexSet(integer: headerSection)
        self.tableView.reloadSections(set, with: .none)
        
    }
    
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView == self.tableView2 {
            // Adjust the frame of the overscroll view
            if let topBounceView = self.topBounceView {
                let frame = CGRect(x: 0, y: 0, width: self.tableView2.frame.size.width, height: self.tableView2.contentOffset.y)
                topBounceView.frame = frame
            }
        }
    }
    
    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Store shadow and background, so we can restore them
        self.navigationBarShadow = self.navigationController?.navigationBar.shadowImage
        self.navigationBarBackground = self.navigationController?.navigationBar.backgroundImage(for: .default)
        
        // Make the navigation bar the same color as the top color of the avatar image
        self.navigationController?.navigationBar.shadowImage = UIImage()
        self.navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        if self.room != nil {
            self.navigationController?.navigationBar.barTintColor = GlobalTheme.shared.lightThemeColor;
            
            // Create a view for the bounce background, with same color as the topmost
            // avatar color.
        }
        
        self.getPins()
    }
    
    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Restore navigation bar
        self.navigationController?.navigationBar.barTintColor = UINavigationBar.appearance().barTintColor
        self.navigationController?.navigationBar.shadowImage = self.navigationBarShadow
        self.navigationController?.navigationBar.setBackgroundImage(self.navigationBarBackground, for: .default)
    }
    
    private func refreshNotificationSwitch(_ notificationsSwitch: UISwitch, room: ChatRoomModel, animated: Bool) {
        let notificationsEnabled = !room.isMuted
        notificationsSwitch.setOn(notificationsEnabled, animated: animated)
    }
    
    private func refreshNameCell() {
        if let row = headerRows.firstIndex(of: CellIdentifier.HeaderCellGroupName) {
            self.tableView.reloadRows(at: [IndexPath(row: row, section: headerSection)], with: .none)
        }
    }
    
    open func createHeaderCell(type:String, at indexPath: IndexPath) -> UITableViewCell {
        var _cell: UITableViewCell?
        if DynamicCellIdentifier(rawValue: type) != nil {
            _cell = tableView.dequeueReusableCell(withIdentifier: type, for: indexPath)
        } else {
            // storyboard cell
            _cell = tableView.dequeueReusableCell(withIdentifier: type)
        }
        guard let cell = _cell else { return UITableViewCell() }
        switch type {
        case CellIdentifier.HeaderCellGroupName:
            if let room = self.room {
                var roomname = room.roomName//room.subject //IOSM-495
                if roomname == nil {
                    roomname = room.roomJID?.user
                }
                //cell.textLabel?.text = "#" + (roomname ?? "") + " (Invite Only Group)"
                cell.textLabel?.text = (roomname ?? "") + " (Invite Only Group)"
                if room.grdbRecord?.isPublic == true {
                    cell.textLabel?.text = (roomname ?? "") + " (Open Group)"
                }
                cell.detailTextLabel?.text = "" // Do we have creation date?
            }
            
            var isOnline = false
            var canModifyName = false // changed subject to name throughout
            if let ownOccupant = ownOccupant() {
                canModifyName = ownOccupant.canModifyName()
                isOnline = ownOccupant.role != .none
            }
            if !canModifyName {
                cell.accessoryView = nil
                cell.isUserInteractionEnabled = false
            } else {
                let font:UIFont? = UIFont(name: "Material Icons", size: 24)
                let button = UIButton(type: .custom)
                if font != nil {
                    button.titleLabel?.font = font
                    button.setTitle("", for: UIControl.State())
                }
                button.setTitleColor(UIColor.label, for: UIControl.State())
                button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
                button.addTarget(self, action: #selector(self.didPressEditGroupSubject(_:withEvent:)), for: UIControl.Event.touchUpInside)
                button.titleLabel?.alpha = isOnline ? 1 :disabledCellAlphaValue
                cell.accessoryView = button
                cell.isUserInteractionEnabled = isOnline
            }
            cell.contentView.alpha = isOnline ? 1 : disabledCellAlphaValue
            cell.selectionStyle = .none
            break
        case CellIdentifier.HeaderCellAddFriends:
            cell.isUserInteractionEnabled = true
            break
        case CellIdentifier.HeaderCellPinned:
            cell.isUserInteractionEnabled = true
            break
        case CellIdentifier.HeaderCellMute:
            let muteswitch = UISwitch()
            if let room = self.room {
                refreshNotificationSwitch(muteswitch, room: room, animated:false)
            }
            muteswitch.addTarget(self, action: #selector(self.didChangeNotificationSwitch(_:)), for: .valueChanged)
            cell.accessoryView = muteswitch
            cell.isUserInteractionEnabled = true
            cell.selectionStyle = .none
            break
        default:
            break
        }
        
        // only changes group name size for some reason
        //let userFont = UIFontDescriptor.preferredFontDescriptor(withTextStyle: UIFontTextStyle.body, compatibleWith: nil)
        //let fontSize = userFont.pointSize-1
        //cell.textLabel?.font = UIFont.systemFont(ofSize: fontSize)
        
        return cell
    }
    
    //open func createFooterCell(type:String, at indexPath: IndexPath) -> UITableViewCell {
    //    return tableView.dequeueReusableCell(withIdentifier:type) ?? UITableViewCell()
    //}
    
    open func didSelectHeaderCell(type:String) {
        switch type {
        case CellIdentifier.HeaderCellAddFriends:
            addMoreFriends()
            break
        case CellIdentifier.HeaderCellPinned:
            didSelectPinnedButton()
            break
        case CellIdentifier.FooterCellLeave:
            if let room = self.room,
                let roomJid = room.roomJID,
                let xmppRoomManager = self.xmppRoomManager(for: room) {
                let hud = MBProgressHUD.showAdded(to: self.view, animated: true)
                
                let xroom = self.xmppRoom(for:room)
                var xmpp: XMPPManager? = nil
                var outaccount: ChatAccountModel? = nil
                if let account = ChatAccountModel.getXMPPAccount(uniqueId: room.threadAccountIdentifier) {
                    xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account)
                    outaccount = account
                    if let myjid = xmpp?.chatAccount.bareJID {
                        xroom?.unsubscribe(fromRoom: myjid)
                    }
                }
                
                if (xmpp != nil) {
                    if let myname = outaccount?.displayName {
                        let outmsg = "\(myname) left the group"
                        let message = room.outgoingMessage(text: outmsg)
                        xmpp?.enqueueMessage(message)
                    }
                }
                xmppRoomManager.removeRoomsFromBookmarks([room])
                
                // pause to let message go through
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    xmppRoomManager.leaveRoom(roomJid)
                    hud.removeFromSuperview()
                    if let delegate = self.delegate {
                        delegate.didLeaveRoom(self)
                    }
                }
            }
            break
        default: break
        }
    }
    
    @objc func didChangeNotificationSwitch(_ sender: UIControl!) {
        guard let notificationSwitch = sender as? UISwitch,
              let room = self.room else {
            return
        }
        if notificationSwitch.isOn {
            room.muteExpiration = nil
            if let account = ChatAccountModel.getXMPPAccount(uniqueId: room.threadAccountIdentifier), let xroom = self.xmppRoom(for:room), let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account), let myjid = xmpp.chatAccount.bareJID {
                    let mynick = xmpp.chatAccount.displayName
                    xroom.subscribe(toRoom: myjid, withNick: mynick)
            }
        } else {
            room.muteExpiration = Date.distantFuture
            if let xroom = self.xmppRoom(for:room), let account = ChatAccountModel.getXMPPAccount(uniqueId: room.threadAccountIdentifier), let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account) {
                if let myjid = xmpp.chatAccount.bareJID {
                    xroom.unsubscribe(fromRoom: myjid)
                }
            }
        }
        
        room.saveThread()
    }
    
    @objc func didPressEditGroupSubject(_ sender: UIControl!, withEvent: UIEvent!) {
        let alert = UIAlertController(title: NSLocalizedString("Change room name", comment: "Title for change room name"), message: nil, preferredStyle: UIAlertController.Style.alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "OK button"), style: UIAlertAction.Style.default, handler: {(action: UIAlertAction!) in
            if let newName = alert.textFields?.first?.text { //IOSM-495 subject to name
                self.room?.roomName = newName //subject = newSubject
                self.refreshNameCell()
                
                if let room = self.room, let xmppRoom = self.xmppRoom(for: room), let roomManager = self.xmppRoomManager(for: room) {
                    //IOSM-495 added roomManager and setRoomName
                    //xmppRoom.changeSubject(newName)
                    roomManager.setRoomName(xmppRoom, name:newName)
                }
            }
        }))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel button"), style: UIAlertAction.Style.cancel, handler: nil))
        alert.addTextField(configurationHandler: {(textField: UITextField!) in
            textField.placeholder = self.room?.roomName //subject //IOSM-495
            textField.isSecureTextEntry = false
        })
        self.present(alert, animated: true, completion: nil)
    }
    
    private func addMoreFriends() {
        guard let roomId = self.roomUniqueId else { return }
        let storyboard = UIStoryboard(name: "OTRComposeGroup", bundle: GlacierInfo.resourcesBundle)
        if let vc = storyboard.instantiateInitialViewController() as? OTRComposeGroupViewController {
            vc.delegate = self
            var existingItems = Set<String>()
            let numrows = ChatRoomOccupantModel.numberOfOccupants(for: roomId)
            for row in 0..<numrows {
                let indexPath = IndexPath(row: Int(row), section: Int(occupantsSection))
                if let cRoomOccupant = self.dataSource.itemIdentifier(for: indexPath) {
                    let roomOccupant = ChatRoomOccupantModel(occupant: cRoomOccupant)
                    if let buddy = roomOccupant.buddy() {
                        existingItems.insert(buddy.uniqueId)
                    }
                }
            }
            
            vc.setExisting(roomOccupants: existingItems, room: self.room)
            self.navigationController?.pushViewController(vc, animated: true)
        }
    }
    
    // moved from OTRMessagesViewController, and next function
    private func didSelectPinnedButton() {
        let storyboard = UIStoryboard(name: "RoomAttachments", bundle: GlacierInfo.resourcesBundle)
        if let vc = storyboard.instantiateViewController(withIdentifier: "roomAttachments") as? RoomAttachmentsViewController, let roomid = self.roomUniqueId {
            vc.setupRoom(roomKey: roomid, pinned: self.pins)
            self.navigationController?.pushViewController(vc, animated: true)
        }
    }
    
    private func getPins() {
        self.pins = nil;
        var xmpp: XMPPManager?
        var xroom: ChatRoomModel?
        if let roomid = self.roomUniqueId {
            DBManager.sharedDB().grdbStorage.asyncRead(block: { transaction in
                do {
                    if let proom = try ChatRoomModel.getXMPPRoom(uniqueId: roomid, transaction: transaction), let account = ChatAccountModel.getXMPPAccount(uniqueId: proom.threadAccountIdentifier, transaction: transaction) {
                        xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account)
                        xroom = proom
                    }
                } catch {
                    DDLogDebug("OTRRoomOccupantViewController.getPins with error: \(error)")
                }
            }, completion: {
                if let xmppmgr = xmpp, let room = xroom, let roomjid = room.roomJID, let acctjid = xmppmgr.chatAccount.bareJID {
                    xmppmgr.fileTransferManager.getAttachments(muc: roomjid, userjid: acctjid) { (pinned, error) in
                        if (pinned == nil) {
                            if let err = error {
                                DDLogError("Error getting pinned files: \(err.localizedDescription)")
                            } else {
                                DDLogError("Error getting pinned files");
                            }
                            return;
                        }
                        self.pins = pinned;
                    }
                }
            })
        }
    }

    open func grantAdmin(_ occupant:ChatRoomOccupantModel) {
        guard let room = self.room,
            let xmppRoom = self.xmppRoom(for: room),
            let occupantRealJid = occupant.realJID
            else { return }
        xmppRoom.editPrivileges([XMPPRoom.item(withAffiliation: RoomOccupantAffiliation.admin.stringValue, jid: occupantRealJid)])
    }
    
    open func revokeMembership(_ occupant:ChatRoomOccupantModel) {
        guard let room = self.room,
            let xmppRoom = self.xmppRoom(for: room),
            let occupantRealJid = occupant.realJID
            else { return }
        xmppRoom.editPrivileges([XMPPRoom.item(withAffiliation: RoomOccupantAffiliation.none.stringValue, jid: occupantRealJid)])
    }
    
    open func revokeSelfMembership(_ occupant:ChatRoomOccupantModel) {
        guard let room = self.room,
            let xmppRoom = self.xmppRoom(for: room),
            let occupantJid = occupant.jid
            else { return }
        xmppRoom.editPrivileges([XMPPRoom.item(withAffiliation: RoomOccupantAffiliation.none.stringValue, jid: occupantJid)])
    }

    open func viewOccupantInfo(_ occupant:ChatRoomOccupantModel) {
        // Show profile view?
    }
}

extension OTRRoomOccupantsViewController {
    
    /** Do not call this within a transaction! */
    fileprivate func xmppRoom(for room: ChatRoomModel) -> XMPPRoom? {
        guard let roomManager = xmppRoomManager(for: room),
            let roomJid = room.roomJID,
            let xmppRoom = roomManager.room(for: roomJid)
            else { return nil }
        return xmppRoom
    }
    
    fileprivate func xmppRoomManager(for room: ChatRoomModel) -> OTRXMPPRoomManager? {
        var xmpp: XMPPManager? = nil
        if let account = ChatAccountModel.getXMPPAccount(uniqueId: room.threadAccountIdentifier) {
            xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account)
        }
        
        return xmpp?.roomManager
    }
    
    fileprivate func fetchMembersList() {
        guard let room = self.room,
            let xmppRoom = xmppRoom(for: room) else {
            return
        }
        xmppRoom.fetchMembersList()
        xmppRoom.fetchAdminsList()
        xmppRoom.fetchOwnersList()
        xmppRoom.fetchModeratorsList()
    }
}

// MARK: - UITableViewDataSource
extension OTRRoomOccupantsViewController: UITableViewDataSource {
    public func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return headerRows.count
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        return createHeaderCell(type: headerRows[indexPath.row], at: indexPath)
    }
}


// MARK: - UITableViewDelegate
extension OTRRoomOccupantsViewController:UITableViewDelegate {
    public func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        if tableView == self.tableView {
            return GenericHeaderCell.cellHeight
        }
        
        //if indexPath.section == headerSection {
        //    return GenericHeaderCell.cellHeight
        //} else
        //if indexPath.section == footerSection {
        //    return GenericHeaderCell.cellHeight
        //}
        return OTRBuddyInfoCellHeight
    }
    
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if tableView == self.tableView {
            return GenericHeaderCell.cellHeight
        }
        
        //if indexPath.section == headerSection {
        //    return GenericHeaderCell.cellHeight
        //} else
        //if indexPath.section == footerSection {
        //    return GenericHeaderCell.cellHeight
        //}
        return OTRBuddyInfoCellHeight
    }
    
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        if tableView == self.tableView {
            didSelectHeaderCell(type: headerRows[indexPath.row])
            return
        }
        
        //if indexPath.section == headerSection {
        //    didSelectHeaderCell(type: headerRows[indexPath.row])
        //    return
        //} else
        //if indexPath.section == footerSection {
        //    didSelectFooterCell(type: footerRows[indexPath.row])
        //    return
        //}
        
        if let cRoomOccupant = self.dataSource.itemIdentifier(for: indexPath) {
            let roomOccupant = ChatRoomOccupantModel(occupant: cRoomOccupant)
            if let ownOccupant = ownOccupant(), ownOccupant.role == .moderator {
                let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
                if ownOccupant.canGrantAdmin(roomOccupant) {
                    let promoteAction = UIAlertAction(title: GROUP_GRANT_ADMIN_STRING(), style: .default, handler: { (action) in
                        self.grantAdmin(roomOccupant)
                    })
                    alert.addAction(promoteAction)
                }
                let viewAction = UIAlertAction(title: VIEW_PROFILE_STRING(), style: .default, handler: { (action) in
                    self.viewOccupantInfo(roomOccupant)
                })
                if ownOccupant.canRevokeMembership(roomOccupant) {
                    let kickAction = UIAlertAction(title: GROUP_REVOKE_MEMBERSHIP_STRING(), style: .destructive, handler: { (action) in
                        self.revokeMembership(roomOccupant)
                    })
                    alert.addAction(kickAction)
                }
                let cancelAction = UIAlertAction(title: CANCEL_STRING(), style: .cancel, handler: nil)
                alert.addAction(cancelAction)
                if let popoverController = alert.popoverPresentationController {
                    popoverController.sourceView = self.tableView2
                    popoverController.sourceRect = CGRect(x: self.tableView2.bounds.midX, y: self.tableView2.bounds.midY, width: 0, height: 0)
                    popoverController.permittedArrowDirections = []
                }
                present(alert, animated: true, completion: nil)
            } else {
                viewOccupantInfo(roomOccupant)
            }
        }
    }
}

// MARK: - OTRComposeGroupViewControllerDelegate
extension OTRRoomOccupantsViewController: OTRComposeGroupViewControllerDelegate {
    
    public func groupSelectionCancelled(_ composeViewController: OTRComposeGroupViewController) {
    }
    
    public func groupBuddiesSelected(_ composeViewController: OTRComposeGroupViewController, buddyUniqueIds: [String], groupName: String) {
        // Add them to the room
        if let room = self.room,
            let xmppRoom = self.xmppRoom(for: room),
            let xmppRoomManager = self.xmppRoomManager(for: room) {
            xmppRoomManager.inviteBuddies(buddyUniqueIds, to: xmppRoom)
            //xmppRoom.fetchMembersList() //done in invite buddies
        }
        self.navigationController?.popToViewController(self, animated: true)
    }
}

// MARK: - UITableViewDataSource
/// Subclass of UITableViewDiffableDataSource that supports row deletion
private class RoomOccupantsSource: UITableViewDiffableDataSource<Int, ChatRoomOccupant> {
    var roomId:String?
    var itemCnt = 0
    
    override public func numberOfSections(in tableView: UITableView) -> Int {
        return 1 //occupants, ...footer and header removed
    }
    
    override public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        
        //if section == headerSection {
        //    return headerRows.count
        //} else
        //if section == footerSection {
        //    return footerRows.count
        //}
        
        return itemCnt
        
    }
}
