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
            TorrentSwipeContent(content: content)
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
        } else { TorrentSwipeContent(content: content) }
    }

    private var swipeButtons: some View {
        Group {
            Button { commit(true) } label: { Label("Delete Torrent + Data", systemImage: "trash") }
                .tint(.red)
            Button { commit(false) } label: { Label("Delete Torrent", systemImage: "xmark") }
                .tint(.yellow)
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 13, weight: .semibold))
        .controlSize(.small)
    }

    private func commit(_ data: Bool) {
        guard !committed else { return }
        committed = true
        presentationChanged(false)
        remove(data)
    }
}

/// Read live telemetry in a child body. Evaluating the builder in the swipe
/// wrapper would subscribe its buttons and AppKit anchors to every refresh.
private struct TorrentSwipeContent<Content: View>: View {
    let content: () -> Content
    var body: some View { content() }
}

private struct NativeSwipeReleaseAnchor: NSViewRepresentable {
    let released: (Bool) -> Void
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.released = released }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stop() }

    final class Anchor: NSView {
        var released: ((Bool) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            if window != nil { NativeSwipeReleaseCoordinator.shared.register(self) }
        }
        fileprivate func isOverRow(_ event: NSEvent) -> Bool {
            guard event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  let content = window?.contentView,
                  let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return false }
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
        func stop() { NativeSwipeReleaseCoordinator.shared.unregister(self) }
        isolated deinit { NativeSwipeReleaseCoordinator.shared.unregister(self) }
    }
}

/// One passive event observer serves all realized rows. Native SwiftUI retains
/// every event; only the gesture's owning row receives a release callback.
@MainActor private final class NativeSwipeReleaseCoordinator {
    static let shared = NativeSwipeReleaseCoordinator()
    private let anchors = NSHashTable<NativeSwipeReleaseAnchor.Anchor>.weakObjects()
    private var monitor: Any?
    private weak var active: NativeSwipeReleaseAnchor.Anchor?
    private var vertical = false
    private var offset: CGFloat = 0
    private var fullThreshold: CGFloat = 180

    func register(_ anchor: NativeSwipeReleaseAnchor.Anchor) {
        anchors.add(anchor)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.observe(event)
            return event
        }
    }
    func unregister(_ anchor: NativeSwipeReleaseAnchor.Anchor) {
        anchors.remove(anchor)
        if active === anchor { active = nil; offset = 0 }
        if anchors.allObjects.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
    private func observe(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
              !event.phase.isEmpty else { return }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            active = nil; vertical = false; offset = 0
        }
        if active == nil {
            guard !vertical else { return }
            if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                vertical = true
                return
            }
            guard abs(event.scrollingDeltaX) > 0,
                  let anchor = anchors.allObjects.first(where: { $0.isOverRow(event) }) else { return }
            active = anchor
            fullThreshold = max(180, anchor.bounds.width * 0.55)
        }
        guard let anchor = active, event.window === anchor.window else { return }
        offset += event.scrollingDeltaX
        guard event.phase.contains(.ended) || event.phase.contains(.cancelled) else { return }
        active = nil
        guard !event.phase.contains(.cancelled), abs(offset) >= 56 else { return }
        let deleteData = abs(offset) >= fullThreshold
        // Capture the owning row's callback now. A recycled host must never
        // dispatch this release to the replacement row after yielding.
        let released = anchor.released
        Task { @MainActor in
            await Task.yield()
            released?(deleteData)
        }
    }
}
