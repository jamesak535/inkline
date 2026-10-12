import AppKit
import ApplicationServices

/// Accessibility (TCC) permission helpers. Event taps and AX reads require the
/// app to be trusted in System Settings → Privacy & Security → Accessibility.
enum Accessibility {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Trigger the system prompt that adds the app to the Accessibility list.
    static func requestPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Open the Accessibility settings pane directly.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
