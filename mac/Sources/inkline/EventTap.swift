import AppKit
import CoreGraphics

/// Virtual key codes we care about.
enum KeyCode {
    static let tab: CGKeyCode = 48
    static let escape: CGKeyCode = 53
    /// The `` ` `` (backtick) key, left of the `1` key.
    static let backtick: CGKeyCode = 50
}

/// A `CGEventTap` on key + mouse/scroll events. The owner decides per-keystroke
/// whether to consume the event (e.g. Tab to accept a suggestion); mouse and
/// scroll events are never consumed — they just signal "dismiss any suggestion".
///
/// The tap is attached to the main run loop, so callbacks run on the main thread
/// and may safely touch AppKit / Accessibility.
final class EventTap {
    /// Return `true` to consume the keystroke, `false` to let it pass through.
    var onKeyDown: ((CGKeyCode, CGEventFlags) -> Bool)?
    /// Fired (never consuming) on a mouse-down or scroll — a cue that the caret
    /// context likely moved, so a shown suggestion should be dismissed.
    var onDismissCue: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Create and enable the tap. Returns false if creation failed (usually
    /// means Accessibility permission is not granted).
    func start() -> Bool {
        let interested: [CGEventType] = [
            .keyDown,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel,
        ]
        let mask = interested.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system can disable a tap that's too slow or on user input; re-arm.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            if let onKeyDown {
                let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                if onKeyDown(keyCode, event.flags) {
                    return nil // consumed
                }
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            onDismissCue?()
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
