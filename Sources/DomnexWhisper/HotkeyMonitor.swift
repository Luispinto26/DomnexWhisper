import CoreGraphics
import Foundation

/// Watches a single modifier key system-wide with a listen-only CGEventTap.
/// Holding the key alone means "dictate"; pressing any other key while it is held
/// means it was part of a shortcut (e.g. ⌥2 = @ on a Portuguese keyboard), so the
/// dictation is cancelled. Requires the Accessibility permission.
final class HotkeyMonitor {
    var hotkey: Hotkey
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false
    private var cancelled = false

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    var isRunning: Bool { tap != nil }

    /// Returns false when the tap cannot be created, which means Accessibility has not been granted yet.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isDown = false
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            NSLog("DomnexWhisper: event tap disabled by the system, re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if isDown && !cancelled {
                // Only the fact that another key was pressed is logged, never which one.
                NSLog("DomnexWhisper: hotkey cancelled (another key pressed while held)")
                cancelled = true
                onCancel?()
            }
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == hotkey.keyCode else { return }
            let pressed = event.flags.contains(hotkey.flag)
            if pressed && !isDown {
                NSLog("DomnexWhisper: hotkey %@ pressed", hotkey.rawValue)
                isDown = true
                cancelled = false
                onPress?()
            } else if !pressed && isDown {
                NSLog("DomnexWhisper: hotkey %@ released", hotkey.rawValue)
                isDown = false
                if !cancelled { onRelease?() }
            }
        default:
            break
        }
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
