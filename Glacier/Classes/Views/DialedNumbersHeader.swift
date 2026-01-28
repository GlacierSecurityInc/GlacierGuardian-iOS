//  NumPadLBTA
//  Created by Brian Voong on 3/20/19.
//  Copyright © 2019 Brian Voong. All rights reserved.

import UIKit

class DialedNumbersHeader: UICollectionReusableView {

    let numbersLabel = UILabel()
    var tapHandler: (() -> Void)?

    private lazy var tapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        return gesture
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        numbersLabel.text = "123"
        numbersLabel.font = UIFont.systemFont(ofSize: 32)
        numbersLabel.textAlignment = .center
        numbersLabel.adjustsFontSizeToFitWidth = true
        numbersLabel.isUserInteractionEnabled = true
        numbersLabel.addGestureRecognizer(tapGesture)
        addSubview(numbersLabel)
        numbersLabel.fillSuperview(padding: .init(top: 0, left: 32, bottom: 0, right: 32))
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tapHandler = nil
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        tapHandler?()
    }

}
