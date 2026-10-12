import AppKit

/// One laid-out line of ghost text: the string plus how far it is inset from the
/// overlay's left edge (only the first line is inset, to start at the caret).
private struct GhostLine {
    let text: String
    let inset: CGFloat
}

/// A flipped view that draws pre-wrapped ghost-text lines. Flipped so y grows
/// downward and the first line sits at the top (the caret's line).
private final class GhostTextView: NSView {
    var lines: [GhostLine] = []
    var attributes: [NSAttributedString.Key: Any] = [:]
    var lineHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        for (i, line) in lines.enumerated() {
            let point = NSPoint(x: line.inset, y: CGFloat(i) * lineHeight)
            (line.text as NSString).draw(at: point, withAttributes: attributes)
        }
    }
}

/// The inline "ghost text" overlay: a borderless, non-activating, transparent
/// panel that floats at the caret and shows the suggested continuation in gray.
///
/// When the focused field's bounds are known, the ghost text wraps within them
/// (first line runs from the caret to the field's right edge; overflow wraps to
/// full-width lines below) instead of running off the window edge. This mirrors
/// Cotypist / the open-source KeyType, which wrap explicitly token-by-token
/// rather than relying on Core Text's first-line indent (unreliable for this).
final class GhostTextOverlay {
    private let panel: NSPanel
    private let view = GhostTextView()

    private let debug = UserDefaults.standard.bool(forKey: "InklineDebug")
        || ProcessInfo.processInfo.environment["INKLINE_DEBUG"] != nil

    /// Parameters of the last `show`, so the overlay can advance past an accepted
    /// word without waiting for the app's Accessibility state to update.
    private var lastShow: (caret: CGRect, field: CGRect?, font: NSFont)?

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = view
    }

    /// Show `text` starting at the caret, wrapping within `field` if provided.
    /// Coordinates are Cocoa screen coordinates (bottom-left origin). `resolvedFont`
    /// is the field's real font when AX surfaced it; otherwise the size is derived
    /// from the caret height (which over/under-shoots in some apps, e.g. browsers).
    func show(text: String, caret: CGRect, field: CGRect?, font resolvedFont: NSFont? = nil) {
        let font: NSFont
        if let resolvedFont {
            font = resolvedFont
        } else {
            let fontSize = caret.height > 1 ? caret.height * 0.72 : 13
            font = NSFont.systemFont(ofSize: max(11, fontSize))
        }
        let lineHeight = ceil(font.ascender - font.descender) + 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.65),
        ]

        let lines: [GhostLine]
        let originX: CGFloat
        let containerWidth: CGFloat

        if let field, field.width > 1, caret.maxX >= field.minX, caret.maxX <= field.maxX + 1 {
            let firstLineInset = max(0, caret.maxX - field.minX)
            let firstWidth = max(1, field.maxX - caret.maxX)
            let fullWidth = max(1, field.width)
            let wrapped = Self.wrap(text: text, font: font, firstWidth: firstWidth, fullWidth: fullWidth)
            lines = wrapped.enumerated().map { index, line in
                GhostLine(text: line, inset: index == 0 ? firstLineInset : 0)
            }
            originX = field.minX
            containerWidth = fullWidth
        } else {
            // No usable field bounds — single line starting at the caret.
            lines = [GhostLine(text: text, inset: 0)]
            originX = caret.maxX
            containerWidth = (text as NSString).size(withAttributes: attributes).width + 4
        }

        let height = max(lineHeight, lineHeight * CGFloat(lines.count))
        let originY = caret.maxY - height

        view.lines = lines
        view.attributes = attributes
        view.lineHeight = lineHeight
        view.needsDisplay = true

        panel.setFrame(CGRect(x: originX, y: originY, width: containerWidth, height: height), display: true)
        view.frame = CGRect(x: 0, y: 0, width: containerWidth, height: height)
        panel.orderFrontRegardless()
        lastShow = (caret, field, font)

        if debug {
            NSLog("Inkline[overlay] caret=\(rectStr(caret)) field=\(field.map(rectStr) ?? "nil") lines=\(lines.count) -> \(lines.map(\.text))")
        }
    }

    /// Redraw `remaining` shifted right by the rendered width of an accepted
    /// `head`, so the ghost text advances instantly without re-reading the caret
    /// (used when the app's AX caret hasn't updated yet). Caret y/height carry
    /// over from the last `show`.
    func advance(remaining: String, acceptedWidthOf head: String) {
        guard let last = lastShow else { return }
        let headWidth = (head as NSString).size(withAttributes: [.font: last.font]).width
        let shifted = CGRect(x: last.caret.maxX + headWidth, y: last.caret.minY,
                             width: 0, height: last.caret.height)
        show(text: remaining, caret: shifted, field: last.field)
    }

    func hide() {
        panel.orderOut(nil)
        lastShow = nil
    }

    /// Greedy word-wrap: fill the first line up to `firstWidth` (the space from
    /// the caret to the field's right edge), then `fullWidth` for the rest.
    /// Wrapped (non-first) lines have their leading whitespace trimmed.
    static func wrap(text: String, font: NSFont, firstWidth: CGFloat, fullWidth: CGFloat) -> [String] {
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }

        // Tokenize into alternating whitespace / non-whitespace runs.
        var tokens: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            let start = i
            let isWS = text[i].isWhitespace
            while i < text.endIndex, text[i].isWhitespace == isWS { i = text.index(after: i) }
            tokens.append(String(text[start..<i]))
        }

        var lines: [String] = []
        var current = ""
        var capacity = max(1, firstWidth)

        func flush() {
            lines.append(current)
            current = ""
            capacity = max(1, fullWidth)
        }

        for token in tokens {
            let isWS = token.first?.isWhitespace ?? false
            // Drop whitespace that would start a wrapped line.
            if current.isEmpty, !lines.isEmpty, isWS { continue }
            if !current.isEmpty, width(current + token) > capacity {
                flush()
                if isWS { continue } // don't start the new line with the break's space
            }
            current += token
        }
        if !current.isEmpty || lines.isEmpty { lines.append(current) }
        return lines
    }

    private func rectStr(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.width, r.height)
    }
}
