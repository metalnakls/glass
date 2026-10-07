import AppKit
import SwiftUI

/// Selection observes the event; SwiftUI owns the native menu and recognizer lifecycle.
/// Never run a modal menu inside a custom gesture recognizer callback: removing its
/// row from that menu can destroy the recognizer before its event handler returns.
struct SecondaryClickSelectionGesture: NSViewRepresentable {
    let action: (NSEvent, NSView) -> Void
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.action = action }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stop() }

    final class Anchor: NSView {
        var action: ((NSEvent, NSView) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            if window != nil { SecondaryClickSelectionObserver.shared.register(self) }
        }
        func stop() {
            SecondaryClickSelectionObserver.shared.unregister(self)
            if window == nil { action = nil }
        }
        isolated deinit { SecondaryClickSelectionObserver.shared.unregister(self) }
    }
}

@MainActor private final class SecondaryClickSelectionObserver {
    static let shared = SecondaryClickSelectionObserver()
    private let anchors = NSHashTable<SecondaryClickSelectionGesture.Anchor>.weakObjects()
    private var monitor: Any?

    func register(_ anchor: SecondaryClickSelectionGesture.Anchor) {
        anchors.add(anchor)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  let anchor = self?.anchors.allObjects.first(where: {
                      event.window === $0.window && $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
                  }) else { return event }
            anchor.action?(event, anchor)
            return event
        }
    }
    func unregister(_ anchor: SecondaryClickSelectionGesture.Anchor) {
        anchors.remove(anchor)
        guard anchors.allObjects.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
