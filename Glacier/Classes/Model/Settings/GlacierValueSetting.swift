import Foundation

@objc public class GlacierValueSetting: GlacierSetting {
    @objc public private(set) var key: String
    @objc public var defaultValue: Any?

    @objc public var value: Any? {
        get { UserDefaults.standard.object(forKey: key) }
        set {
            guard let newValue else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(
                name: .glacierSettingsValueUpdated,
                object: key,
                userInfo: [key: newValue]
            )
        }
    }

    @objc public init(title: String?, description: String?, settingsKey: String) {
        self.key = settingsKey
        super.init(title: title, description: description)
    }
}
