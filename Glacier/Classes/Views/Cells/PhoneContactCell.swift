//  Glacier
//  Created by andyfriedman on 1/20/25.
//  Copyright © 2025 Glacier. All rights reserved.

import UIKit
import XLForm
import ParkedTextField

protocol PhoneContactDelegateProtocol:AnyObject {
    func smsTapped(_ contact: PhoneContact)
    func phoneTapped(_ contact: PhoneContact)
}

@objc(PhoneContactCell)
open class PhoneContactCell: OTRBuddyImageCell {

    var buttonsView: UIStackView!
    var nameLabel:UILabel!
    var accountLabel:UILabel!
    var smsBtn = UIButton(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
    var phoneBtn = UIButton(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
    var phoneContact:PhoneContact?
    var delegate: PhoneContactDelegateProtocol?
    
    public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        nameLabel = UILabel.init(forAutoLayout: ())
        nameLabel.font = UIFont.preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontSizeToFitWidth = false//true
        self.contentView.addSubview(nameLabel)
        
        accountLabel = UILabel.init(forAutoLayout: ())
        accountLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        accountLabel.textColor = .lightGray
        accountLabel.adjustsFontSizeToFitWidth = true
        self.contentView.addSubview(accountLabel)
        
        smsBtn.addTarget(self, action: #selector(smsTapped(_:)), for: .touchUpInside)
        phoneBtn.addTarget(self, action: #selector(phoneTapped(_:)), for: .touchUpInside)
        
        
        phoneBtn.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4.0, leading: 8.0, bottom: 4.0, trailing: 8.0)
        self.phoneBtn.titleLabel?.font = UIFont(name: kFontAwesomeFont, size: 22)
        self.phoneBtn.titleLabel?.textAlignment = NSTextAlignment.center
        self.phoneBtn.tintColor = .lightGray//.label
        self.phoneBtn.setTitleColor(.label, for: UIControl.State.normal)
        let phoneIconChar: UniChar = 0xf095
        self.phoneBtn.setTitle(String(format: "%C", phoneIconChar), for: .normal)
        self.phoneBtn.layer.borderWidth = 1
        self.phoneBtn.layer.borderColor = #colorLiteral(red: 0.297358036, green: 0.8514089584, blue: 0.389008224, alpha: 1).cgColor
        
        smsBtn.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4.0, leading: 8.0, bottom: 4.0, trailing: 8.0)
        self.smsBtn.titleLabel?.font = UIFont(name: kFontAwesomeFont, size: 22)
        self.smsBtn.titleLabel?.textAlignment = NSTextAlignment.center
        self.smsBtn.tintColor = .lightGray//.label
        self.smsBtn.setTitleColor(.label, for: UIControl.State.normal)
        let smsIconChar: UniChar = 0xf27a
        self.smsBtn.setTitle(String(format: "%C", smsIconChar), for: .normal)
        self.smsBtn.layer.borderWidth = 1
        self.smsBtn.layer.borderColor = UIColor.bubbleBlue().cgColor

        // Create a stack view to arrange the buttons horizontally
        buttonsView = UIStackView(arrangedSubviews: [smsBtn, phoneBtn])
        buttonsView.axis = .horizontal  // Horizontal layout
        buttonsView.spacing = 5        // Space between buttons
        buttonsView.alignment = .center // Center the buttons vertically
        buttonsView.distribution = .equalSpacing // Equal spacing between the buttons

        // Add stack view to the main view
        buttonsView.translatesAutoresizingMaskIntoConstraints = false
        
        
        self.contentView.addSubview(buttonsView)
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setContact(_ contact: PhoneContact) {
        phoneContact = contact
        self.accountLabel.text = contact.phoneNumber
        self.nameLabel.text = contact.name
        if let avatar = contact.avatar {
            self.avatarImageView.image = avatar
        }
    }
    
    @objc func smsTapped(_ sender: UIButton) {
        if let contact = self.phoneContact {
            self.delegate?.smsTapped(contact)
        }
    }
    
    @objc func phoneTapped(_ sender: UIButton) {
        if let contact = self.phoneContact {
            self.delegate?.phoneTapped(contact)
        }
    }
    
    open override func updateConstraints() {
        if self.addedConstraints {
            super.updateConstraints()
            return
        }
        
        self.avatarImageView.autoPinEdge(toSuperviewEdge: .top, withInset: OTRBuddyImageCellPadding)
        self.avatarImageView.autoPinEdge(toSuperviewEdge: .bottom, withInset: OTRBuddyImageCellPadding)
        self.avatarImageView.autoPinEdge(toSuperviewEdge: .leading, withInset: 10)
        self.avatarImageView.autoMatch(.height, to: .width, of: self.avatarImageView)
        
        nameLabel.autoPinEdge(.leading, to: .trailing, of: self.avatarImageView, withOffset: OTRBuddyImageCellPadding)
        
        accountLabel.autoPinEdge(.leading, to: .trailing, of: self.avatarImageView, withOffset: OTRBuddyImageCellPadding)
        
        nameLabel.autoPinEdge(toSuperviewEdge: .top, withInset: OTRBuddyImageCellPadding)
        nameLabel.autoPinEdge(.bottom, to: .top, of: self.accountLabel, withOffset: 0, relation: .greaterThanOrEqual)
        accountLabel.autoPinEdge(toSuperviewEdge: .bottom, withInset: OTRBuddyImageCellPadding)
        
        smsBtn.autoPinEdge(toSuperviewEdge: .top, withInset: 0.0)
        smsBtn.autoPinEdge(toSuperviewEdge: .bottom, withInset: 0.0)
        smsBtn.autoMatch(.width, to: .height, of: buttonsView)
        phoneBtn.autoPinEdge(toSuperviewEdge: .top, withInset: 0.0)
        phoneBtn.autoPinEdge(toSuperviewEdge: .bottom, withInset: 0.0)
        phoneBtn.autoMatch(.width, to: .height, of: buttonsView)
        
        buttonsView.autoPinEdge(toSuperviewEdge: .bottom, withInset: OTRBuddyImageCellPadding*1.5)
        buttonsView.autoPinEdge(toSuperviewEdge: .top, withInset: OTRBuddyImageCellPadding*1.5)
        buttonsView.autoPinEdge(toSuperviewEdge: .trailing, withInset: 7)
        
        let btnHeight = self.contentView.frame.size.height-3*OTRBuddyImageCellPadding
        let btnViewWidth = 2*btnHeight+8
        buttonsView.autoSetDimension(.width, toSize: btnViewWidth, relation: .equal)
        
        nameLabel.autoPinEdge(.trailing, to: .leading, of: buttonsView, withOffset: 0)
        accountLabel.autoPinEdge(.trailing, to: .leading, of: buttonsView, withOffset: 0)
        
        self.setConstraintsAdded()
        super.updateConstraints()
    }
    
    open override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = self.contentView.frame.size.height-3*OTRBuddyImageCellPadding
        let radius = diameter/2.0
        smsBtn.layer.cornerRadius = radius
        phoneBtn.layer.cornerRadius = radius
    }
    
    open override func prepareForReuse() {
        super.prepareForReuse()
        self.nameLabel.textColor = .label
        self.accountLabel.textColor = .lightGray
    }
}
