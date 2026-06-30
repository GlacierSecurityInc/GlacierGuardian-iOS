import Foundation

@objc public class GlacierBoolSetting: GlacierValueSetting {
    @objc public var enabled: Bool {
        get {
            if let stored = value as? NSNumber {
                return stored.boolValue
            }
            return (defaultValue as? NSNumber)?.boolValue ?? false
        }
        set {
            value = NSNumber(value: newValue)
        }
    }

    @objc override public init(title: String?, description: String?, settingsKey: String) {
        super.init(title: title, description: description, settingsKey: settingsKey)
        defaultValue = NSNumber(value: false)
        actionBlock = { [weak self] _ in
            self?.toggle()
        }
    }

    @objc public func toggle() {
        enabled = !enabled
    }
}
