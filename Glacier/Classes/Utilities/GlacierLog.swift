//
//  GlacierLog.swift
//  Created on 12/18/19.
//  Copyright © 2019 Glacier Security. All rights reserved.

import Foundation
import os.log
//import Sentry

/*enum BC {
    static func info(
        _ category: String,
        _ message: String,
        data: [String: Any]? = nil
    ) {
        let crumb = Breadcrumb()
        crumb.level = .info
        crumb.category = category
        crumb.message = message
        if let data {
            crumb.data = data
        }
        NSLog("*****DBG %@", message)
        SentrySDK.addBreadcrumb(crumb)
    }
}*/

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
