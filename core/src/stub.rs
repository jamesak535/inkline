//! Phase 1 STUB suggestion generator.
//!
//! No model, no inference — just a deterministic, canned completion derived from
//! the context so the FFI round-trip is observably driven by the input. This is
//! replaced wholesale in Phase 3 by the `llama-server` HTTP client.

/// Produce a suggested *continuation* (the ghost text that would be inserted),
/// given the full context text and the cursor position within it.
///
/// Returns the text that should appear *after* the cursor, not the whole line.
pub fn complete(text: &str, _cursor_pos: usize) -> String {
    let trimmed = text.trim_end();
    let last_word = trimmed
        .rsplit(|c: char| c.is_whitespace())
        .next()
        .unwrap_or("")
        .to_lowercase();

    match last_word.as_str() {
        "" => "…".to_string(),
        "hello" => " there! How can I help you today?".to_string(),
        "the" => " quick brown fox".to_string(),
        "thank" => " you very much".to_string(),
        "dear" => " Sir or Madam,".to_string(),
        "best" => " regards,".to_string(),
        other => format!(" [stub completion for \"{other}\"]"),
    }
}
