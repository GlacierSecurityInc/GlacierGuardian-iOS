//
//  BackspaceCell.swift
//  NumPadLBTA
//
//  Created by Brian Voong on 3/20/19.
//  Copyright © 2019 Brian Voong. All rights reserved.
//

import UIKit

class BackspaceCell: UICollectionViewCell {

    let imageView = UIImageView(image: UIImage(named: "phone_backspace", in: GlacierInfo.resourcesBundle, compatibleWith: nil))
    
    fileprivate let defaultBGColor = UIColor.systemGray4//UIColor(white: 0.9, alpha: 1)
    fileprivate let highlightColor = UIColor.systemGray//UIColor(white: 0.9, alpha: 1)
    
    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? highlightColor : nil
        }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        //backgroundColor = defaultBGColor
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        imageView.centerInSuperview(size: .init(width: 40, height: 40))
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = frame.width / 2
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError()
    }
    
}
