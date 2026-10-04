import AppKit
import SwiftUI

/// SwiftUI owns button layout, reveal motion and foreground movement.
/// The passive release observer preserves Glass's short/long swipe semantics.
struct TorrentNativeSwipeRow<Content: View>: View {
    let enabled: Bool
    let remove: (Bool) -> Void
    let presentationChanged: (Bool) -> Void
    @ViewBuilder let content: () -> Content
    @State private var committed = false

    var body: some View {
        if enabled {
            content()
                .swipeActionsContainer()
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    swipeButtons
                } onPresentationChanged: { presentationChanged($0) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    swipeButtons
                } onPresentationChanged: { presentationChanged($0) }
                .background {
                    NativeSwipeReleaseAnchor { deleteData in commit(deleteData) }
                }
                .onDisappear { presentationChanged(false) }
        } else { content() }
    }

    private var swipeButtons: some View {
        Group {
            Button { commit(true) } label: { Label("Delete Torrent + Data", systemImage: "trash") }
                .tint(.red)
            Button { commit(false) } label: { Label("Delete Torrent", systemImage: "xmark") }
                .tint(.yellow)
        }
    }

    private func commit(_ data: Bool) {
        guard !committed else { return }
        committed = true
        presentationChanged(false)
        remove(data)
    }
}

private struct NativeSwipeReleaseAnchor: NSViewRepresentable {
    let released: (Bool) -> Void
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.released = released }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stop() }

    final class Anchor: NSView {
        var released: ((Bool) -> Void)?
        private var monitor: Any?
        private var tracking = false
        private var vertical = false
        private var offset: CGFloat = 0
        private var fullThreshold: CGFloat = 180
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
                      !event.phase.isEmpty else { return event }
                if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                    self.tracking = false; self.vertical = false; self.offset = 0
                }
                if !self.tracking {
                    guard !self.vertical, self.isOverRow(event) else { return event }
                    if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                        self.vertical = true
                        return event
                    }
                    guard abs(event.scrollingDeltaX) > 0 else { return event }
                    self.tracking = true
                    self.fullThreshold = max(180, self.bounds.width * 0.55)
                }
                self.offset += event.scrollingDeltaX
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                    self.tracking = false
                    if !event.phase.contains(.cancelled), abs(self.offset) >= 56 {
                        let deleteData = abs(self.offset) >= self.fullThreshold
                        // Let SwiftUI finish processing the release before changing rows.
                        Task { @MainActor [weak self] in
                            await Task.yield()
                            self?.released?(deleteData)
                        }
                    }
                }
                return event
            }
        }
        private func isOverRow(_ event: NSEvent) -> Bool {
            guard bounds.contains(convert(event.locationInWindow, from: nil)),
                  let window, let hit = window.contentView?.hitTest(window.contentView!.convert(event.locationInWindow, from: nil)) else { return false }
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    let ownRow = table.row(for: self)
                    return ownRow >= 0 && table.row(for: hit) == ownRow
                }
                ancestor = view.superview
            }
            return false
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            tracking = false; vertical = false; offset = 0
        }
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
