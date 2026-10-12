import AppKit
import ApplicationServices

/// Inserts accepted suggestion text into the focused app.
///
/// Primary path: set `kAXSelectedTextAttribute`, which replaces the (empty)
/// selection at the caret — i.e. inserts at the caret. Fallback: synthesize the
/// characters via `CGEvent` if AX injection is refused.
enum TextInjector {
    static func insert(_ text: String, into element: AXUIElement?) {
        if let element {
            let err = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            )
            if err == .success { return }
            NSLog("Inkline: AX injection failed (\(err.rawValue)); using CGEvent fallback")
        }
        postUnicode(text)
    }

    /// Type the string as a single synthetic unicode keystroke pair.
    private static func postUnicode(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)

        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.post(tap: .cgSessionEventTap)
        }
    }
}
