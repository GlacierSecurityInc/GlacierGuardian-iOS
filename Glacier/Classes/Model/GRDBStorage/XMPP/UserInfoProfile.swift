//  Glacier
//  Created by andyfriedman on 10/6/23.
//  Copyright © 2023 Glacier. All rights reserved.

import Foundation

@objc public protocol UserInfoProfile: AnyObject {
    var displayName: String { get set }
    var username: String { get set }
#if !TARGET_IS_EXTENSION
    var avatarImage: UIImage { get }
    var avatarBorderColor: UIColor? { get }
#endif
}
