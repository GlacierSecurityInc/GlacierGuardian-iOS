import Foundation
import UIKit

@objc public protocol GlacierSettingDelegate: AnyObject {
    func refreshView()
    func glacierSetting(_ setting: GlacierSetting, showDetailViewControllerClass viewControllerClass: AnyClass)
}

@objc public class GlacierSetting: NSObject {
    @objc public var title: String?
    @objc public private(set) var settingDescription: String?
    @objc public var imageName: String?
    @objc public weak var delegate: GlacierSettingDelegate?
    @objc public var actionBlock: ((Any) -> Void)?

    @objc public init(title: String?, description: String?) {
        self.title = title
        self.settingDescription = description
        super.init()
    }
}
