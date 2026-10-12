import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

/// OCR caret tier — the last resort for placing ghost text in apps that expose no
/// caret bounds and no font via Accessibility (Chromium/Electron). Accessibility
/// still gives us the field's **text** and the caret **char-offset**; this finds
/// the caret's **pixel position** (and a usable font size) by screenshotting the
/// field and running Vision text recognition over it.
///
/// Phase 1 scope: **single-line** inputs (search / login / comment boxes). Multi-
/// line and canvas editors (Google Docs) are out of scope. Reference prior art:
/// KeyType's `ScreenTextOCR.swift`.
///
/// All OS I/O lives shell-side — the Rust core never touches this.
enum ScreenOCR {
    /// Padding added around the field rect before capture, so a caret hugging an
    /// edge still has its glyph fully in frame.
    private static let capturePadding: CGFloat = 6

    /// Locate the caret by screenshotting `fieldTopLeft` (AX top-left display space)
    /// and OCR'ing it. `completion` is always called on the **main thread**; nil
    /// means we couldn't place the caret (caller should show nothing). OCR requires
    /// macOS 14+ (ScreenCaptureKit screenshots); older systems no-op.
    static func locateCaret(
        element: AXUIElement,
        value: String,
        caretLocation: Int,
        fieldTopLeft: CGRect,
        completion: @escaping (AXReader.CaretGeometry?) -> Void
    ) {
        guard fieldTopLeft.width > 4, fieldTopLeft.height > 4 else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        guard #available(macOS 14.0, *) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let captureRect = fieldTopLeft.insetBy(dx: -capturePadding, dy: -capturePadding)
        let fieldCocoa = AXReader.flipToCocoa(fieldTopLeft)

        Task.detached(priority: .userInitiated) {
            let image = await capture(captureRect)
            let geometry = image.flatMap {
                resolveImage($0, value: value, caretLocation: caretLocation,
                             captureRect: captureRect, fieldCocoa: fieldCocoa)
            }
            await MainActor.run { completion(geometry) }
        }
    }

    // MARK: - Capture (ScreenCaptureKit)

    /// Screenshot `rect` (AX top-left display space) via ScreenCaptureKit. We capture
    /// the whole containing display at native resolution and **crop the CGImage**
    /// ourselves to the field region — `SCStreamConfiguration.sourceRect` is
    /// unreliable for display filters (it may not crop at all, yielding the full
    /// display and a badly compressed coordinate mapping). The returned image
    /// therefore corresponds exactly to `rect`, so Vision's normalized coords map
    /// straight back onto it.
    @available(macOS 14.0, *)
    private static func capture(_ rect: CGRect) async -> CGImage? {
        do {
            let content = try await SCShareableContent.current
            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(center) })
                    ?? content.displays.first else {
                debugLog("OCR: no display for rect")
                return nil
            }
            let scale = displayScale(display.displayID)
            let config = SCStreamConfiguration()
            config.width = max(1, Int(display.frame.width * scale))
            config.height = max(1, Int(display.frame.height * scale))
            config.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let full = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )

            // Crop to the field region. The image is top-left origin, in pixels;
            // derive the pixel scale from the image vs the display's point size.
            let sx = CGFloat(full.width) / display.frame.width
            let sy = CGFloat(full.height) / display.frame.height
            let cropPx = CGRect(
                x: (rect.minX - display.frame.minX) * sx,
                y: (rect.minY - display.frame.minY) * sy,
                width: rect.width * sx,
                height: rect.height * sy
            ).integral
            guard let crop = full.cropping(to: cropPx) else {
                debugLog("OCR: crop failed (rect \(NSStringFromRect(cropPx)) vs image \(full.width)x\(full.height))")
                return nil
            }
            return crop
        } catch {
            debugLog("OCR: capture failed: \(error)")
            return nil
        }
    }

    /// Backing scale (points→pixels) for a display, via its matching NSScreen.
    private static func displayScale(_ id: CGDirectDisplayID) -> CGFloat {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id
        }) {
            return screen.backingScaleFactor
        }
        return 2
    }

    // MARK: - Recognition + mapping (off-main)

    private static func resolveImage(
        _ image: CGImage, value: String, caretLocation: Int, captureRect: CGRect, fieldCocoa: CGRect
    ) -> AXReader.CaretGeometry? {
        // Recognize text. Don't let Vision "correct" what the user actually typed.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            debugLog("OCR: Vision perform failed: \(error)")
            return nil
        }
        let observations = request.results ?? []
        guard !observations.isEmpty else {
            debugLog("OCR: no text recognized")
            return nil
        }

        // 3. Pick the line that matches the field text, then find the caret x.
        guard let chosen = bestObservation(observations, value: value),
              let candidate = chosen.topCandidates(1).first else {
            debugLog("OCR: no usable observation")
            return nil
        }
        let lineBox = chosen.boundingBox // normalized, bottom-left origin
        let caretNormX = caretNormalizedX(
            caretLocation: caretLocation, value: value, candidate: candidate, lineBox: lineBox
        )
        debugLog("OCR: matched \"\(candidate.string)\" caretNormX \(caretNormX) lineBox \(NSStringFromRect(lineBox))")

        // 4. Map normalized (within the capture image == captureRect) → top-left
        // display space → Cocoa. Normalized coords map directly onto captureRect, so
        // the Retina backing scale cancels out.
        let caretX = captureRect.minX + caretNormX * captureRect.width
        let topY = captureRect.minY + (1 - lineBox.maxY) * captureRect.height
        let lineHeight = lineBox.height * captureRect.height
        let caretTopLeft = CGRect(x: caretX, y: topY, width: 0, height: max(1, lineHeight))
        let caretCocoa = AXReader.flipToCocoa(caretTopLeft)

        // Vision's line box spans roughly the glyph extent; ~0.8 of it is a good font
        // point size for the ghost. (Tunable — verify live against real fields.)
        let fontSize = max(11, lineHeight * 0.8)
        let font = NSFont.systemFont(ofSize: fontSize)

        debugLog("OCR: caret via OCR at \(NSStringFromRect(caretCocoa)) (lineH \(lineHeight))")
        return AXReader.CaretGeometry(caret: caretCocoa, field: fieldCocoa, font: font)
    }

    // MARK: - Caret location within the recognized line

    /// Normalized x (0…1 across the capture image) of the caret. Prefers the right
    /// edge of the recognized glyph just before the caret; falls back to proportional
    /// placement across the line, or the line's left edge for an empty field.
    private static func caretNormalizedX(
        caretLocation: Int, value: String, candidate: VNRecognizedText, lineBox: CGRect
    ) -> CGFloat {
        if value.isEmpty || caretLocation <= 0 {
            return lineBox.minX
        }
        let s = candidate.string
        // Caret offset is an index into `value`; for a single-line field the OCR
        // string closely tracks it, so clamp the same offset into `s`.
        if !s.isEmpty,
           let end = s.index(s.startIndex, offsetBy: min(caretLocation, s.count), limitedBy: s.endIndex),
           end > s.startIndex,
           let box = try? candidate.boundingBox(for: s.startIndex..<end) {
            return box.boundingBox.maxX
        }
        // Fallback: interpolate by character fraction across the line.
        let frac = min(1, CGFloat(caretLocation) / CGFloat(max(1, value.count)))
        return lineBox.minX + frac * lineBox.width
    }

    /// Choose the observation whose recognized text best matches the field value:
    /// longest common (case-folded, whitespace-stripped) prefix, tie-broken by the
    /// widest box (the dominant text line). For an empty field, the widest box.
    private static func bestObservation(
        _ observations: [VNRecognizedTextObservation], value: String
    ) -> VNRecognizedTextObservation? {
        let target = normalize(value)
        return observations.max { a, b in
            score(a, target: target) < score(b, target: target)
        }
    }

    private static func score(_ obs: VNRecognizedTextObservation, target: String) -> (Int, CGFloat) {
        let width = obs.boundingBox.width
        guard !target.isEmpty, let candidate = obs.topCandidates(1).first else {
            return (0, width)
        }
        return (commonPrefixLength(normalize(candidate.string), target), width)
    }

    private static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) })
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        var i = a.startIndex
        var j = b.startIndex
        while i < a.endIndex, j < b.endIndex, a[i] == b[j] {
            count += 1
            i = a.index(after: i)
            j = b.index(after: j)
        }
        return count
    }

    private static func debugLog(_ message: @autoclosure () -> String) {
        if AXReader.debugEnabled { NSLog("Inkline: %@", message()) }
    }
}
