//! Local inference engine: manages the `llama-server` child process and talks
//! to it over HTTP. This is the real completion backend that replaces the stub.
//!
//! Design (per the architecture):
//! - locate the `llama-server` binary, spawn it on an ephemeral localhost port
//! - poll `GET /health` until ready, then talk to `POST /completion` (a forward
//!   continuation of the text before the caret) for every suggestion
//! - switch models by restarting the subprocess with a new `-m`
//! - restart on crash; clean up the child on shutdown
//!
//! We deliberately use `/completion` for *all* contexts — including mid-text —
//! rather than `/infill`. Fill-in-the-middle only works on FIM-tuned models (most
//! general instruct models 501 on `/infill`) and even there small models tend to
//! copy the suffix back out. A plain continuation works on every model; mid-text
//! awareness comes from feeding the after-caret text as prompt context, which is
//! uniform across models. (See the prompt builder.)
//!
//! ## Concurrency
//! All subprocess work (spawn / health-poll / restart / kill) happens on a single
//! dedicated **manager thread** that exclusively owns the `Child`. Callers
//! interact through a channel plus two atomics (`port`, `ready`). This keeps
//! completion requests lock-free and ensures a multi-second model load never
//! blocks the debounce/worker thread. There is no shared `Mutex`, so there is
//! nothing to poison.
//!
//! The Rust core never makes OS UI calls — this is pure process + HTTP work.

use std::io;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

/// How many tokens of continuation to request per suggestion.
const N_PREDICT: u32 = 24;
/// How long to wait for the server to load a model and report healthy.
const HEALTH_TIMEOUT: Duration = Duration::from_secs(90);
/// How often to poll `/health` while waiting for startup.
const HEALTH_POLL: Duration = Duration::from_millis(200);

/// Control / framing tokens that must never surface as visible text in a
/// suggestion. Resolved to token IDs *per loaded model* (IDs differ across models)
/// and banned via `logit_bias`. Only resolutions that map to a **single atomic
/// token** are kept (a multi-piece string can't be banned without restricting
/// legitimate text), so listing a token a given model doesn't have is harmless —
/// it's simply skipped. This is a cleanliness guard on specific control-token IDs
/// only; it never restricts characters, scripts, or languages.
///
/// Covers the popular instruct families. **Intentionally excludes end-of-turn /
/// end-of-sequence tokens** (`<|im_end|>`, `<|eot_id|>`, `<end_of_turn>`, `</s>`,
/// `<|end|>`, …): a model emits those to *stop*, and llama-server ends generation
/// on them instead of placing them in `content`, so they never leak as text —
/// banning them would only force run-on output. We ban turn-*start*, role-header,
/// and "thinking" tokens, which a model can otherwise emit mid-completion.
const SUPPRESSED_TOKEN_STRINGS: &[&str] = &[
    // ChatML / Qwen
    "<|im_start|>",
    // Reasoning / "thinking" traces (Qwen-thinking, DeepSeek-R1, …)
    "<think>",
    "</think>",
    // Llama 3.x role-header delimiters and tool tag
    "<|start_header_id|>",
    "<|end_header_id|>",
    "<|python_tag|>",
    // Gemma turn start
    "<start_of_turn>",
    // Phi-3 role markers
    "<|user|>",
    "<|assistant|>",
    "<|system|>",
];

/// Bias applied to a suppressed token's logit (JSON has no -inf). Large enough
/// negative that the token is effectively unselectable; verified against the
/// llama.cpp build in use.
const BAN_BIAS: f64 = -100_000.0;

/// Commands to the manager thread (the sole owner of the child process).
enum Cmd {
    LoadModel(String),
    Restart,
    Shutdown(SyncSender<()>),
}

/// Handle to the inference engine. Cheap to share; holds no lock on the hot path.
pub struct Engine {
    tx: Sender<Cmd>,
    /// Current server port (0 = none/not ready).
    port: Arc<AtomicU16>,
    /// True once the server is healthy and a model is loaded.
    ready: Arc<AtomicBool>,
    /// Control-token IDs to ban via logit_bias, resolved per loaded model.
    /// Written by the manager on load; read on each completion.
    suppressed: Arc<Mutex<Vec<i64>>>,
    agent: ureq::Agent,
}

/// Why a single HTTP completion request failed, so the caller can react: a
/// `Rejected` (non-2xx) request leaves the server running; a `Dead` (transport)
/// failure means the server likely died and should be restarted.
enum SendErr {
    Rejected,
    Dead,
}

impl Engine {
    pub fn new() -> Self {
        let agent = build_agent();
        let port = Arc::new(AtomicU16::new(0));
        let ready = Arc::new(AtomicBool::new(false));
        let suppressed = Arc::new(Mutex::new(Vec::new()));
        let (tx, rx) = mpsc::channel::<Cmd>();

        let manager = Manager {
            server_bin: None,
            child: None,
            model_path: None,
            port: Arc::clone(&port),
            ready: Arc::clone(&ready),
            suppressed: Arc::clone(&suppressed),
            agent: agent.clone(),
        };
        thread::spawn(move || manager.run(rx));

        Engine { tx, port, ready, suppressed, agent }
    }

    /// Switch to `path`, (re)starting llama-server. Non-blocking: the manager
    /// thread loads the model and publishes readiness when done.
    pub fn set_model(&self, path: &str) {
        let _ = self.tx.send(Cmd::LoadModel(path.to_string()));
    }

    /// Request a completion. `prefix` is the text before the caret, `suffix` the
    /// text after it.
    ///
    /// Always a plain `/completion`: a forward continuation. The prompt builder
    /// ([`crate::prompt::build`]) feeds the after-caret text as context so mid-text
    /// suggestions are suffix-aware without needing model-specific fill-in-the-
    /// middle (see the module docs for why we don't use `/infill`). The result is
    /// sanitized and run through the suffix-overlap guard ([`crate::overlap::trim`])
    /// so it can't just re-type text the user already has after the caret.
    ///
    /// Returns None if the server isn't ready or there's nothing to suggest. Never
    /// blocks on a model load — that happens on the manager thread.
    pub fn complete(&self, prefix: &str, suffix: &str) -> Option<String> {
        if !self.ready.load(Ordering::Acquire) {
            return None;
        }
        let port = self.port.load(Ordering::Acquire);
        if port == 0 {
            return None;
        }

        // Seam context for the sanitizer: whether the prefix already ends in
        // whitespace (leading-space handling), and whether the user's sentence
        // continues after the caret (trailing-terminator handling).
        let prefix_ends_with_ws = prefix.ends_with(|c: char| c.is_whitespace());
        let suffix_continues = suffix_continues_sentence(suffix);

        // A /completion continues the text before the caret; an all-whitespace
        // prefix has nothing to continue from, so don't ask.
        if prefix.trim_end().is_empty() {
            return None;
        }

        let prompt = crate::prompt::build(prefix, suffix);
        let (url, body) = self.build_request(port, &prompt);
        match self.send(&url, &body) {
            // Clean the raw content (markup/whitespace/sentence) into a suggestion,
            // then drop/trim it if it just reproduces text after the caret — all
            // before it reaches the callback, so nothing bad flashes in the overlay.
            Ok(raw) => raw
                .and_then(|s| sanitize_suggestion(&s, prefix_ends_with_ws, suffix_continues))
                .and_then(|s| crate::overlap::trim(s, prefix, suffix)),
            // The server answered but rejected this request — leave it running.
            Err(SendErr::Rejected) => None,
            // Transport-level failure — the server likely died. Trigger exactly
            // one restart (the first caller to flip `ready` wins).
            Err(SendErr::Dead) => {
                if self.ready.swap(false, Ordering::AcqRel) {
                    let _ = self.tx.send(Cmd::Restart);
                }
                None
            }
        }
    }

    /// Build the (url, json-body) for one `/completion` request: the sampling
    /// params, the `prompt` (already assembled by [`crate::prompt::build`]), and
    /// the control-token `logit_bias`.
    fn build_request(&self, port: u16, prompt: &str) -> (String, String) {
        let mut request = serde_json::json!({
            "n_predict": N_PREDICT,
            "temperature": 0.6,
            "top_p": 0.9,
            "top_k": 40,
            "repeat_penalty": 1.1,
            "cache_prompt": true,
            "stop": ["\n"],
        });
        let fields = request.as_object_mut().expect("json object");

        fields.insert("prompt".into(), prompt.into());
        let url = format!("http://127.0.0.1:{port}/completion");

        // Ban this model's control/thinking tokens so they can't leak into the
        // suggestion. Targets specific token IDs only, so it never restricts
        // characters, scripts, or languages.
        let suppressed = lock_ids(&self.suppressed).clone();
        if !suppressed.is_empty() {
            let bias: Vec<serde_json::Value> = suppressed
                .iter()
                .map(|&id| serde_json::json!([id, BAN_BIAS]))
                .collect();
            fields.insert("logit_bias".into(), serde_json::Value::Array(bias));
        }

        (url, request.to_string())
    }

    /// POST one completion request and parse the result. `Ok(Some)` is a usable
    /// completion, `Ok(None)` an empty/whitespace one; `Err` distinguishes a
    /// rejected (non-2xx) request from a dead-server transport failure.
    fn send(&self, url: &str, body: &str) -> Result<Option<String>, SendErr> {
        match self
            .agent
            .post(url)
            .set("Content-Type", "application/json")
            .send_string(body)
        {
            Ok(response) => Ok(response.into_string().ok().and_then(|t| parse_completion(&t))),
            Err(ureq::Error::Status(_, _)) => Err(SendErr::Rejected),
            Err(ureq::Error::Transport(_)) => Err(SendErr::Dead),
        }
    }

    /// Stop the server and wait briefly for the child to actually be killed, so
    /// it isn't orphaned when the app exits.
    pub fn shutdown(&self) {
        let (ack_tx, ack_rx) = mpsc::sync_channel::<()>(0);
        if self.tx.send(Cmd::Shutdown(ack_tx)).is_ok() {
            let _ = ack_rx.recv_timeout(Duration::from_secs(5));
        }
    }
}

fn build_agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_millis(500))
        .timeout_read(Duration::from_secs(20))
        .build()
}

fn parse_completion(body: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(body).ok()?;
    let content = value.get("content")?.as_str()?;
    if content.trim().is_empty() {
        None
    } else {
        Some(content.to_string())
    }
}

/// Punctuation that ends a sentence. If one appears in a suggestion we cut at the
/// first occurrence (inclusive) so we offer a clean unit rather than a run-on.
/// Tunable: adjust this set to change what counts as a stopping point.
const SENTENCE_TERMINATORS: &[char] = &['.', '!', '?'];

/// Turn a raw model completion into a clean suggestion, or `None` if nothing
/// usable remains. This is the single post-processing step applied to every
/// `/completion` result before it reaches the callback, so cosmetic noise never
/// flashes in the overlay.
///
/// `prefix_ends_with_ws` is whether the text before the caret already ends in
/// whitespace; it controls leading-space handling at the seam so inserting the
/// suggestion never produces a double space (nor drops a needed single one).
///
/// `suffix_continues` is whether the user's sentence continues into the text after
/// the caret (see [`suffix_continues_sentence`]); when true a trailing sentence
/// terminator is dropped so the suggestion doesn't punctuate the middle of an
/// ongoing sentence.
///
/// Pipeline, in order:
/// 1. strip markup tags (complete `<b>`/`</b>`/… and trailing dangling fragments)
/// 2. trim leading newlines
/// 3. (seam) drop/keep a leading space depending on `prefix_ends_with_ws`
/// 4. cut at the first sentence terminator (inclusive), if any
/// 5. if `suffix_continues`, drop a trailing `.`/`!`/`?`
/// 6. trim trailing whitespace
/// 7. return `None` if nothing is left
fn sanitize_suggestion(raw: &str, prefix_ends_with_ws: bool, suffix_continues: bool) -> Option<String> {
    // 1. Strip HTML/markdown markup (e.g. Gemma's `</b>blue<b>` -> `blue`).
    let stripped = strip_markup_tags(raw);

    // 2. Trim leading newlines (e.g. "\nblue..." -> "blue..."). Spaces are left
    //    for the seam step below, where they may be meaningful.
    let mut s: &str = stripped.trim_start_matches(['\n', '\r']);

    // 3. Seam handling. If the prefix already ends in whitespace, a leading space
    //    on the suggestion would produce "is  blue" — drop it. If the prefix does
    //    NOT end in whitespace, keep a leading space so we get "is" + " blue".
    if prefix_ends_with_ws {
        s = s.trim_start_matches(' ');
    }

    // 4. Sentence-boundary cut: keep up to and including the first terminator. If
    //    there is none, keep the whole string (don't force-truncate).
    if let Some(idx) = s.find(|c| SENTENCE_TERMINATORS.contains(&c)) {
        // Terminators are ASCII, so `idx + 1` is a valid char boundary.
        s = &s[..=idx];
    }

    // 5. If the user's sentence continues after the caret, don't inject a sentence
    //    terminator into the middle of it: drop any trailing `.`/`!`/`?` so e.g.
    //    "Paris." inserted before ", a beautiful city." reads "Paris, a beautiful
    //    city." rather than "Paris., a beautiful city.".
    if suffix_continues {
        s = s.trim_end_matches(|c: char| SENTENCE_TERMINATORS.contains(&c));
    }

    // 6. Trim trailing whitespace.
    s = s.trim_end();

    // 7. Nothing usable left (only tags/whitespace) -> emit no suggestion.
    if s.is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}

/// Whether the user's sentence continues into the text after the caret — i.e. a
/// suggestion that ends the sentence (with `.`/`!`/`?`) would wrongly punctuate
/// the middle of it. True when the next non-whitespace character after the caret
/// is a lowercase letter, clause-continuing punctuation, or itself a sentence
/// terminator (the suffix already carries the period, so the suggestion mustn't
/// add a second one). False at end-of-text or when the suffix looks like a fresh
/// sentence (where keeping a terminator is correct). Conservative: anything
/// ambiguous (uppercase, digit, other scripts) keeps the terminator.
fn suffix_continues_sentence(suffix: &str) -> bool {
    match suffix.trim_start().chars().next() {
        None => false,
        Some(c) => {
            c.is_lowercase()
                || matches!(c, ',' | ';' | ':' | ')' | ']' | '-' | '—')
                || SENTENCE_TERMINATORS.contains(&c)
        }
    }
}

/// Remove markup tag-like spans from `input`: complete tags (`<b>`, `</b>`,
/// `<br>`, `<a href="x">`, …) anywhere, plus a single dangling/unterminated tag
/// fragment (`<`, `<b`, `</b` with no closing `>`) at the trailing edge.
///
/// Conservative by design: a `<` only counts as a tag when followed by an
/// optional `/` and an ASCII-letter tag name, so legitimate prose like `x < y`
/// (a `<` followed by a space) survives untouched.
fn strip_markup_tags(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut i = 0;
    let mut copy_from = 0;
    while i < bytes.len() {
        if bytes[i] == b'<' {
            if let Some(end) = complete_tag_len(bytes, i) {
                // Flush the prose before the tag (as a UTF-8 slice), skip the tag.
                out.push_str(&input[copy_from..i]);
                i = end;
                copy_from = end;
                continue;
            }
        }
        i += 1;
    }
    out.push_str(&input[copy_from..]);
    strip_trailing_dangling_tag(&out).to_string()
}

/// If a complete markup tag starts at `bytes[start]` (a `<`), return the byte
/// index just past its closing `>`. Requires `<`, an optional `/`, an ASCII-letter
/// name, then any attribute bytes up to `>`. Returns `None` for a bare `<` not
/// followed by a tag name (e.g. `x < y`) or a `<` with no closing `>`.
fn complete_tag_len(bytes: &[u8], start: usize) -> Option<usize> {
    let mut j = start + 1; // past '<'
    if j < bytes.len() && bytes[j] == b'/' {
        j += 1; // closing tag
    }
    // A tag name must start with an ASCII letter; otherwise this isn't a tag.
    if j >= bytes.len() || !bytes[j].is_ascii_alphabetic() {
        return None;
    }
    while j < bytes.len() {
        match bytes[j] {
            b'>' => return Some(j + 1),
            b'<' => return None, // not a well-formed tag
            _ => j += 1,
        }
    }
    None // hit end with no '>': not a *complete* tag
}

/// Strip a single dangling, unterminated tag fragment at the end of `s` — a
/// trailing `<`, `<b`, or `</b` with no closing `>`. Conservative: the trailing
/// `<` must be followed only by an optional `/` and ASCII letters, so prose like
/// `x < y` (which doesn't end in such a fragment) is left intact.
fn strip_trailing_dangling_tag(s: &str) -> &str {
    if let Some(pos) = s.rfind('<') {
        let mut rest = &s[pos + 1..];
        if let Some(r) = rest.strip_prefix('/') {
            rest = r;
        }
        if rest.bytes().all(|b| b.is_ascii_alphabetic()) {
            return &s[..pos];
        }
    }
    s
}

/// Lock the suppressed-IDs list, tolerating poisoning (the data is just a Vec).
fn lock_ids(m: &Mutex<Vec<i64>>) -> MutexGuard<'_, Vec<i64>> {
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Resolve each control-token string to its ID for the loaded model, keeping
/// only those that map to a *single* (atomic) token — a multi-piece string can't
/// be banned without restricting legitimate text, so it's skipped.
fn resolve_suppressed_tokens(agent: &ureq::Agent, port: u16) -> Vec<i64> {
    let mut ids = Vec::new();
    for &s in SUPPRESSED_TOKEN_STRINGS {
        match tokenize_special(agent, port, s) {
            Some(tokens) if tokens.len() == 1 => {
                eprintln!("inkline: suppressing control token {s:?} -> id {}", tokens[0]);
                ids.push(tokens[0]);
            }
            Some(tokens) => {
                eprintln!("inkline: skip {s:?} (not an atomic token: {} pieces)", tokens.len());
            }
            None => eprintln!("inkline: skip {s:?} (absent / not resolvable)"),
        }
    }
    ids
}

/// Tokenize `content` with special-token parsing on, returning the token IDs.
fn tokenize_special(agent: &ureq::Agent, port: u16, content: &str) -> Option<Vec<i64>> {
    let url = format!("http://127.0.0.1:{port}/tokenize");
    let body = serde_json::json!({ "content": content, "special": true }).to_string();
    let response = agent
        .post(&url)
        .set("Content-Type", "application/json")
        .send_string(&body)
        .ok()?;
    let text = response.into_string().ok()?;
    let value: serde_json::Value = serde_json::from_str(&text).ok()?;
    let tokens: Vec<i64> = value
        .get("tokens")?
        .as_array()?
        .iter()
        .filter_map(|t| t.as_i64())
        .collect();
    if tokens.is_empty() {
        None
    } else {
        Some(tokens)
    }
}

/// Owns the llama-server child and runs all subprocess work on its own thread.
struct Manager {
    server_bin: Option<PathBuf>,
    child: Option<Child>,
    model_path: Option<String>,
    port: Arc<AtomicU16>,
    ready: Arc<AtomicBool>,
    suppressed: Arc<Mutex<Vec<i64>>>,
    agent: ureq::Agent,
}

impl Manager {
    fn run(mut self, rx: Receiver<Cmd>) {
        while let Ok(cmd) = rx.recv() {
            match cmd {
                Cmd::LoadModel(path) => {
                    if let Err(err) = self.load(&path) {
                        eprintln!("inkline: failed to load model '{path}': {err}");
                    }
                }
                Cmd::Restart => {
                    if let Some(model) = self.model_path.clone() {
                        eprintln!("inkline: llama-server unreachable, restarting");
                        if let Err(err) = self.load(&model) {
                            eprintln!("inkline: restart failed: {err}");
                        }
                    }
                }
                Cmd::Shutdown(ack) => {
                    self.stop();
                    let _ = ack.send(());
                    return;
                }
            }
        }
        // Channel closed (Engine dropped) — Drop will stop the child.
    }

    /// Load `path`, restarting the server against the new model. Blocks (on this
    /// thread only) until the server is healthy or times out.
    fn load(&mut self, path: &str) -> Result<(), String> {
        // Mark not-ready up front so completions stop hitting the old server, and
        // drop the previous model's suppressed-token IDs (they're model-specific).
        self.ready.store(false, Ordering::Release);
        self.port.store(0, Ordering::Release);
        lock_ids(&self.suppressed).clear();

        let server = self
            .locate_server()
            .ok_or_else(|| "llama-server binary not found".to_string())?;
        if !Path::new(path).exists() {
            return Err(format!("model file does not exist: {path}"));
        }

        self.stop();

        let port = pick_ephemeral_port().map_err(|e| format!("could not pick a port: {e}"))?;
        let mut child = Command::new(&server)
            .arg("-m")
            .arg(path)
            .arg("--host")
            .arg("127.0.0.1")
            .arg("--port")
            .arg(port.to_string())
            .arg("--no-webui")
            .arg("-c")
            .arg("4096")
            .stdout(Stdio::null())
            .stderr(Stdio::inherit()) // surface model-load errors during dev
            .spawn()
            .map_err(|e| format!("failed to spawn llama-server: {e}"))?;

        let deadline = Instant::now() + HEALTH_TIMEOUT;
        loop {
            if is_healthy(&self.agent, port) {
                break;
            }
            if let Ok(Some(status)) = child.try_wait() {
                return Err(format!("llama-server exited during startup ({status})"));
            }
            if Instant::now() > deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err("llama-server did not become healthy in time".to_string());
            }
            thread::sleep(HEALTH_POLL);
        }

        self.child = Some(child);
        self.model_path = Some(path.to_string());

        // Resolve this model's control/thinking tokens to IDs (now that the
        // server can tokenize) and publish them for the per-request logit_bias.
        let ids = resolve_suppressed_tokens(&self.agent, port);
        *lock_ids(&self.suppressed) = ids;

        self.port.store(port, Ordering::Release);
        self.ready.store(true, Ordering::Release);
        eprintln!("inkline: model loaded on 127.0.0.1:{port} ({path})");
        Ok(())
    }

    fn stop(&mut self) {
        self.ready.store(false, Ordering::Release);
        self.port.store(0, Ordering::Release);
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    /// Find the `llama-server` binary: env override, common install locations,
    /// then PATH. Cached after the first lookup.
    fn locate_server(&mut self) -> Option<PathBuf> {
        if let Some(bin) = &self.server_bin {
            return Some(bin.clone());
        }

        let mut candidates: Vec<PathBuf> = Vec::new();
        if let Ok(env_path) = std::env::var("INKLINE_LLAMA_SERVER") {
            candidates.push(PathBuf::from(env_path));
        }
        candidates.push(PathBuf::from("/opt/homebrew/bin/llama-server"));
        candidates.push(PathBuf::from("/usr/local/bin/llama-server"));
        if let Ok(path_var) = std::env::var("PATH") {
            for dir in path_var.split(':') {
                candidates.push(Path::new(dir).join("llama-server"));
            }
        }

        let found = candidates.into_iter().find(|p| p.is_file());
        self.server_bin = found.clone();
        found
    }
}

impl Drop for Manager {
    fn drop(&mut self) {
        self.stop();
    }
}

fn is_healthy(agent: &ureq::Agent, port: u16) -> bool {
    let url = format!("http://127.0.0.1:{port}/health");
    // ureq treats non-2xx as Err, so Ok == ready (200). 503 = still loading.
    agent.get(&url).call().is_ok()
}

/// Grab a free ephemeral localhost port by binding to :0 and releasing it.
/// (Small TOCTOU window before llama-server binds it; acceptable here.)
fn pick_ephemeral_port() -> io::Result<u16> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();
    Ok(port)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Acceptance criterion 1: tags gone, content intact.
    #[test]
    fn strips_markup_keeping_content() {
        assert_eq!(sanitize_suggestion("</b>blue<b>", false, false).as_deref(), Some("blue"));
    }

    // Acceptance criterion 2: leading newline stripped, cut at first sentence end.
    #[test]
    fn trims_newline_and_cuts_at_sentence() {
        assert_eq!(
            sanitize_suggestion("\nblue. I like it because...", false, false).as_deref(),
            Some("blue.")
        );
    }

    // Acceptance criterion 3: legitimate `<` in prose survives.
    #[test]
    fn preserves_prose_angle_bracket() {
        assert_eq!(sanitize_suggestion("x < y", false, false).as_deref(), Some("x < y"));
    }

    // Acceptance criterion 4: only tags/whitespace -> None.
    #[test]
    fn empty_after_sanitizing_is_none() {
        assert_eq!(sanitize_suggestion("<b></b>", false, false), None);
        assert_eq!(sanitize_suggestion("   ", false, false), None);
        assert_eq!(sanitize_suggestion("<b", false, false), None);
    }

    // Acceptance criterion 5: no double space when prefix ends in whitespace, but
    // a needed leading space is kept when it doesn't.
    #[test]
    fn handles_seam_whitespace() {
        assert_eq!(sanitize_suggestion(" blue", true, false).as_deref(), Some("blue"));
        assert_eq!(sanitize_suggestion(" blue", false, false).as_deref(), Some(" blue"));
    }

    // Dangling trailing fragment is removed (the `<b` half of `</b>blue<b`).
    #[test]
    fn strips_trailing_dangling_tag() {
        assert_eq!(sanitize_suggestion("</b>blue<b", false, false).as_deref(), Some("blue"));
        assert_eq!(sanitize_suggestion("blue<", false, false).as_deref(), Some("blue"));
    }

    // When the user's sentence continues after the caret, a trailing terminator is
    // dropped so we don't punctuate the middle of it; otherwise it's kept.
    #[test]
    fn drops_trailing_terminator_when_suffix_continues() {
        // "The capital of France is │, a beautiful city." -> "Paris" (no period).
        assert_eq!(sanitize_suggestion(" Paris.", true, true).as_deref(), Some("Paris"));
        // End-of-text (suffix doesn't continue): keep the period.
        assert_eq!(sanitize_suggestion(" Paris.", true, false).as_deref(), Some("Paris."));
        // The sentence-cut still bounds length; only the trailing terminator goes.
        assert_eq!(
            sanitize_suggestion("yes! and more", false, true).as_deref(),
            Some("yes")
        );
    }

    #[test]
    fn suffix_continuation_detection() {
        assert!(suffix_continues_sentence(", a beautiful city."));   // clause punct
        assert!(suffix_continues_sentence(" and then we left."));    // lowercase word
        assert!(suffix_continues_sentence("."));                     // suffix is the period
        assert!(!suffix_continues_sentence(""));                     // end of text
        assert!(!suffix_continues_sentence(" The next sentence."));  // new sentence
    }

    // Every request targets /completion and carries the prompt verbatim (the
    // prompt builder owns assembly/trimming; see the `prompt` module's tests).
    #[test]
    fn build_request_targets_completion_with_prompt() {
        let engine = Engine::new();
        let (url, body) = engine.build_request(1234, "The capital of France is");
        assert!(url.ends_with("/completion"));
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["prompt"], "The capital of France is");
        assert_eq!(v["n_predict"], 24);
    }
}
