//
//  ComposeGroupBuddyCell.swift
//  ChatSecure
//
//  Created by N-Pex on 2017-08-15.
//  Copyright © 2017 Chris Ballinger. All rights reserved.
//

import UIKit

public protocol ComposeGroupBuddyCellDelegate {
    func didRemoveBuddy(_ buddy:ChatBuddy)
}

open class ComposeGroupBuddyCell: UICollectionViewCell {
    @IBOutlet open weak var image:UIImageView!
    @IBOutlet open weak var label:UILabel!
    @IBOutlet open weak var closeButton:UIButton!
    
    public var delegate:ComposeGroupBuddyCellDelegate?
    var buddy:ChatBuddy?
    
    func bind(buddy:ChatBuddy) {
        self.buddy = buddy
        let cornerRadius = image.frame.height/2
        self.layer.cornerRadius = cornerRadius
        self.clipsToBounds = true
        image.layer.cornerRadius = cornerRadius
        image.clipsToBounds = true
        
        label.text = buddy.displayName
        let budModel = ChatBuddyModel(buddy: buddy)
        image.image = budModel.avatarImage
        updateShadow()
    }
    
    @IBAction func didPressCloseButton(_ sender: Any) {
        if let delegate = self.delegate, let buddy = self.buddy {
            delegate.didRemoveBuddy(buddy)
        }
    }
    
    private func updateShadow() {
        let shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: image.frame.height/2)
        layer.masksToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0.0, height: 2.0)
        layer.shadowOpacity = 0.2
        layer.shadowPath = shadowPath.cgPath
    }
    
    override open func layoutSubviews()
    {
        super.layoutSubviews()
        updateShadow()
    }
    
    static func reuseIdentifier() -> String {
        return "ComposeGroupBuddyCell"
    }
}
