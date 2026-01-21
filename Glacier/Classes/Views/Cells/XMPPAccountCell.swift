//
//  XMPPAccountCell.swift
//  ChatSecure
//
//  Created by Chris Ballinger on 3/3/17.
//  Copyright © 2017 Chris Ballinger. All rights reserved.
//

import UIKit

public typealias CellButtonBlock = (_ cell: UITableViewCell, _ sender: Any) -> ()

@objc(XMPPAccountCell)
public class XMPPAccountCell: UITableViewCell {
    @IBOutlet weak var avatarButton: UIButton!
    @IBOutlet public weak var displayNameLabel: UILabel!
    @IBOutlet weak var displayNameTop: NSLayoutConstraint! //ALF IOSM-479
    
    @IBOutlet weak var userNameLabel: UILabel! //ALF IOSM-479
    
    @IBOutlet public weak var infoButton: UIButton!
    
    @objc public var infoButtonAction: CellButtonBlock?
    @objc public var avatarButtonAction: CellButtonBlock?
    
    @objc public class func cellIdentifier() -> String {
        return "XMPPAccountCell"
    }
    
    @objc public class func cellHeight() -> CGFloat {
        return 80
    }
    
    public override func awakeFromNib() {
        avatarButton.backgroundColor = nil
    }
    
    @objc public func setAppearance(buddy: ChatBuddyModel) {
        setAppearance(userInfo: buddy)
    }

    @objc public func setAppearance(account: ChatAccountModel) {
        setAppearance(userInfo: account)
    }
    
    func setAppearance(userInfo: UserInfoProfile) {
        let image = userInfo.avatarImage
        avatarButton.setImage(image, for: .normal)
        
        if let imageView = avatarButton.imageView {
            setAppearance(userInfo: userInfo, displayNameLabel: displayNameLabel, avatarImageView: imageView)
        }
    }
    
    @IBAction func infoButtonPressed(_ sender: Any) {
        guard let block = infoButtonAction else { return }
        block(self, sender)
    }
    
    @IBAction func avatarButtonPressed(_ sender: Any) {
        guard let block = avatarButtonAction else { return }
        block(self, sender)
    }
}
