import AppKit
import ApplicationServices

/// A snapshot of the focused editable element and where the caret sits.
struct EditContext {
    let element: AXUIElement
    /// Full text of the focused element.
    let value: String
    /// Caret offset as a UTF-16 (NSString) index — AX's native unit.
    let caretLocation: Int
    /// Text before the caret. This is what we feed the core, so the core never
    /// has to reconcile UTF-16 vs byte offsets.
    let prefix: String
    /// True if the focused element is a password / secure text field — the shell
    /// skips these (per the `suppressSecureFields` setting) so secrets are never
    /// read or echoed as ghost text.
    let isSecure: Bool
}

/// Reads editable text + caret geometry from the focused app via Accessibility.
/// This is the macOS shell's job — the Rust core never touches AX.
enum AXReader {
    /// Read the focused element's text and caret position.
    static func readContext() -> EditContext? {
        let system = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            debugLog("readContext: no focused AX element")
            return nil
        }
        // Verified above that this CFTypeRef really is an AXUIElement.
        let element = focused as! AXUIElement

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String else {
            debugLog("readContext: \(describe(element)) — no string AXValue (unsupported field)")
            return nil
        }

        let ns = value as NSString
        var caret = ns.length

        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeVal = rangeRef, let axRange = asAXValue(rangeVal) {
            var range = CFRange()
            if AXValueGetValue(axRange, .cfRange, &range) {
                caret = range.location
            }
        }

        let loc = max(0, min(caret, ns.length))
        let prefix = ns.substring(to: loc)
        debugLog("readContext: \(describe(element)) ok — \(ns.length) chars, caret \(loc), secure \(isSecureField(element))")
        return EditContext(
            element: element,
            value: value,
            caretLocation: loc,
            prefix: prefix,
            isSecure: isSecureField(element)
        )
    }

    /// `role/subrole` of an element, for diagnostics.
    private static func describe(_ element: AXUIElement) -> String {
        func string(_ attribute: String) -> String {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
                  let s = ref as? String else { return "?" }
            return s
        }
        return "\(string(kAXRoleAttribute as String))/\(string(kAXSubroleAttribute as String))"
    }

    /// Debug logging gate. Works both when launched directly (`INKLINE_DEBUG` env)
    /// and via `open` (the `InklineDebug` UserDefault — env vars don't reach an
    /// `open`ed app). Toggle: `defaults write com.inkline.app InklineDebug -bool YES`.
    static var debugEnabled: Bool {
        UserDefaults.standard.bool(forKey: "InklineDebug")
            || ProcessInfo.processInfo.environment["INKLINE_DEBUG"] != nil
    }

    private static func debugLog(_ message: @autoclosure () -> String) {
        if debugEnabled { NSLog("Inkline: %@", message()) }
    }

    /// Whether the focused element is a password / secure text field. Native
    /// secure fields report the `AXSecureTextField` role (some apps put it in the
    /// subrole), so we check both.
    static func isSecureField(_ element: AXUIElement) -> Bool {
        func string(_ attribute: String) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
                return nil
            }
            return ref as? String
        }
        return string(kAXRoleAttribute as String) == "AXSecureTextField"
            || string(kAXSubroleAttribute as String) == "AXSecureTextField"
    }

    /// Caret position plus the focused field's bounds, both in Cocoa screen
    /// coordinates. The field rect is the wrap boundary for ghost text; `font` is
    /// the field's actual font (when AX surfaces it) so the ghost matches its size.
    struct CaretGeometry {
        let caret: CGRect
        let field: CGRect?
        let font: NSFont?
        /// Which tier produced this geometry. `exact` is pixel-accurate (AX bounds
        /// or OCR); `estimated` is the font-measurement fallback, which drifts as the
        /// line grows — the caller prefers OCR over it when Screen Recording is on.
        var source: Source = .exact
        enum Source { case exact, estimated }
    }

    static func caretGeometry(for element: AXUIElement, caretLocation: Int) -> CaretGeometry? {
        let field = elementFrame(element).map(flipToCocoa)
        let resolvedFont = resolveFont(for: element, caretLocation: caretLocation)
        // Most apps + many Safari sites: the focused element answers caret bounds.
        if let caret = caretRect(for: element, caretLocation: caretLocation) {
            return CaretGeometry(caret: caret, field: field, font: resolvedFont, source: .exact)
        }
        // No caret bounds via AX: estimate the caret from the field frame + text +
        // font, but ONLY when AX gave us the real font. Even then it drifts per-
        // character (measured glyph widths rarely match what the app actually renders,
        // e.g. web inputs), so the caller treats this as a last resort and prefers OCR
        // when it can. Single-line only.
        if let font = resolvedFont,
           let caret = estimatedCaretRect(for: element, caretLocation: caretLocation, field: field, font: font) {
            debugLog("caretGeometry: via single-line estimate")
            return CaretGeometry(caret: caret, field: field, font: font, source: .estimated)
        }
        debugLog("caretGeometry: no caret geometry available")
        return nil
    }

    /// A rough caret rect for a single-line field that exposes no per-range bounds:
    /// measure the text up to the caret in the field's font, offset from the field's
    /// left edge. Good enough for search/login/comment inputs. Returns nil for
    /// multi-line fields (where wrapping makes this unreliable — better no ghost
    /// than a wrong one) or when the needed inputs aren't available.
    private static func estimatedCaretRect(
        for element: AXUIElement, caretLocation: Int, field: CGRect?, font: NSFont?
    ) -> CGRect? {
        guard let field, field.width > 10, field.height > 0,
              let value = stringValue(element) else { return nil }
        let font = font ?? NSFont.systemFont(ofSize: 13)
        let lineHeight = ceil(font.ascender - font.descender)
        guard lineHeight > 0, field.height <= lineHeight * 2.2 else { return nil } // single-line only
        let ns = value as NSString
        let loc = max(0, min(caretLocation, ns.length))
        let prefixWidth = (ns.substring(to: loc) as NSString).size(withAttributes: [.font: font]).width
        let caretX = min(field.minX + prefixWidth, field.maxX)
        let caretY = field.minY + max(0, (field.height - lineHeight) / 2)
        return CGRect(x: caretX, y: caretY, width: 0, height: lineHeight)
    }

    /// The element's text value (`AXValue`), or nil.
    private static func stringValue(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// The field's font, read from a 1-character attributed-string probe at the
    /// caret, so the ghost text matches the field's size (rather than guessing from
    /// the caret rect height). Nil when the app doesn't surface a font via AX.
    private static func resolveFont(for element: AXUIElement, caretLocation: Int) -> NSFont? {
        let loc = caretLocation > 0 ? caretLocation - 1 : 0
        var probe = CFRange(location: loc, length: 1)
        guard let axRange = AXValueCreate(.cfRange, &probe) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXAttributedStringForRangeParameterizedAttribute as CFString, axRange, &ref) == .success,
              let attributed = ref as? NSAttributedString, attributed.length > 0 else {
            return nil
        }
        if let nsFont = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            return nsFont
        }
        // AX exposes the font as a dictionary ({AXFontName, AXFontSize, …}) rather
        // than an NSFont.
        if let info = attributed.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any] {
            let size = (info["AXFontSize"] as? CGFloat)
                ?? (info["AXFontSize"] as? Double).map { CGFloat($0) }
                ?? NSFont.systemFontSize
            if let name = info["AXFontName"] as? String, let font = NSFont(name: name, size: size) {
                return font
            }
            return NSFont.systemFont(ofSize: size)
        }
        return nil
    }

    /// The focused element's frame in **AX top-left** display space (origin
    /// top-left of the primary display, y down) — the space `CGWindowListCreateImage`
    /// captures in. Exposed for the OCR caret tier (`ScreenOCR`), which screenshots
    /// this rect; it flips the final caret rect back to Cocoa via `flipToCocoa`.
    static func fieldFrameTopLeft(_ element: AXUIElement) -> CGRect? {
        elementFrame(element)
    }

    /// The focused element's frame (AX position + size), in Cocoa coordinates.
    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        guard let posValue = asAXValue(posRef), let sizeValue = asAXValue(sizeRef) else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &pos),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size) // AX top-left space; flipped by caller
    }

    /// Caret bounds in **Cocoa** screen coordinates (bottom-left origin), or nil.
    static func caretRect(for element: AXUIElement, caretLocation: Int) -> CGRect? {
        // Prefer the bounds of the glyph *before* the caret: non-empty ranges
        // report reliable screen bounds, whereas a zero-length (caret) range is
        // unreliable in several apps — TextEdit can return a rect at the text
        // container origin {0,0}, which after the y-flip parks the overlay at the
        // top-left of the screen. We only show suggestions when there's at least
        // one character of context, so the previous glyph exists.
        if caretLocation > 0,
           let prev = boundsForRange(element, location: caretLocation - 1, length: 1),
           prev.height > 0 {
            debugLog("caretRect: via prev-glyph bounds")
            let atCaret = CGRect(x: prev.maxX, y: prev.origin.y, width: 0, height: prev.height)
            return flipToCocoa(atCaret)
        }
        // Caret at the very start: use the glyph after it, left edge.
        if let next = boundsForRange(element, location: caretLocation, length: 1),
           next.height > 0 {
            debugLog("caretRect: via next-glyph bounds")
            let atCaret = CGRect(x: next.minX, y: next.origin.y, width: 0, height: next.height)
            return flipToCocoa(atCaret)
        }
        // Zero-length range, if the app happens to honor it.
        if let zero = boundsForRange(element, location: caretLocation, length: 0),
           zero.width > 0 || zero.height > 0 {
            debugLog("caretRect: via zero-length range")
            return flipToCocoa(zero)
        }
        // Fallback for fields that don't answer single-char bounds (e.g. Chromium
        // web content): bounds of the text from start to the caret — its right edge
        // is the caret x, and its y/height give the (single) line. Accurate for
        // single-line inputs; for a multi-line field that also lacks single-char
        // bounds it's approximate.
        if caretLocation > 0,
           let upToCaret = boundsForRange(element, location: 0, length: caretLocation),
           upToCaret.height > 0 {
            debugLog("caretRect: via start→caret bounds")
            let atCaret = CGRect(x: upToCaret.maxX, y: upToCaret.origin.y, width: 0, height: upToCaret.height)
            return flipToCocoa(atCaret)
        }
        // Web content (Safari/Chrome) typically exposes caret bounds via the
        // AXTextMarker API rather than integer ranges — this is the path that
        // actually places the ghost at the caret in a browser.
        if let marker = caretRectViaTextMarker(element) {
            debugLog("caretRect: via text-marker bounds (web)")
            return flipToCocoa(marker)
        }
        debugLog("caretRect: no geometry available")
        return nil
    }

    /// Caret bounds (AX top-left space) via the undocumented-but-stable
    /// `AXTextMarker` API that WebKit/Chromium use for web content. The text-marker
    /// attributes live on the `AXWebArea` (document), not the focused `<input>`, so
    /// we walk up the ancestor chain and try each. Returns nil if none support it.
    private static func caretRectViaTextMarker(_ element: AXUIElement) -> CGRect? {
        var current: AXUIElement? = element
        var depth = 0
        while let el = current, depth < 8 {
            if let rect = textMarkerCaretBounds(el) { return rect }
            current = axParent(of: el)
            depth += 1
        }
        return nil
    }

    private static func textMarkerCaretBounds(_ element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &rangeRef) == .success,
              let range = rangeRef else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXBoundsForTextMarkerRange" as CFString, range, &boundsRef) == .success,
              let boundsRef, let bounds = asAXValue(boundsRef) else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds, .cgRect, &rect), rect.height > 0 else { return nil }
        return rect
    }

    private static func axParent(of element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// AX bounds (top-left origin global space) for a text range.
    private static func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &boundsRef
        )
        guard err == .success, let boundsRef, let boundsValue = asAXValue(boundsRef) else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Safely bridge a CFTypeRef to `AXValue`, returning nil if it isn't one —
    /// AX values from third-party apps aren't guaranteed to be the expected type,
    /// and a force-cast would trap and crash the app.
    private static func asAXValue(_ ref: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return (ref as! AXValue)
    }

    /// Convert an AX rect (origin top-left of primary display, y down) to a
    /// Cocoa rect (origin bottom-left of primary display, y up).
    ///
    /// The flip constant is the height of the *primary* display — the one whose
    /// frame origin is (0,0), which both coordinate systems share as their
    /// origin — not just `screens.first`, which may be a secondary monitor.
    static func flipToCocoa(_ axRect: CGRect) -> CGRect {
        let primaryHeight = (NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
            ?? NSScreen.screens.first)?.frame.height ?? axRect.maxY
        let cocoaY = primaryHeight - axRect.origin.y - axRect.height
        let cocoa = CGRect(x: axRect.origin.x, y: cocoaY, width: axRect.width, height: axRect.height)
        if debugEnabled {
            NSLog("Inkline: caret AX rect \(axRect) -> Cocoa \(cocoa) (primaryH \(primaryHeight))")
        }
        return cocoa
    }
}
