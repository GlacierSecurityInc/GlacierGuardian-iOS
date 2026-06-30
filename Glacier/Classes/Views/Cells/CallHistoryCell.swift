//
//  CallHistoryCell.swift
//  Glacier
//
//  Created by andyfriedman on 1/22/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import UIKit
//import XLForm
//import ParkedTextField

open class CallHistoryCell: UITableViewCell {

    static let historyCellSize:CGFloat = 70.0
    static let reuseIdentifier = "CallHistoryCell"
    var dateLabel: UILabel!
    var nameLabel: UILabel!
    var avatarImageView: UIImageView!
    var addedConstraints = false
    
    public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        self.avatarImageView = UIImageView(image: UIImage(named: "call_status_outgoing", in: GlacierInfo.resourcesBundle, with: nil))
        self.avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        let cellImageLayer = self.avatarImageView.layer
        cellImageLayer.borderWidth = 0.0
        cellImageLayer.masksToBounds = true
        self.contentView.addSubview(self.avatarImageView)
        
        self.nameLabel = UILabel(forAutoLayout: ())
        self.nameLabel.font = UIFont.preferredFont(forTextStyle: .body)
        self.nameLabel.adjustsFontSizeToFitWidth = true
        self.contentView.addSubview(self.nameLabel)
        
        self.dateLabel = UILabel(forAutoLayout: ())
        self.dateLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        self.dateLabel.textColor = .lightGray
        self.dateLabel.adjustsFontSizeToFitWidth = true
        self.contentView.addSubview(self.dateLabel)
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    open override func updateConstraints() {
        if !self.addedConstraints {
            avatarImageView.autoPinEdge(toSuperviewEdge: .top, withInset: BuddyImageCellPadding)
            avatarImageView.autoPinEdge(toSuperviewEdge: .leading, withInset: BuddyImageCellPadding)
            avatarImageView.autoSetDimension(.height, toSize: 35)
            avatarImageView.autoSetDimension(.width, toSize: 35)
            
            nameLabel.autoPinEdge(.leading, to: .trailing, of: self.avatarImageView, withOffset:BuddyImageCellPadding)
            nameLabel.autoPinEdge(.top, to: .top, of: self.avatarImageView, withOffset:0)
            nameLabel.autoPinEdge(toSuperviewEdge: .trailing, withInset: BuddyImageCellPadding)
            
            dateLabel.autoPinEdge(.leading, to: .leading, of: self.nameLabel, withOffset:0)
            dateLabel.autoPinEdge(.top, to: .bottom, of: self.nameLabel, withOffset:8)
            dateLabel.autoPinEdge(toSuperviewEdge: .trailing, withInset: BuddyImageCellPadding)
            
            self.addedConstraints = true
        }
        
        super.updateConstraints()
    }
}

