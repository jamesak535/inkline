import AppKit
import CoreGraphics

/// Screen Recording (TCC) permission helpers. The OCR caret tier (`ScreenOCR`)
/// screenshots the focused field to locate the caret in apps that expose no caret
/// bounds via Accessibility (Chromium/Electron) — that capture requires the app to
/// be trusted in System Settings → Privacy & Security → Screen Recording.
///
/// Mirrors `Accessibility.swift`. Unlike Accessibility this permission is requested
/// **lazily** (the first time we actually need to OCR a field), so users who never
/// type in a browser are never asked.
enum ScreenRecording {
    /// Non-prompting check — whether screen capture is currently allowed.
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Trigger the system prompt that adds the app to the Screen Recording list.
    /// Returns the (immediate) grant state; on first call macOS shows the prompt and
    /// returns false until the user grants and the app is relaunched.
    @discardableResult
    static func requestPrompt() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Open the Screen Recording settings pane directly.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
