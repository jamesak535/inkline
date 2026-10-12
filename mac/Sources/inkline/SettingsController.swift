import AppKit
import WebKit

/// The Settings window: an `NSWindow` hosting a `WKWebView` whose HTML/JS UI talks
/// to Swift over a script-message bridge. The web layer is pure presentation and
/// is the **shared, cross-platform** UI (`ui/settings.html`) — the Windows shell
/// will host the same file in WebView2. All state lives in `Settings`
/// (UserDefaults); the Rust core is not involved.
///
/// A singleton (lives for the app's lifetime), which also sidesteps the
/// `WKUserContentController` → handler retain cycle.
final class SettingsController: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    static let shared = SettingsController()

    private var window: NSWindow?
    private var webView: WKWebView?

    private override init() { super.init() }

    /// Show (building lazily on first use) and focus the Settings window. Inkline
    /// is an accessory app, so we activate explicitly to bring the window forward.
    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        // Relay model download progress/completion (main thread) to the web UI.
        ModelManager.shared.onProgress = { [weak self] name, received, total in
            self?.evalJS("window.inklineDownloadProgress", [
                "name": name, "received": received, "total": total, "done": false,
            ])
        }
        ModelManager.shared.onFinished = { [weak self] name, error, cancelled in
            // Auto-activate the download if nothing is active yet (first model).
            if !cancelled, error == nil {
                let dest = ModelManager.shared.modelsDir.appendingPathComponent(name).path
                if !ModelManager.shared.installed().contains(where: { $0.active }) {
                    ModelManager.shared.activate(dest)
                }
            }
            self?.evalJS("window.inklineDownloadProgress", [
                "name": name, "done": true, "error": error as Any, "cancelled": cancelled,
            ])
            self?.pushModels()
        }

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "inkline")

        let frame = NSRect(x: 0, y: 0, width: 520, height: 580)
        let web = WKWebView(frame: frame, configuration: config)
        // Load the SHARED settings UI bundled at Contents/Resources/settings.html
        // (copied there by run.sh). The same file is what the Windows shell will
        // host in WebView2 — don't fork it. `loadFileURL` (not an embedded string)
        // keeps the door open for splitting out css/js as sibling files later.
        if let url = Bundle.main.url(forResource: "settings", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.loadHTMLString(
                "<body style='font:13px -apple-system;padding:24px'>settings.html not found in bundle.</body>",
                baseURL: nil
            )
        }
        self.webView = web

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Inkline Settings"
        win.contentView = web
        win.isReleasedWhenClosed = false // reuse across opens
        win.center()
        win.delegate = self
        self.window = win
    }

    // MARK: - JS → Swift

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            pushState()
            pushModels()
        case "setEnabled":
            if let value = body["value"] as? Bool { Settings.enabled = value }
        case "setSuppressSecure":
            if let value = body["value"] as? Bool { Settings.suppressSecureFields = value }
        case "setAppEnabled":
            if let bundleID = body["bundleId"] as? String, let value = body["value"] as? Bool {
                Settings.setApp(bundleID, enabled: value)
            }
        case "selectModel":
            if let path = body["path"] as? String {
                ModelManager.shared.activate(path)
                pushModels()
            }
        case "downloadModel":
            if let url = body["url"] as? String {
                if ModelManager.shared.startDownload(url) == nil {
                    evalJS("window.inklineDownloadProgress", [
                        "done": true, "cancelled": false,
                        "error": "Invalid URL, not a .gguf, or a download is already running.",
                    ])
                }
            }
        case "cancelDownload":
            ModelManager.shared.cancelDownload()
        case "chooseModelsFolder":
            chooseModelsFolder()
        default:
            break
        }
    }

    /// Open a folder picker for the models directory; persist + refresh on choose.
    private func chooseModelsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for Inkline models"
        panel.directoryURL = ModelManager.shared.modelsDir
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Settings.modelsDirectory = url.path
            pushModels()
        }
    }

    // MARK: - Swift → JS

    /// Call `function(arg)` in the page with `arg` JSON-encoded.
    private func evalJS(_ function: String, _ arg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: arg),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("\(function)(\(json));", completionHandler: nil)
    }

    /// Push the full settings snapshot to the page (renders the controls + app list).
    private func pushState() {
        evalJS("window.inklineSetState", [
            "enabled": Settings.enabled,
            "suppressSecure": Settings.suppressSecureFields,
            "apps": currentApps().map {
                ["bundleId": $0.bundleID, "name": $0.name, "enabled": !Settings.isAppDisabled($0.bundleID)]
            },
        ])
    }

    /// Push the installed-models list (with the active one marked) + the folder.
    private func pushModels() {
        evalJS("window.inklineSetModels", [
            "dir": ModelManager.shared.modelsDir.path,
            "models": ModelManager.shared.installed().map {
                ["name": $0.name, "path": $0.path, "size": $0.size, "active": $0.active] as [String: Any]
            },
        ])
    }

    private struct AppInfo { let bundleID: String; let name: String }

    /// Running regular (UI) apps, plus any disabled apps that aren't running, so
    /// the user can always re-enable one. Sorted by display name.
    private func currentApps() -> [AppInfo] {
        var seen = Set<String>()
        var apps: [AppInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty, seen.insert(bundleID).inserted else {
                continue
            }
            apps.append(AppInfo(bundleID: bundleID, name: app.localizedName ?? bundleID))
        }
        for bundleID in Settings.disabledApps where seen.insert(bundleID).inserted {
            apps.append(AppInfo(bundleID: bundleID, name: bundleID))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
