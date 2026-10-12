import AppKit
import ApplicationServices

/// Orchestrates the macOS typing loop: wires the event tap, AX reader, core
/// bridge, and ghost-text overlay together. All state here is touched only on
/// the main thread.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let eventTap = EventTap()
    private let overlay = GhostTextOverlay()
    private var statusItem: NSStatusItem?
    private var enableMenuItem: NSMenuItem?
    private var permissionTimer: Timer?
    private var pendingRead: DispatchWorkItem?
    private var hideTimer: Timer?
    /// Whether we've already shown the Screen Recording prompt this launch (the OCR
    /// caret tier needs it; we ask lazily, once, on first need).
    private var didRequestScreenRecording = false

    /// Auto-dismiss a shown suggestion after this long with no activity, so a
    /// stale overlay never lingers on screen.
    private let suggestionTimeout: TimeInterval = 6

    // Current suggestion state.
    private var suggestionVisible = false
    private var currentSuggestion = ""
    private var currentElement: AXUIElement?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AXReader.debugEnabled { NSLog("Inkline: debug logging ON") }
        setupMainMenu()
        setupStatusItem()

        CoreBridge.shared.onSuggestion = { [weak self] suggestion in
            self?.handleSuggestion(suggestion)
        }
        CoreBridge.shared.start()

        // Load the active model (an explicit choice via run.sh/Settings, else the
        // first installed model). If there are none, the core uses the stub.
        if let modelPath = ModelManager.shared.activeModelPath() {
            NSLog("Inkline: loading model %@", modelPath)
            CoreBridge.shared.setModel(modelPath)
        }

        eventTap.onKeyDown = { [weak self] keyCode, flags in
            self?.handleKeyDown(keyCode, flags) ?? false
        }
        // A click, scroll, or app switch means the caret context likely moved —
        // the floating overlay can't follow it, so drop it.
        eventTap.onDismissCue = { [weak self] in
            self?.dismissSuggestion()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        ensureAccessibilityThenStart()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CoreBridge.shared.shutdown()
    }

    // MARK: - Permission flow

    private func ensureAccessibilityThenStart() {
        if Accessibility.isTrusted {
            startTypingLoop()
            return
        }

        Accessibility.requestPrompt()
        updateStatusTitle(granted: false)

        // Poll until the user grants permission, then start.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard Accessibility.isTrusted else { return }
            timer.invalidate()
            self?.permissionTimer = nil
            self?.startTypingLoop()
        }
    }

    private func startTypingLoop() {
        updateStatusTitle(granted: true)
        // Enable AX on the app that's already frontmost (later switches are handled
        // by activeAppChanged) so a browser focused at launch exposes its inputs.
        if let front = NSWorkspace.shared.frontmostApplication {
            Self.enableAccessibility(for: front)
        }
        if eventTap.start() {
            NSLog("Inkline: event tap active — type in TextEdit to see suggestions.")
        } else {
            NSLog("Inkline: failed to create event tap despite being trusted.")
        }
    }

    // MARK: - Keystroke handling (main thread)

    /// Returns true to consume the keystroke.
    private func handleKeyDown(_ keyCode: CGKeyCode, _ flags: CGEventFlags) -> Bool {
        let hasCommandOrControl = flags.contains(.maskCommand) || flags.contains(.maskControl)

        if suggestionVisible && !hasCommandOrControl {
            // Tab: accept the next word (completing the current word if the caret
            // is mid-word), revealing the rest of the suggestion to keep tabbing.
            if keyCode == KeyCode.tab {
                acceptWord()
                return true // swallow the Tab
            }
            // ` (backtick): accept the entire remaining suggestion at once.
            if keyCode == KeyCode.backtick {
                acceptRest()
                return true
            }
            if keyCode == KeyCode.escape {
                dismissSuggestion()
                return true
            }
        }

        // Any other key invalidates the shown suggestion and (for normal typing)
        // schedules a fresh context read once the keystroke has landed.
        dismissSuggestion()
        if !hasCommandOrControl {
            scheduleContextRead()
        }
        return false
    }

    /// Read the focused text just after the keystroke is applied (the core
    /// debounces, so exact timing isn't critical) and feed it to the core.
    private func scheduleContextRead() {
        pendingRead?.cancel()
        // Honor the settings gates before doing any AX work: global toggle, then
        // our own UI, then per-app, then secure fields (once we have the element).
        guard Settings.enabled else { return }
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontBundle == Bundle.main.bundleIdentifier { return } // never act on our own windows
        if let bundleID = frontBundle, Settings.isAppDisabled(bundleID) { return }
        let work = DispatchWorkItem {
            guard let ctx = AXReader.readContext(), !ctx.prefix.isEmpty else { return }
            if ctx.isSecure && Settings.suppressSecureFields { return }
            // Send the full text + caret byte offset; the core slices prefix/suffix.
            // prefix.utf8.count is the caret's byte offset within the full value.
            CoreBridge.shared.sendContext(ctx.value, caretByteOffset: ctx.prefix.utf8.count)
        }
        pendingRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012, execute: work)
    }

    // MARK: - Suggestion handling (main thread)

    private func handleSuggestion(_ suggestion: String) {
        guard !suggestion.isEmpty, suggestion != "…" else { return }
        // Re-read the live caret + field bounds so the overlay lands right and
        // wraps within the field instead of running off the edge.
        guard let ctx = AXReader.readContext() else {
            debugLog("handleSuggestion: no context on re-read — dropping")
            return
        }
        let geometry = AXReader.caretGeometry(for: ctx.element, caretLocation: ctx.caretLocation)

        // Fast path: exact AX caret bounds (native apps, AX-friendly Safari sites).
        if let geometry, geometry.source == .exact {
            showSuggestion(suggestion, geometry: geometry, element: ctx.element)
            return
        }
        // Otherwise our only choices are the font estimate (which drifts as the line
        // grows) and OCR (true pixels). Prefer OCR when Screen Recording is granted,
        // falling back to the estimate (`geometry`, possibly nil) if it isn't or OCR
        // fails. This is the Chromium/web-input path (§7b/§11).
        tryOCRPlacement(suggestion: suggestion, ctx: ctx, fallback: geometry)
    }

    /// Place the overlay using an already-resolved caret geometry. Factored out so
    /// both the sync AX path and the async OCR path share the same show + state.
    private func showSuggestion(_ suggestion: String, geometry: AXReader.CaretGeometry, element: AXUIElement) {
        debugLog("handleSuggestion: showing \(suggestion.count) chars at \(NSStringFromRect(geometry.caret))")
        currentSuggestion = suggestion
        currentElement = element
        overlay.show(text: suggestion, caret: geometry.caret, field: geometry.field, font: geometry.font)
        suggestionVisible = true
        restartHideTimer()
    }

    /// OCR caret-placement for apps with no exact AX caret bounds. Async (capture +
    /// Vision), so we re-validate on completion that the caret hasn't moved before
    /// showing — mirrors the M1 stale-suggestion guard. `fallback` is the font
    /// estimate (or nil): used when Screen Recording is off or OCR fails.
    private func tryOCRPlacement(suggestion: String, ctx: EditContext, fallback: AXReader.CaretGeometry?) {
        guard ScreenRecording.isGranted, let fieldTopLeft = AXReader.fieldFrameTopLeft(ctx.element) else {
            if !ScreenRecording.isGranted { requestScreenRecordingOnce() }
            // No OCR available — fall back to the (drifty) estimate, or drop.
            if let fallback {
                showSuggestion(suggestion, geometry: fallback, element: ctx.element)
            } else {
                debugLog("handleSuggestion: no exact geometry, no OCR, no estimate — dropping")
            }
            return
        }
        let expectedCaret = ctx.caretLocation
        let element = ctx.element
        ScreenOCR.locateCaret(
            element: element, value: ctx.value, caretLocation: ctx.caretLocation, fieldTopLeft: fieldTopLeft
        ) { [weak self] geometry in
            guard let self else { return }
            // OCR if it succeeded, else the estimate fallback.
            guard let resolved = geometry ?? fallback else {
                self.debugLog("handleSuggestion: OCR failed and no estimate — dropping")
                return
            }
            // The OCR round-trip took time; only show if the caret is still where it
            // was when we captured (else the suggestion + placement are both stale).
            guard let live = AXReader.readContext(),
                  CFEqual(live.element, element), live.caretLocation == expectedCaret else {
                self.debugLog("handleSuggestion: caret moved during OCR — dropping")
                return
            }
            self.showSuggestion(suggestion, geometry: resolved, element: element)
        }
    }

    /// Ask for Screen Recording once per launch (lazily, on first OCR need) so we
    /// never nag users who don't type in browsers.
    private func requestScreenRecordingOnce() {
        guard !didRequestScreenRecording else { return }
        didRequestScreenRecording = true
        ScreenRecording.requestPrompt()
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        if AXReader.debugEnabled { NSLog("Inkline: %@", message()) }
    }

    /// Accept just the next word of the suggestion (the leading whitespace plus
    /// the first word run — which completes the current word when the caret is
    /// mid-word), then keep showing the remainder so the user can tab onward.
    private func acceptWord() {
        guard suggestionVisible, !currentSuggestion.isEmpty else { return }
        let (head, rest) = Self.splitLeadingWord(currentSuggestion)
        guard !head.isEmpty else { dismissSuggestion(); return }

        let previousCaret = AXReader.readContext()?.caretLocation
        TextInjector.insert(head, into: currentElement)

        // Nothing meaningful left → done.
        if rest.allSatisfy(\.isWhitespace) {
            dismissSuggestion()
            return
        }
        currentSuggestion = rest
        reanchorRemainder(previousCaretLocation: previousCaret, acceptedHead: head)
    }

    /// Accept the entire remaining suggestion at once.
    private func acceptRest() {
        guard suggestionVisible, !currentSuggestion.isEmpty else { return }
        TextInjector.insert(currentSuggestion, into: currentElement)
        dismissSuggestion()
        // The inserted text becomes new context for the next prediction.
        scheduleContextRead()
    }

    /// Re-position the overlay over the *remaining* suggestion after accepting a
    /// word. Prefer the real post-injection caret; if the app's Accessibility
    /// state hasn't updated yet, eagerly shift the overlay by the inserted width.
    private func reanchorRemainder(previousCaretLocation: Int?, acceptedHead: String) {
        if let ctx = AXReader.readContext(),
           let geometry = AXReader.caretGeometry(for: ctx.element, caretLocation: ctx.caretLocation),
           previousCaretLocation == nil || ctx.caretLocation != previousCaretLocation {
            currentElement = ctx.element
            overlay.show(text: currentSuggestion, caret: geometry.caret, field: geometry.field, font: geometry.font)
        } else {
            overlay.advance(remaining: currentSuggestion, acceptedWidthOf: acceptedHead)
        }
        suggestionVisible = true
        restartHideTimer()
    }

    /// Split off the leading whitespace + first word; the rest is the remainder.
    static func splitLeadingWord(_ s: String) -> (head: String, rest: String) {
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isWhitespace { idx = s.index(after: idx) }
        while idx < s.endIndex, !s[idx].isWhitespace { idx = s.index(after: idx) }
        return (String(s[..<idx]), String(s[idx...]))
    }

    private func restartHideTimer() {
        // Safety net: never let the overlay linger if nothing else dismisses it.
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: suggestionTimeout, repeats: false) { [weak self] _ in
            self?.dismissSuggestion()
        }
    }

    private func dismissSuggestion() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard suggestionVisible else { return }
        suggestionVisible = false
        currentSuggestion = ""
        currentElement = nil
        overlay.hide()
    }

    @objc private func activeAppChanged(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            Self.enableAccessibility(for: app)
        }
        dismissSuggestion()
    }

    /// Ask an app to expose its accessibility tree. Chromium-based browsers and
    /// Electron apps build their AX tree lazily and only when a client requests it
    /// via the `AXManualAccessibility` attribute; without this they expose no
    /// editable text (so Inkline can't read web inputs). Harmless on apps that
    /// don't support it (e.g. native Cocoa apps ignore it).
    static func enableAccessibility(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0 else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "✎"
        let menu = NSMenu()
        menu.delegate = self // refresh the Enable checkmark each time the menu opens
        let status = NSMenuItem(title: "Inkline", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let enable = NSMenuItem(title: "Enable Inkline", action: #selector(toggleEnabled), keyEquivalent: "")
        enable.state = Settings.enabled ? .on : .off
        menu.addItem(enable)
        self.enableMenuItem = enable

        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Open Accessibility Settings…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Open Screen Recording Settings…",
            action: #selector(openScreenRecordingSettings),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Inkline", action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        self.statusItem = item
    }

    /// Keep the Enable checkmark in sync (it may have been toggled from Settings).
    func menuWillOpen(_ menu: NSMenu) {
        enableMenuItem?.state = Settings.enabled ? .on : .off
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        enableMenuItem?.state = Settings.enabled ? .on : .off
        if !Settings.enabled { dismissSuggestion() }
    }

    @objc private func openSettings() {
        SettingsController.shared.show()
    }

    /// A minimal main menu so standard editing shortcuts (⌘X/⌘C/⌘V/⌘A, undo) work
    /// in our windows. An accessory app has no menu bar by default, so without this
    /// the Settings WebView's text fields can't even paste. The menu isn't shown
    /// (we stay `.accessory`); only its key equivalents are used, routed to the
    /// first responder.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = mainMenu
    }

    private func updateStatusTitle(granted: Bool) {
        statusItem?.button?.title = granted ? "✎" : "✎⚠"
    }

    @objc private func openAccessibilitySettings() {
        Accessibility.openSettings()
    }

    /// Screen Recording powers the OCR caret tier (ghost text in Chromium/Electron
    /// apps that expose no caret bounds via Accessibility — §7b/§11).
    @objc private func openScreenRecordingSettings() {
        ScreenRecording.openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
