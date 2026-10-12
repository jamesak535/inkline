import AppKit

// Inkline macOS shell — Phase 2.
//
// A menu-bar (accessory) app that watches typing system-wide via a CGEventTap,
// reads the focused text + caret via Accessibility, feeds context to the Rust
// core, and renders the returned suggestion as ghost text at the caret.
// Tab accepts, Esc dismisses.

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
// Accessory: no Dock icon, lives in the menu bar; never steals focus.
app.setActivationPolicy(.accessory)
app.run()
