//  Created on 12/18/19.
//  Copyright © 2019 Glacier Security. All rights reserved.

import Foundation
import os.log

extension OSLog {
    private static var subsystem = Bundle.main.bundleIdentifier!
    public static let login = OSLog(subsystem: subsystem, category: "GlacierLogin")
}

@objc open class GlacierLog: NSObject {

    @objc public static func glog(logMsg: String, detail: String) -> Void {
        #if DEBUG
            os_log("Test: %{public}@ for %{public}@", log: .login, logMsg, detail)
        #endif
    }
}
