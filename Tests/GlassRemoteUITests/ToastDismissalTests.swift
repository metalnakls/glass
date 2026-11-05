import AppKit
import SwiftUI
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Toast dismissal delivery", .serialized)
struct ToastDismissalTests {
    @Test("trackpad dismissal runs after the callback without a timed pause", arguments: [-1.0, 1.0])
    func trackpadDismissal(direction: Double) async throws {
        _ = NSApplication.shared
        var calls = 0
        let toast = RemovalUndoToast(removals: [], resetToken: UUID(), duration: 12,
            undo: {}, dismiss: { calls += 1 })
        let host = NSHostingView(rootView: toast)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 520, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        func receiver(in view: NSView) -> ToastTrackpadSwipe.Receiver? {
            if let receiver = view as? ToastTrackpadSwipe.Receiver { return receiver }
            return view.subviews.lazy.compactMap { receiver(in: $0) }.first
        }
        let trackpad = try #require(receiver(in: host))
        // Use the closure installed by the real toast, not a duplicate state model.
        trackpad.changed?(35 * direction, false, false)
        trackpad.changed?(70 * direction, true, true)
        #expect(calls == 0, "Do not destroy the gesture host inside its callback")
        let delivered = await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume(returning: calls) }
        }
        #expect(delivered == 1, "A completed swipe must not leave the toast parked for a timer")
    }

    @Test("a short trackpad swipe leaves Undo available")
    func shortSwipe() async throws {
        _ = NSApplication.shared
        var calls = 0
        let host = NSHostingView(rootView: RemovalUndoToast(removals: [], resetToken: UUID(), duration: 12,
            undo: {}, dismiss: { calls += 1 }))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 100)
        host.layoutSubtreeIfNeeded()
        func receiver(in view: NSView) -> ToastTrackpadSwipe.Receiver? {
            if let receiver = view as? ToastTrackpadSwipe.Receiver { return receiver }
            return view.subviews.lazy.compactMap { receiver(in: $0) }.first
        }
        let trackpad = try #require(receiver(in: host))
        trackpad.changed?(10, true, false)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(calls == 0)
    }
}
