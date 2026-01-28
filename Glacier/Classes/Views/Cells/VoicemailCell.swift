//
//  VoicemailCell.swift
//  Glacier
//
//  Created by andyfriedman on 3/3/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import UIKit

open class VoicemailCell: UITableViewCell {

    static let voicemailCellSize:CGFloat = 50.0
    static let reuseIdentifier = "VoicemailCell"
    var dateLabel: UILabel!
    var durationLabel: UILabel!
    var nameLabel: UILabel!
    var unreadImageView: UIImageView!
    var dtDurationView: UIStackView!
    var unreadImage:UIImage!
    var addedConstraints = false
    
    public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        self.unreadImage = OTRImages.circle(withRadius: 10, lineWidth: 0, lineColor: nil, fill: UIColor.bubbleBlue())
        
        self.unreadImageView = UIImageView(image: nil) 
        self.unreadImageView.translatesAutoresizingMaskIntoConstraints = false
        //self.avatarImageView.tintColor = UIColor.label
        //let cellImageLayer = self.avatarImageView.layer
        //cellImageLayer.borderWidth = 0.0
        //cellImageLayer.masksToBounds = true
        self.contentView.addSubview(self.unreadImageView)
        
        self.nameLabel = UILabel(forAutoLayout: ())
        self.nameLabel.font = UIFont.preferredFont(forTextStyle: .body)
        self.nameLabel.adjustsFontSizeToFitWidth = true
        self.contentView.addSubview(self.nameLabel)
        
        self.dateLabel = UILabel(forAutoLayout: ())
        self.dateLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        self.dateLabel.textColor = .lightGray
        self.dateLabel.adjustsFontSizeToFitWidth = true
        
        self.durationLabel = UILabel(forAutoLayout: ())
        self.durationLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        self.durationLabel.textColor = .lightGray
        self.durationLabel.adjustsFontSizeToFitWidth = true
        //self.contentView.addSubview(self.dateLabel)
        
        // Create a stack view to arrange the buttons horizontally
        dtDurationView = UIStackView(arrangedSubviews: [self.dateLabel, self.durationLabel])
        dtDurationView.axis = .vertical  // Horizontal layout
        dtDurationView.spacing = 0        // Space between buttons
        dtDurationView.alignment = .trailing // Center the buttons vertically
        dtDurationView.distribution = .equalSpacing // Equal spacing between the buttons

        // Add stack view to the main view
        dtDurationView.translatesAutoresizingMaskIntoConstraints = false
        
        //dtDurationView.addSubview(dateLabel)
        //dtDurationView.addSubview(durationLabel)
        
        self.contentView.addSubview(dtDurationView)
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    open override func updateConstraints() {
        if !self.addedConstraints {
            unreadImageView.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 20, left: 10, bottom: 20, right: 10), excludingEdge: .trailing)
            unreadImageView.autoMatch(.width, to: .height, of: unreadImageView)
            
            nameLabel.autoPinEdge(.leading, to: .trailing, of: self.unreadImageView, withOffset:5.0)
            //nameLabel.autoPinEdge(toSuperviewEdge: .trailing, withInset:OTRBuddyImageCellPadding, relation:.greaterThanOrEqual)
            nameLabel.autoPinEdge(toSuperviewEdge: .top, withInset: OTRBuddyImageCellPadding)
            nameLabel.autoPinEdge(toSuperviewEdge: .bottom, withInset: OTRBuddyImageCellPadding)
            
            dtDurationView.autoPinEdge(toSuperviewEdge: .bottom, withInset: OTRBuddyImageCellPadding)
            dtDurationView.autoPinEdge(toSuperviewEdge: .top, withInset: OTRBuddyImageCellPadding)
            dtDurationView.autoPinEdge(toSuperviewEdge: .trailing, withInset: OTRBuddyImageCellPadding)
            
            self.addedConstraints = true
        }
        
        //dateLabel.autoSetDimension(.width, toSize: 100.0, relation: .lessThanOrEqual)
        super.updateConstraints()
    }
    
    func markUnread() {
        self.unreadImageView.image = self.unreadImage
    }

    func markRead() {
        self.unreadImageView.image = nil
    }
}

