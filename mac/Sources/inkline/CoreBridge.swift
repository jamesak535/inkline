import Foundation
import CInklineCore

/// Thin Swift wrapper over the Rust core's C-ABI.
///
/// Owns the FFI calls and nothing OS-specific. Suggestions arrive on the core's
/// worker thread and are hopped to the main thread before reaching `onSuggestion`.
final class CoreBridge {
    static let shared = CoreBridge()

    /// Called on the **main thread** when the core emits a suggestion.
    var onSuggestion: ((String) -> Void)?

    /// Monotonic id stamped on every context we send to the core and echoed back
    /// with its suggestion. Touched only on the main thread. A suggestion whose id
    /// isn't the latest was generated for context the user has already typed past,
    /// so it's dropped (M1 stale-suggestion guard).
    private(set) var lastContextSeq: UInt64 = 0

    private init() {}

    /// Register the callback and start the core's worker.
    func start() {
        inkline_init(coreSuggestionCallback)
    }

    /// Feed the latest typing context into the core: the full field text and the
    /// caret position as a UTF-8 byte offset (so the core can split it into the
    /// text before and after the caret). Each call is stamped with the next
    /// sequence id, which rides the FFI round-trip back on the suggestion so stale
    /// results can be rejected. Call on the main thread.
    func sendContext(_ text: String, caretByteOffset: Int) {
        lastContextSeq &+= 1
        let seq = lastContextSeq
        text.withCString { cstr in
            inkline_on_context(cstr, UInt(caretByteOffset), seq)
        }
    }

    /// Point the core at a GGUF model (absolute path). Loading is async in the
    /// core; suggestions switch to real inference once it's ready.
    func setModel(_ path: String) {
        path.withCString { inkline_set_model($0) }
    }

    func shutdown() {
        inkline_shutdown()
    }
}

/// Top-level C callback (no captured Swift context). Runs on the core's worker
/// thread; frees the core-owned string and forwards to the main thread.
let coreSuggestionCallback: @convention(c) (UnsafePointer<CChar>?, UInt64) -> Void = { ptr, seq in
    guard let ptr = ptr else { return }
    let suggestion = String(cString: ptr)
    inkline_free_string(UnsafeMutablePointer(mutating: ptr))
    DispatchQueue.main.async {
        // Drop suggestions generated for a context the user has already typed
        // past: only the most recently sent context's id is still current.
        guard seq == CoreBridge.shared.lastContextSeq else { return }
        CoreBridge.shared.onSuggestion?(suggestion)
    }
}
