import Foundation

@objc public class GlacierSettingsGroup: NSObject {
    @objc public private(set) var title: String
    private var mutableSettings: [GlacierSetting]

    @objc public var settings: [GlacierSetting] {
        return mutableSettings
    }

    @objc public init(title: String, settings: [GlacierSetting]?) {
        self.title = title
        self.mutableSettings = settings ?? []
        super.init()
    }

    @objc public convenience init(title: String) {
        self.init(title: title, settings: nil)
    }

    @objc public func addSetting(_ setting: GlacierSetting) {
        mutableSettings.append(setting)
    }
}
