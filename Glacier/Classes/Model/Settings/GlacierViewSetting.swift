import UIKit

@objc public class GlacierViewSetting: GlacierSetting {
    @objc public private(set) var viewControllerClass: AnyClass?
    @objc public var accessoryType: UITableViewCell.AccessoryType = .none

    @objc public init(title: String?, description: String?, viewControllerClass: AnyClass?) {
        self.viewControllerClass = viewControllerClass
        super.init(title: title, description: description)
        actionBlock = { [weak self] _ in
            self?.showView()
        }
    }

    @objc public func showView() {
        guard let vc = viewControllerClass else { return }
        delegate?.glacierSetting(self, showDetailViewControllerClass: vc)
    }
}
