//
//  SecurityHubCell.swift
//  Glacier
//
//  Created by andyfriedman on 3/8/22.
//  Copyright © 2022 Glacier. All rights reserved.
//

import UIKit
import PureLayout;

//IOSM#19
@objc public class SecurityHubCell: OTRSettingTableViewCell {
    
    private var securityAlertView: UIImageView!
    private let securityAlertImage = OTRImages.circle(withRadius: 5, lineWidth: 0, lineColor: nil, fill: UIColor.bubbleBlue())
    private var addedConstraints = false
    
    public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.securityAlertView = UIImageView(image: securityAlertImage)
        self.securityAlertView.translatesAutoresizingMaskIntoConstraints = false
        self.markSecure()
        self.contentView.addSubview(securityAlertView)
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc func markInsecure() {
        self.securityAlertView.image = self.securityAlertImage;
    }

    @objc func markSecure() {
        self.securityAlertView.image = nil;
    }
    
    public override func updateConstraints()
    {
        if (!self.addedConstraints) {
            let topbottom = (self.bounds.height - 10) / 2
            self.securityAlertView.autoSetDimensions(to: CGSize(width: 10.0, height: 10.0))
            self.securityAlertView.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: topbottom, left: 2, bottom: topbottom, right: 2), excludingEdge:ALEdge.trailing)
            //self.securityAlertView.autoMatch(ALDimension.height, to: ALDimension.width, of: self.securityAlertView)
            
            self.addedConstraints = true;
        }
        
        super.updateConstraints()
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        if (!self.addedConstraints) {
            self.updateConstraints()
        }
    }
    
    @objc static func reuseIdentifier() -> String {
        return "SecurityHubCell"
    }
}
