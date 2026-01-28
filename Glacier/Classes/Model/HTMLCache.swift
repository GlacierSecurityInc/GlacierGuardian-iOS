//  Glacier
//  Created by andyfriedman on 4/5/22.
//  Copyright © 2022 Glacier. All rights reserved.
//IOSM#32

class HTMLCache: NSObject , NSDiscardableContent {

    public var image: UIImage!
    public var title: String!
    public var url: URL!

    func beginContentAccess() -> Bool {
        return true
    }

    func endContentAccess() {

    }

    func discardContentIfPossible() {

    }

    func isContentDiscarded() -> Bool {
        return false
    }
}

