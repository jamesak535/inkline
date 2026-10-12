//! Inkline core — the cross-platform "brain".
//!
//! This crate owns everything that is *not* an OS call: debounce/timing, prompt
//! building, suggestion generation (a stub in Phase 1; real local inference in
//! Phase 3), and the C-ABI FFI boundary the native shells (Swift / C#) talk to.
//!
//! ## FFI contract
//! - Events flow **in** as simple calls (`inkline_on_context`).
//! - Suggestions flow **out** via a registered C callback function pointer — no
//!   async/await crosses the boundary.
//! - Strings are UTF-8 `char*`. Strings handed to the callback are **allocated by
//!   the core** and must be released by the caller with `inkline_free_string`.
//! - The core must NEVER make OS UI/accessibility calls — that is the shell's job.

mod inference;
mod overlap;
mod prompt;
mod stub;

use inference::Engine;
use std::ffi::{c_char, CStr, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::Duration;

/// How long to wait for typing to settle before generating a suggestion.
const DEBOUNCE: Duration = Duration::from_millis(100);

/// Callback the shell registers to receive suggestions.
///
/// The `suggestion` pointer is a NUL-terminated UTF-8 string **owned by the
/// caller after this call returns**: release it with [`inkline_free_string`].
/// `seq` echoes the sequence id of the [`inkline_on_context`] call this
/// suggestion was generated from, so the shell can drop it if the user has since
/// typed past that context (stale-suggestion guard).
/// Invoked on the core's internal worker thread — the shell is responsible for
/// hopping to its UI thread if needed.
pub type SuggestionCallback = extern "C" fn(suggestion: *const c_char, seq: u64);

/// Commands sent from FFI calls to the debounce/worker thread.
enum Cmd {
    Context { text: String, cursor_pos: usize, seq: u64 },
    Shutdown,
}

/// Channel to the worker thread. `None` until `inkline_init` is called.
static SENDER: OnceLock<Mutex<Option<Sender<Cmd>>>> = OnceLock::new();

/// Lock the sender, recovering from poisoning rather than aborting the process.
/// The guarded data is just an `Option<Sender>`, so a poisoned lock is harmless.
fn lock_sender() -> MutexGuard<'static, Option<Sender<Cmd>>> {
    SENDER
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// The local inference engine (llama-server subprocess + HTTP client). The
/// engine is internally lock-free (a manager thread + atomics), so it can be
/// shared by `&` with no mutex here.
static ENGINE: OnceLock<Engine> = OnceLock::new();

fn engine() -> &'static Engine {
    ENGINE.get_or_init(Engine::new)
}

/// Set once a model has been requested via `inkline_set_model`, so we stop
/// emitting stub completions and use only real inference (which yields no
/// suggestion until the model finishes loading).
static MODEL_REQUESTED: AtomicBool = AtomicBool::new(false);

/// Produce a suggestion for the given context: real inference once a model is
/// requested, otherwise the canned stub (so the app demos before a model loads).
// v1
// fn generate(text: &str, cursor_pos: usize) -> Option<String> {
//     if MODEL_REQUESTED.load(Ordering::Acquire) {
//         // Non-blocking: returns None until the model is ready.
//         return engine().complete(text);
//     }
//     Some(stub::complete(text, cursor_pos))
// }
// v2
fn generate(text: &str, cursor_pos: usize) -> Option<String> {
    if MODEL_REQUESTED.load(Ordering::Acquire) {
        let (prefix, suffix) = split_at_caret(text, cursor_pos);
        if prefix.is_empty() {
            return None;
        }
        // The engine continues from the prefix; `suffix` is passed for the
        // upcoming prompt builder (after-caret context), not yet used.
        return engine().complete(prefix, suffix);
    }
    Some(stub::complete(text, cursor_pos))
}

/// Split `text` into (before-caret, after-caret) at `cursor_pos` (a UTF-8 byte
/// offset), clamped down to the nearest char boundary.
fn split_at_caret(text: &str, cursor_pos: usize) -> (&str, &str) {
    let mut idx = cursor_pos.min(text.len());
    while idx > 0 && !text.is_char_boundary(idx) {
        idx -= 1;
    }
    text.split_at(idx)
}


/// The debounce loop: collapse a burst of context updates into a single
/// suggestion once typing goes quiet for [`DEBOUNCE`].
fn worker(rx: Receiver<Cmd>, callback: SuggestionCallback) {
    loop {
        // Block until the first context update of a burst arrives.
        let mut pending = match rx.recv() {
            Ok(Cmd::Context { text, cursor_pos, seq }) => (text, cursor_pos, seq),
            Ok(Cmd::Shutdown) | Err(_) => return,
        };

        // Keep absorbing updates until the user pauses for DEBOUNCE.
        loop {
            match rx.recv_timeout(DEBOUNCE) {
                Ok(Cmd::Context { text, cursor_pos, seq }) => pending = (text, cursor_pos, seq),
                Ok(Cmd::Shutdown) | Err(RecvTimeoutError::Disconnected) => return,
                Err(RecvTimeoutError::Timeout) => break,
            }
        }

        // Typing settled — generate and emit a suggestion (if any), tagged with the
        // sequence id of the context it came from so the shell can reject it if
        // newer input has since arrived.
        let (text, cursor_pos, seq) = pending;
        if let Some(suggestion) = generate(&text, cursor_pos) {
            if let Ok(cstr) = CString::new(suggestion) {
                // Transfer ownership to the caller; they free via inkline_free_string.
                callback(cstr.into_raw(), seq);
            }
        }
    }
}

/// Initialize the core and register the suggestion callback.
///
/// Spawns the internal worker thread. Calling this again replaces the callback
/// and worker (the previous worker shuts down when its channel disconnects).
#[no_mangle]
pub extern "C" fn inkline_init(callback: SuggestionCallback) {
    let (tx, rx) = mpsc::channel::<Cmd>();
    *lock_sender() = Some(tx); // dropping any previous Sender ends the old worker
    thread::spawn(move || worker(rx, callback));
}

/// Feed the latest typing context into the core.
///
/// `text` is a NUL-terminated UTF-8 string owned by the caller (copied here).
/// `cursor_pos` is the caret offset within `text`. `seq` is a caller-chosen,
/// monotonically increasing id for this context; it is echoed back with the
/// resulting suggestion so the caller can drop suggestions for a context the user
/// has already typed past. Calls are debounced; a suggestion is delivered later
/// via the registered callback.
#[no_mangle]
pub extern "C" fn inkline_on_context(text: *const c_char, cursor_pos: usize, seq: u64) {
    if text.is_null() {
        return;
    }
    // SAFETY: caller guarantees `text` is a valid NUL-terminated string.
    let text = match unsafe { CStr::from_ptr(text) }.to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => return, // ignore non-UTF-8 input
    };

    if let Some(tx) = lock_sender().as_ref() {
        let _ = tx.send(Cmd::Context { text, cursor_pos, seq });
    }
}

/// Load a GGUF model for inference, by absolute path.
///
/// Switches the local inference backend to this model (starting/restarting the
/// `llama-server` subprocess). Loading happens on a background thread, so this
/// returns immediately; suggestions begin once the model is ready. After this is
/// called, the stub generator is no longer used.
#[no_mangle]
pub extern "C" fn inkline_set_model(path: *const c_char) {
    if path.is_null() {
        return;
    }
    // SAFETY: caller guarantees `path` is a valid NUL-terminated string.
    let path = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => return,
    };

    MODEL_REQUESTED.store(true, Ordering::Release);
    // Non-blocking: the engine's manager thread loads the model and serves
    // completions once it's ready.
    engine().set_model(&path);
}

/// Free a string previously handed to the suggestion callback.
#[no_mangle]
pub extern "C" fn inkline_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: `ptr` came from CString::into_raw in this crate and is freed once.
    unsafe { drop(CString::from_raw(ptr)) };
}

/// Stop the worker thread and tear down the core. Safe to call more than once.
#[no_mangle]
pub extern "C" fn inkline_shutdown() {
    if let Some(tx) = lock_sender().take() {
        let _ = tx.send(Cmd::Shutdown);
    }
    // Kill the llama-server child so it isn't orphaned when the app quits.
    // (Blocks briefly until the child is actually reaped.)
    if let Some(engine) = ENGINE.get() {
        engine.shutdown();
    }
}
