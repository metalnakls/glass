import AppKit
import SwiftUI

/// A full-width action plane under a moving foreground. Native scroll events
/// drive it; row padding belongs to the foreground and never clips the buttons.
struct TorrentSwipeRow<Content: View>: View {
    struct Action {
        let name: String
        let symbol: String
        let color: Color
    }
    let content: Content
    let leading: Action
    let trailing: Action
    let remove: (Bool) -> Void
    let presentationChanged: (Bool) -> Void
    let selected: Bool
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(selected: Bool, remove: @escaping (Bool) -> Void, presentationChanged: @escaping (Bool) -> Void,
         leading: Action = Action(name: "Delete Torrent", symbol: "xmark", color: .yellow),
         trailing: Action = Action(name: "Delete Torrent + Data", symbol: "trash", color: .red),
         @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.leading = leading
        self.trailing = trailing
        self.remove = remove
        self.presentationChanged = presentationChanged
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 8) {
                action(leading.name, symbol: leading.symbol, color: leading.color, data: false)
                action(trailing.name, symbol: trailing.symbol, color: trailing.color, data: true)
            }
            .padding(.trailing, 10)
            .opacity(offset < -0.5 ? 1 : 0)
            .allowsHitTesting(offset < -0.5)
            content.offset(x: offset)
        }
        .background(ScrollGestureAnchor(offset: offset, changed: { value, ended in
            let target = ended ? (value < -35 ? CGFloat(-98) : 0) : value
            withAnimation(ended && !reduceMotion ? .snappy(duration: 0.22) : nil) { offset = target }
        }))
        .onChange(of: offset < -0.5) { _, shown in presentationChanged(shown) }
        .onChange(of: selected) { _, value in
            if !value { withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { offset = 0 } }
        }
    }

    private func action(_ name: String, symbol: String, color: Color, data: Bool) -> some View {
        Button { remove(data) } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color == .yellow ? Color.black : .white)
                .frame(width: 34, height: 34)
                .background(color, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .help(name)
    }
}

private struct ScrollGestureAnchor: NSViewRepresentable {
    let offset: CGFloat
    let changed: (CGFloat, Bool) -> Void
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.offset = offset; view.changed = changed }

    final class Anchor: NSView {
        var offset: CGFloat = 0
        var changed: ((CGFloat, Bool) -> Void)?
        private var monitor: Any?
        private var tracking = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if event.type == .leftMouseDown {
                    if self.offset != 0 && !self.bounds.contains(point) { self.changed?(0, true) }
                    return event
                }
                guard self.tracking || self.bounds.contains(point) else { return event }
                if !self.tracking {
                    guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), abs(event.scrollingDeltaX) > 0 else { return event }
                    self.tracking = true
                }
                let value = min(0, max(-110, self.offset + event.scrollingDeltaX))
                self.offset = value
                let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
                self.changed?(value, ended)
                if ended { self.tracking = false }
                return nil
            }
        }
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
