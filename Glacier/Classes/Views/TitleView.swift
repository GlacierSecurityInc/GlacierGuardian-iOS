//
//  TitleView.swift
//  Glacier
//
//  Created by andyfriedman on 6/29/22.
//  Copyright © 2022 Glacier. All rights reserved.
//

import UIKit
import PureLayout

@objc public class TitleView: UIView {
    @objc var titleLabel : UILabel!
    @objc var titleConnectingView : UIActivityIndicatorView!
    @objc var addedConstraints = false
    static let kMaxImageViewHeight = 6.0
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        
        self.backgroundColor = UIColor.clear
        self.autoresizesSubviews = true
        
        self.titleLabel = UILabel(forAutoLayout: ())
        self.titleLabel.backgroundColor = UIColor.clear
        self.titleLabel.textAlignment = NSTextAlignment.center
        self.titleLabel.adjustsFontSizeToFitWidth = true
        self.titleLabel.textColor = UIColor.label
        
        self.titleLabel.adjustsFontForContentSizeCategory = true
        self.titleLabel.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: UIFont.boldSystemFont(ofSize: 19.0))
        self.titleConnectingView = UIActivityIndicatorView(forAutoLayout: ())
        
        self.addSubview(self.titleConnectingView)
        self.addSubview(self.titleLabel)
        
        self.setNeedsUpdateConstraints()
    }
    
    @available(*, unavailable, message:"use other constructor instead.")
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func updateConstraints()
    {
        if (!self.addedConstraints) {
            self.autoPinEdgesToSuperviewEdges()
            self.autoAlignAxis(toSuperviewAxis: ALAxis.horizontal)
            self.autoAlignAxis(toSuperviewAxis: ALAxis.vertical)
            
            self.titleLabel.autoPinEdge(ALEdge.bottom, to: ALEdge.bottom, of: self)
            self.titleLabel.autoPinEdge(ALEdge.top, to: ALEdge.top, of: self)
            self.titleLabel.autoMatch(ALDimension.height, to:ALDimension.height, of: self)
            
            self.titleConnectingView.autoPinEdge(ALEdge.trailing, to: ALEdge.leading, of: self.titleLabel, withOffset: -4.0)
            self.titleConnectingView.autoAlignAxis(toSuperviewAxis: ALAxis.horizontal)
            
            self.addedConstraints = true
        }
        
        super.updateConstraints()
    }
}
