import AppKit
import SwiftUI

/// Native trackpad deltas move the foreground; actions are cut out behind its rounded frame.
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
    var compactActions: Bool
    var commitsOnRelease: Bool
    var foregroundInset: CGFloat
    var foregroundTrailingInset: CGFloat
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 300
    @State private var committed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(selected: Bool, remove: @escaping (Bool) -> Void, presentationChanged: @escaping (Bool) -> Void,
         commitsOnRelease: Bool = false, compactActions: Bool = false, foregroundInset: CGFloat = 0, foregroundTrailingInset: CGFloat? = nil,
         leading: Action = Action(name: "Delete Torrent", symbol: "xmark", color: .yellow),
         trailing: Action = Action(name: "Delete Torrent + Data", symbol: "trash", color: .red),
         @ViewBuilder content: () -> Content) {
        self.compactActions = compactActions
        self.selected = selected; self.leading = leading; self.trailing = trailing
        self.remove = remove; self.presentationChanged = presentationChanged
        self.commitsOnRelease = commitsOnRelease; self.foregroundInset = foregroundInset
        self.foregroundTrailingInset = foregroundTrailingInset ?? foregroundInset
        self.content = content()
    }

    private var fullThreshold: CGFloat { max(180, width * 0.55) }
    var body: some View {
        ZStack(alignment: offset > 0 ? .leading : .trailing) {
            HStack(spacing: 8) {
                action(leading, data: false)
                action(trailing, data: true)
            }
            .padding(.horizontal, 12)
            .opacity(min(abs(offset) / 36, 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: offset > 0 ? .leading : .trailing)
            .mask {
                SwipeRevealMask(offset: offset, inset: foregroundInset, trailingInset: foregroundTrailingInset)
                    .fill(style: FillStyle(eoFill: true))
            }
            .allowsHitTesting(abs(offset) > 40 && !committed)
            content
                .background {
                    if abs(offset) > 0.5 && !(commitsOnRelease && selected) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(white: colorScheme == .dark ? 0.12 : 1))
                            .padding(.leading, foregroundInset).padding(.trailing, foregroundTrailingInset).padding(.vertical, 3)
                    }
                }
                .offset(x: offset)
        }
        .background(GeometryReader { proxy in Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { _, value in width = value } })
        .background(ScrollGestureAnchor(offset: offset, limit: width, changed: { value, ended, cancelled in
            guard !committed else { return }
            if ended {
                if !cancelled && commitsOnRelease && abs(value) >= 56 {
                    committed = true
                    let deleteData = abs(value) >= fullThreshold
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { offset = value.sign == .minus ? -width : width }
                    Task { @MainActor in
                        if !reduceMotion { try? await Task.sleep(for: .milliseconds(180)) }
                        remove(deleteData)
                        // A rejected/cancelled deletion restores the foreground.
                        withAnimation(.spring(duration: 0.28, bounce: 0.12)) { offset = 0 }
                        committed = false
                    }
                } else {
                    let target: CGFloat = !cancelled && !commitsOnRelease && abs(value) > 35 ? (value < 0 ? -98 : 98) : 0
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12)) { offset = target }
                }
            } else { offset = value }
        }))
        .onChange(of: abs(offset) > 0.5) { _, shown in presentationChanged(shown) }
        .onChange(of: abs(offset) >= fullThreshold) { _, crossed in
            if crossed && commitsOnRelease { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        .onChange(of: selected) { _, value in
            if !value && !committed { withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) { offset = 0 } }
        }
    }

    private func action(_ action: Action, data: Bool) -> some View {
        Button { remove(data) } label: {
            Image(systemName: action.symbol)
                .font(.system(size: compactActions ? 9 : 14, weight: .semibold))
                .foregroundStyle(action.color == .yellow ? Color.black : .white)
                .frame(width: compactActions ? 18 : 34, height: compactActions ? 18 : 34)
                .background(action.color, in: Circle())
                .scaleEffect((0.8 + 0.2 * min(abs(offset) / 80, 1)) * (data && abs(offset) >= fullThreshold ? 1.15 : 1))
                .animation(reduceMotion ? nil : .spring(duration: 0.2), value: abs(offset) >= fullThreshold)
        }
        .buttonStyle(.plain).accessibilityLabel(action.name).help(action.name)
    }
}

private struct SwipeRevealMask: Shape {
    var offset: CGFloat
    var inset: CGFloat
    var trailingInset: CGFloat
    var animatableData: CGFloat { get { offset } set { offset = newValue } }
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let card = CGRect(x: rect.minX + inset + offset, y: rect.minY + 3,
                          width: max(0, rect.width - inset - trailingInset), height: max(0, rect.height - 6))
        path.addRoundedRect(in: card, cornerSize: CGSize(width: 12, height: 12))
        return path
    }
}

private struct ScrollGestureAnchor: NSViewRepresentable {
    let offset: CGFloat
    let limit: CGFloat
    let changed: (CGFloat, Bool, Bool) -> Void
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { if !view.tracking { view.offset = offset }; view.limit = limit; view.changed = changed }

    final class Anchor: NSView {
        var offset: CGFloat = 0
        var limit: CGFloat = 300
        var changed: ((CGFloat, Bool, Bool) -> Void)?
        private var monitor: Any?
        fileprivate var tracking = false
        private var vertical = false
        private var finishTask: Task<Void, Never>?
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
                    if self.offset != 0 && !self.bounds.contains(point) { self.changed?(0, true, true) }
                    return event
                }
                if !event.momentumPhase.isEmpty { return self.tracking ? nil : event }
                if event.phase.contains(.began) || event.phase.contains(.mayBegin) { self.vertical = false }
                guard self.tracking || self.bounds.contains(point) else { return event }
                if !self.tracking {
                    guard !self.vertical else { return event }
                    if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) { self.vertical = true; return event }
                    guard abs(event.scrollingDeltaX) > 0 else { return event }
                    self.tracking = true
                }
                self.finishTask?.cancel()
                self.offset = min(self.limit * 0.95, max(-self.limit * 0.95, self.offset + event.scrollingDeltaX))
                let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
                self.changed?(self.offset, ended, event.phase.contains(.cancelled))
                if ended { self.tracking = false; self.vertical = false }
                else if event.phase.isEmpty {
                    self.finishTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled, let self else { return }
                        self.changed?(self.offset, true, false); self.tracking = false; self.vertical = false
                    }
                }
                return nil
            }
        }
        isolated deinit { finishTask?.cancel(); if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
