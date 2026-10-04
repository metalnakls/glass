import AppKit
import SwiftUI

/// A toast owns only horizontal trackpad gestures that begin over its surface.
/// Vertical scrolling and clicks continue through the normal responder chain.
struct ToastTrackpadSwipe: NSViewRepresentable {
    let resetToken: UUID
    let changed: (CGFloat, Bool, Bool) -> Void

    func makeNSView(context: Context) -> Receiver { Receiver() }
    func updateNSView(_ view: Receiver, context: Context) {
        if view.resetToken != resetToken { view.reset(); view.resetToken = resetToken }
        view.changed = changed
    }
    static func dismantleNSView(_ view: Receiver, coordinator: ()) { view.stop() }

    final class Receiver: NSView {
        var resetToken: UUID?
        var changed: ((CGFloat, Bool, Bool) -> Void)?
        private var monitor: Any?
        private var gesture = ToastSwipeMotion()
        private var swallowingMomentum = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window, event.hasPreciseScrollingDeltas else { return event }
                if !event.momentumPhase.isEmpty {
                    let consume = self.swallowingMomentum
                    if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                        self.swallowingMomentum = false
                    }
                    return consume ? nil : event
                }
                // Ignore wheel input without trackpad gesture phases.
                guard !event.phase.isEmpty else { return event }
                if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                    self.reset()
                }
                let overToast = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                guard self.gesture.tracking || overToast else { return event }
                let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
                let cancelled = event.phase.contains(.cancelled)
                guard self.gesture.update(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                                          timestamp: event.timestamp, ended: ended) else { return event }
                let offset = self.gesture.offset
                let dismiss = !cancelled && self.gesture.shouldDismiss
                self.changed?(offset, ended, dismiss)
                if ended {
                    self.swallowingMomentum = true
                    self.gesture = ToastSwipeMotion()
                }
                return nil
            }
        }

        func reset() { gesture = ToastSwipeMotion(); swallowingMomentum = false }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            reset()
        }
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct ToastSwipeMotion {
    private(set) var tracking = false
    private var vertical = false
    private(set) var offset: CGFloat = 0
    private var velocity: CGFloat = 0
    private var lastTimestamp: TimeInterval?
    private var lastMotionTimestamp: TimeInterval?
    private var timestamp: TimeInterval = 0

    mutating func update(x: CGFloat, y: CGFloat, timestamp: TimeInterval, ended: Bool) -> Bool {
        self.timestamp = timestamp
        if !tracking {
            guard !vertical else { return false }
            if abs(y) > abs(x) { vertical = true; return false }
            guard abs(x) > 0 else { return false }
            tracking = true
        }
        if x != 0 {
            if let lastTimestamp, timestamp > lastTimestamp {
                velocity = x / CGFloat(max(0.008, timestamp - lastTimestamp))
            }
            offset += x
            lastMotionTimestamp = timestamp
        }
        if !ended { lastTimestamp = timestamp }
        return true
    }

    var shouldDismiss: Bool {
        if abs(offset) > 56 { return true }
        // A deliberate pause before lifting must not count as a fast flick.
        guard let lastMotionTimestamp, timestamp - lastMotionTimestamp < 0.1 else { return false }
        return abs(offset + velocity * 0.12) > 120
    }
}
