//  NumPadLBTA
//  Created by Brian Voong on 3/20/19.
//  Copyright © 2019 Brian Voong. All rights reserved.

import UIKit

class BackspaceCell: UICollectionViewCell {

    let imageView = UIImageView(image: UIImage(named: "phone_backspace", in: GlacierInfo.resourcesBundle, compatibleWith: nil))
    
    fileprivate let defaultBGColor = UIColor.systemGray4
    fileprivate let highlightColor = UIColor.systemGray
    
    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? highlightColor : nil
        }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
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
