//! Suppresses or trims a completion that merely reproduces text already after the
//! caret.
//!
//! A non-FIM model fed the after-caret text as context (see [`crate::prompt`])
//! will sometimes copy it back out — e.g. completing
//! "Please remember to │ before you leave the office." as
//! "check your messages before you leave the office.", which would duplicate the
//! user's existing words on insertion. We keep the genuine new part
//! ("check your messages") and drop the duplicating tail. Per the product
//! principle *prefer suppression to a wrong suggestion*, a completion that is
//! wholly a suffix copy is dropped entirely.
//!
//! Ported from KeyType's `SuffixOverlapGuard`. The comparison is on case-folded
//! alphanumerics only (whitespace, punctuation, and stray markup glyphs the model
//! prepends are ignored), so a leading `<b>`/`•`/`**` can't defeat the match.

/// Minimum normalized-alphanumeric length before any overlap can match — keeps a
/// short common run from tripping it.
const MIN_OVERLAP: usize = 3;
/// For the "completion contains the whole suffix" shape, require this much suffix
/// so a short shared phrase can't fire it.
const MIN_CONTAINED_OVERLAP: usize = 8;

/// Trim `completion` so it doesn't reproduce `after_cursor`. Returns:
/// - `Some(unchanged)` when there is no qualifying overlap,
/// - `Some(truncated)` keeping only the genuine leading part,
/// - `None` when the whole completion is a suffix copy (emit nothing).
///
/// Conservative by construction: never fires when there is no suffix, and a real
/// end-of-line continuation (no overlap with downstream text) passes through.
pub fn trim(completion: String, before_cursor: &str, after_cursor: &str) -> Option<String> {
    match non_duplicating_prefix_len(&completion, before_cursor, after_cursor) {
        None => Some(completion),
        Some(0) => None,
        Some(keep) => {
            let kept: String = completion.chars().take(keep).collect();
            let kept = kept.trim_end();
            if kept.is_empty() {
                None
            } else {
                Some(kept.to_string())
            }
        }
    }
}

/// Number of leading characters of `completion` to keep so it stops right where it
/// begins reproducing `after`. `None` = keep all; `Some(0)` = drop entirely.
fn non_duplicating_prefix_len(completion: &str, before: &str, after: &str) -> Option<usize> {
    let start = duplication_start(completion, before, after)?;
    Some(original_prefix_len(completion, start))
}

/// Offset, in normalized-alphanumeric space, at which `completion` starts
/// reproducing `after`, or `None` when there is no qualifying overlap.
fn duplication_start(completion: &str, before: &str, after: &str) -> Option<usize> {
    let nc = normalized(completion);
    let ns = normalized(after);
    let nc_len = nc.chars().count();
    if nc_len < MIN_OVERLAP || ns.is_empty() {
        return None;
    }

    // 1. Boundary-aligned: the whole completion copies the head of the suffix.
    if ns.starts_with(nc.as_str()) {
        return Some(0);
    }
    // 2. Suffix-contained: the completion already includes the entire upcoming
    //    suffix, so inserting it would re-type text the user already has. The
    //    duplication begins where the suffix first appears inside the completion;
    //    everything before that is the genuine "middle".
    if ns.chars().count() >= MIN_CONTAINED_OVERLAP {
        if let Some(off) = char_index_of(&nc, &ns) {
            return Some(off);
        }
    }
    // 3. Mid-word: the caret split a word, so the suffix opens with that word's
    //    remainder; a copy of the downstream text then starts a few characters
    //    into the suffix. Only fires when the caret is genuinely inside a word.
    if !ends_in_word_char(before) || nc_len < 6 {
        return None;
    }
    let straddle = normalized(&leading_word_run(after));
    if straddle.is_empty() {
        return None;
    }
    if let Some(off) = char_index_of(&ns, &nc) {
        return if off <= straddle.chars().count() {
            Some(0)
        } else {
            None
        };
    }
    None
}

/// Largest count of leading whole chars of `text` whose case-folded alphanumeric
/// scalars number at most `keep_alnum` (rounds down at char boundaries, so a
/// truncation can never include part of the duplicated suffix).
fn original_prefix_len(text: &str, keep_alnum: usize) -> usize {
    if keep_alnum == 0 {
        return 0;
    }
    let mut seen = 0;
    let mut kept = 0;
    for ch in text.chars() {
        let contribution = ch.to_lowercase().filter(|c| c.is_alphanumeric()).count();
        if seen + contribution > keep_alnum {
            break;
        }
        seen += contribution;
        kept += 1;
    }
    kept
}

/// Case-folded string of only the alphanumeric characters of `text`.
fn normalized(text: &str) -> String {
    text.chars()
        .flat_map(char::to_lowercase)
        .filter(|c| c.is_alphanumeric())
        .collect()
}

/// Char offset (not byte offset) of `needle` within `haystack`, or `None`.
fn char_index_of(haystack: &str, needle: &str) -> Option<usize> {
    haystack.find(needle).map(|b| haystack[..b].chars().count())
}

/// Whether `text` ends in a word character (letter or digit) — i.e. the caret sits
/// at the trailing edge of a word rather than after a space/punctuation.
fn ends_in_word_char(text: &str) -> bool {
    text.chars().next_back().is_some_and(|c| c.is_alphanumeric())
}

/// The leading run of word characters in `text` (the remainder of a split word).
fn leading_word_run(text: &str) -> String {
    text.chars().take_while(|c| c.is_alphanumeric()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    // No overlap: a clean answer that doesn't reproduce the suffix passes through.
    #[test]
    fn keeps_non_overlapping_completion() {
        assert_eq!(
            trim("Paris.".to_string(), "The capital of France is ", ", a beautiful city."),
            Some("Paris.".to_string())
        );
    }

    // Boundary-aligned: completion is just the head of the suffix → drop.
    #[test]
    fn drops_boundary_aligned_copy() {
        assert_eq!(
            trim("for dinner tonight".to_string(), "I want to eat ", " for dinner tonight."),
            None
        );
    }

    // Suffix-contained: keep the genuine middle, drop the duplicating tail.
    #[test]
    fn truncates_suffix_contained_copy() {
        assert_eq!(
            trim(
                "check your messages before you leave the office.".to_string(),
                "Please remember to ",
                " before you leave the office."
            ),
            Some("check your messages".to_string())
        );
    }

    // Mid-word: caret split a word; completion copies downstream text starting a
    // few chars into the suffix → drop.
    #[test]
    fn drops_mid_word_copy() {
        assert_eq!(
            trim("ance tuning now".to_string(), "I like per", "formance tuning now"),
            None
        );
    }

    // A stray non-alphanumeric glyph the model prepends (bullet, emphasis stars)
    // is ignored by the normalized comparison, so it can't defeat the match.
    // (HTML tags are already removed upstream by the sanitizer before this runs.)
    #[test]
    fn ignores_stray_punctuation_when_matching() {
        assert_eq!(
            trim("** for dinner tonight".to_string(), "I want to eat ", " for dinner tonight."),
            None
        );
    }

    // No suffix → never fires.
    #[test]
    fn never_fires_without_suffix() {
        assert_eq!(
            trim("some more text".to_string(), "prefix ", ""),
            Some("some more text".to_string())
        );
    }
}
