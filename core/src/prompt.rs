//! Builds the `/completion` prompt the model continues from.
//!
//! The shape is chosen by whether the caret sits at a **word boundary** (the text
//! before it ends in whitespace) and whether there is text after the caret:
//!
//! - **Word boundary** (just typed a space — predicting the next word): a **few-
//!   shot** prompt. A handful of `Before:/Insert:` (or `…/Continue:`) examples plus
//!   `stop:["\n"]` teach the base model to emit a short, bounded bridge and stop,
//!   instead of rambling into a full paragraph. When there's text after the caret
//!   it's shown as an `After:` line so the bridge is suffix-aware (non-FIM mid-text
//!   completion, cf. KeyType). Verified on the live model: turns
//!   "The capital of France is │, a beautiful city." into "Paris" (not a run-on).
//!
//! - **Mid-word** (typing the letters of a word — no trailing whitespace): a plain
//!   forward continuation of the text before the caret. The model finishes the
//!   partial word ("conc" → "iseness"). The few-shot answer style is *avoided*
//!   here: it primes a leading space and would start a new word ("conc │erence").
//!
//! Both shapes are **windowed**: only a bounded slice of context near the caret is
//! kept, so a large document can't overflow the server's context window (`-c`).
//! The before-caret text always has its trailing whitespace trimmed so the model
//! continues a clean boundary; the output sanitizer reconciles the seam space.

/// Max bytes of before-caret text to keep (the slice nearest the caret). Sized so
/// that even dense multi-byte scripts stay well under a 4096-token context once
/// the few-shot examples, suffix window, and `n_predict` are added.
const PREFIX_WINDOW_BYTES: usize = 4000;
/// Max bytes of after-caret text to keep (the slice nearest the caret).
const SUFFIX_WINDOW_BYTES: usize = 1200;

/// Few-shot preamble for end-of-text (no suffix) completion at a word boundary.
const CONTINUE_FEWSHOT: &str = "\
Continue the text with a short, natural continuation. Write only the text to add.

Before: The weather today is
Continue: sunny with a light breeze

Before: Thank you so much for
Continue: your time and consideration

Before: The project deadline is
Continue: next Friday afternoon

";

/// Few-shot preamble for mid-text completion at a word boundary: the `After:` line
/// makes the bridge suffix-aware, and "do not repeat" discourages copying it back.
const INSERT_FEWSHOT: &str = "\
Insert text where the cursor is so the writing flows into the text that follows. \
Write only the short text to insert; do not repeat the text after the cursor.

After: , a beautiful city.
Before: The capital of France is
Insert: Paris

After: for dinner tonight.
Before: I want to eat
Insert: pasta

After: before you leave the office.
Before: Please remember to
Insert: lock the door

";

/// Build the prompt for a `/completion` request from the text before/after the
/// caret. The caller guarantees `prefix` has non-whitespace content.
pub fn build(prefix: &str, suffix: &str) -> String {
    // Mid-word (no trailing whitespace): continue the prefix directly so the model
    // finishes the partial word. Answer-style few-shot would wrongly start a new
    // word here. The suffix is dropped in this case (rare mid-word/mid-edit; the
    // overlap guard still protects against re-typing it).
    let at_boundary = prefix.ends_with(|c: char| c.is_whitespace());
    let prefix_win = window_prefix(prefix).trim_end();
    if !at_boundary {
        return prefix_win.to_string();
    }

    let suffix_win = window_suffix(suffix).trim();
    if suffix_win.is_empty() {
        // End-of-text at a word boundary: few-shot continuation.
        format!("{CONTINUE_FEWSHOT}Before: {prefix_win}\nContinue:")
    } else {
        // Mid-text at a word boundary: few-shot, suffix-aware.
        format!("{INSERT_FEWSHOT}After: {suffix_win}\nBefore: {prefix_win}\nInsert:")
    }
}

/// Keep the last `PREFIX_WINDOW_BYTES` of `prefix`, snapped forward to a char
/// boundary and then past the first partial word, so the kept slice starts on a
/// clean word boundary.
fn window_prefix(prefix: &str) -> &str {
    if prefix.len() <= PREFIX_WINDOW_BYTES {
        return prefix;
    }
    let mut start = prefix.len() - PREFIX_WINDOW_BYTES;
    while start < prefix.len() && !prefix.is_char_boundary(start) {
        start += 1;
    }
    let tail = &prefix[start..];
    // Drop a partial leading word so the window starts at a word boundary.
    match tail.split_once(|c: char| c.is_whitespace()) {
        Some((_partial, rest)) => rest,
        None => tail,
    }
}

/// Keep the first `SUFFIX_WINDOW_BYTES` of `suffix`, snapped back to a char
/// boundary and then to the last whole word, so the kept slice ends cleanly.
fn window_suffix(suffix: &str) -> &str {
    if suffix.len() <= SUFFIX_WINDOW_BYTES {
        return suffix;
    }
    let mut end = SUFFIX_WINDOW_BYTES;
    while end > 0 && !suffix.is_char_boundary(end) {
        end -= 1;
    }
    let head = &suffix[..end];
    // Drop a partial trailing word so the window ends at a word boundary.
    match head.rfind(|c: char| c.is_whitespace()) {
        Some(pos) => &head[..pos],
        None => head,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn end_of_text_boundary_uses_fewshot_continue() {
        let p = build("I want to eat ", "");
        assert!(p.starts_with("Continue the text"));
        assert!(p.ends_with("Before: I want to eat\nContinue:"));
    }

    #[test]
    fn mid_text_boundary_uses_fewshot_insert() {
        let p = build("The capital of France is ", ", a beautiful city.");
        assert!(p.starts_with("Insert text where the cursor is"));
        // Trailing space trimmed; query lines appended after the examples.
        assert!(p.ends_with(
            "After: , a beautiful city.\nBefore: The capital of France is\nInsert:"
        ));
    }

    #[test]
    fn mid_word_is_plain_continuation_no_scaffolding() {
        // No trailing whitespace -> plain prefix so the model finishes the word.
        assert_eq!(build("I really enjoyed the conc", ""), "I really enjoyed the conc");
        // Mid-word with a suffix still goes plain (suffix dropped; overlap guard
        // protects against re-typing the rest of the word).
        assert_eq!(build("I like perf", "ormance tuning"), "I like perf");
    }

    #[test]
    fn window_prefix_keeps_tail_at_word_boundary() {
        let long = format!("{}lemon", "word ".repeat(2000)); // ~10k bytes
        let w = window_prefix(&long);
        assert!(w.len() <= PREFIX_WINDOW_BYTES);
        assert!(w.ends_with("lemon"));
        assert!(w.starts_with("word")); // no partial leading fragment, no space
        assert!(!w.starts_with(' '));
    }

    #[test]
    fn window_suffix_keeps_head_at_word_boundary() {
        let long = format!("start {}", "tail ".repeat(2000)); // ~10k bytes
        let w = window_suffix(&long);
        assert!(w.len() <= SUFFIX_WINDOW_BYTES);
        assert!(w.starts_with("start"));
        assert!(!w.ends_with(' '));
    }
}
