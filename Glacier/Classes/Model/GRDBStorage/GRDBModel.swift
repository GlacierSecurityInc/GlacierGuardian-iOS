//  Glacier
//  Created by andyfriedman on 8/22/23.
//  Copyright © 2023 Glacier. All rights reserved.

import Foundation

@objc open class GRDBModel: NSObject {
    
    @objc let uniqueId: String
    var grdbId: NSNumber?
    
    public override init() {
        self.uniqueId = UUID().uuidString
    }
    
    public init(uniqueId: String) {
        self.uniqueId = uniqueId
    }
    
    
    @objc static func collection() -> String {
        return NSStringFromClass(self)
    }
    
}
