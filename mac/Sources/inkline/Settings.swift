import Foundation

/// User-configurable settings, persisted in `UserDefaults`.
///
/// These gate *whether* the shell asks the core for a suggestion — they're all
/// OS-level decisions (is Inkline on, which app is focused, is the field secure),
/// so they live in the Swift shell rather than the Rust core (which never makes OS
/// calls). Cross-platform settings like model choice or writing instructions can
/// move into the core later.
///
/// Read on the main thread during event handling; written from the settings UI
/// (also main thread).
enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let enabled = "InklineEnabled"
        static let suppressSecure = "InklineSuppressSecureFields"
        static let disabledApps = "InklineDisabledApps"
        static let modelsDir = "InklineModelsDir"
    }

    /// User-chosen models folder, or nil to use the default (app-support). Stored
    /// as a path; `ModelManager` resolves and creates the actual directory.
    static var modelsDirectory: String? {
        get {
            let path = defaults.string(forKey: Key.modelsDir)
            return (path?.isEmpty == false) ? path : nil
        }
        set { defaults.set(newValue, forKey: Key.modelsDir) }
    }

    /// Master on/off. Absent key → enabled (opt-out, not opt-in).
    static var enabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Never read or suggest in password / secure text fields. Defaults to true.
    static var suppressSecureFields: Bool {
        get { defaults.object(forKey: Key.suppressSecure) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.suppressSecure) }
    }

    /// Bundle identifiers Inkline is turned off in.
    static var disabledApps: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.disabledApps) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.disabledApps) }
    }

    static func isAppDisabled(_ bundleID: String) -> Bool {
        disabledApps.contains(bundleID)
    }

    /// Enable/disable Inkline for a specific app (by bundle id).
    static func setApp(_ bundleID: String, enabled: Bool) {
        var apps = disabledApps
        if enabled { apps.remove(bundleID) } else { apps.insert(bundleID) }
        disabledApps = apps
    }
}
