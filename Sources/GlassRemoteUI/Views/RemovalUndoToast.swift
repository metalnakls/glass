import AppKit
import SwiftUI

struct RemovalUndoToast: View {
    let removals: [PendingTorrentRemoval]
    let resetToken: UUID
    let duration: TimeInterval
    let undo: () -> Void
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var countdownProgress = 1.0
    @State private var countdownTask: Task<Void, Never>?
    @AppStorage("GlassList.showExtensions") private var showExtensions = false
    @GestureState private var dragTranslation: CGFloat = 0
    @State private var trackpadTranslation: CGFloat = 0

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 0) {
                    interactiveToastSurface
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
            } else {
                interactiveToastSurface
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(.separator.opacity(0.35), lineWidth: 1)
                    }
                    .shadow(radius: 8, y: 3)
            }
        }
        .font(.callout)
        .frame(maxWidth: 520)
        .offset(x: dragTranslation + trackpadTranslation)
        .opacity(dragOpacity)
        .padding(.bottom, 14)
        .zIndex(1)
        .onAppear(perform: restartCountdown)
        .onChange(of: resetToken) { _, _ in
            trackpadTranslation = 0
            restartCountdown()
        }
        .onDisappear {
            countdownTask?.cancel()
        }
    }

    private var interactiveToastSurface: some View {
        toastSurface
            .contentShape(Capsule())
            .highPriorityGesture(dismissGesture, including: .all)
            .background {
                ToastTrackpadSwipe(resetToken: resetToken) { offset, ended, shouldDismiss in
                    if ended {
                        withAnimation(GlassMotion.animation(.undo, reduceMotion: accessibilityReduceMotion)) {
                            if shouldDismiss {
                                trackpadTranslation = offset
                                GlassHaptics.perform(.swipe)
                                finishGesture(dismiss)
                            } else { trackpadTranslation = 0 }
                        }
                    } else {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { trackpadTranslation = offset }
                    }
                }
            }
    }

    private var toastSurface: some View {
        toastContent
            .overlay(alignment: .bottomLeading) {
                if !accessibilityReduceMotion {
                    ToastCountdownContour(progress: countdownProgress)
                        .fill(.white.opacity(colorScheme == .light ? 1 : 0.7))
                        .shadow(color: .black.opacity(colorScheme == .light ? 0.4 : 0), radius: 0.5, y: 0.5)
                        .padding(1)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(Capsule())
    }

    private var toastContent: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .frame(width: 18)

            Text(message).textCase(nil)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 320, alignment: .leading)
                .layoutPriority(1)

            undoButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 36)
    }

    private var undoButton: some View {
        Button {
            finishGesture(undo)
        } label: {
            Text(glassText("Undo"))
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var message: String {
        if removals.count == 1, let removal = removals.first {
            let title = showExtensions ? removal.torrent.name : TorrentExtensionPolicy.name(removal.torrent.name,
                hiding: TorrentExtensionPolicy.hiddenExtension(paths: [removal.torrent.name]))
            return "\(glassText(removal.deleteData ? "Deleted data for" : "Removed")) \(title)"
        }

        if removals.allSatisfy(\.deleteData) {
            return glassText("Deleted data for \(removals.count) torrents")
        }
        return glassText("Removed \(removals.count) torrents")
    }

    private var iconName: String {
        TorrentRemovalStyle.symbol(deleteData: removals.contains { $0.deleteData })
    }

    private var dragOpacity: Double {
        let distance = min(160, abs(dragTranslation + trackpadTranslation))
        return 1 - Double(distance / 260)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragTranslation) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    state = 0
                    return
                }
                state = value.translation.width
            }
            .onEnded { value in
                if shouldDismiss(with: value) {
                    GlassHaptics.perform(.swipe)
                    withAnimation(GlassMotion.animation(.undo, reduceMotion: accessibilityReduceMotion)) {
                        finishGesture(dismiss)
                    }
                }
            }
    }

    private func finishGesture(_ action: @escaping () -> Void) {
        // Let the current input callback unwind before removing its gesture host.
        // A timed sleep parks the toast at the release position; one main-queue
        // turn provides the same reentrancy boundary without a visible pause.
        DispatchQueue.main.async {
            action()
        }
    }

    private func shouldDismiss(with value: DragGesture.Value) -> Bool {
        guard abs(value.translation.width) > abs(value.translation.height) else { return false }
        return abs(value.translation.width) > 56 || abs(value.predictedEndTranslation.width) > 120
    }

    private func restartCountdown() {
        countdownTask?.cancel()

        guard !accessibilityReduceMotion else {
            countdownProgress = 0
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            countdownProgress = 1
        }

        countdownTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            withAnimation(GlassMotion.countdown(duration: duration)) {
                countdownProgress = 0
            }
        }
    }
}

/// A fine specular highlight on the lower glass edge. Only the tips taper;
/// stretching the taper over the full countdown produces a broad underline.
private struct ToastCountdownContour: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.height, rect.width) / 2
        guard radius > 0, progress > 0 else { return Path() }
        let arcLength = .pi * radius / 2
        let straightLength = max(0, rect.width - 2 * radius)
        let visibleLength = (2 * arcLength + straightLength) * min(1, progress)
        // A one-point rim highlight, with tips no longer than a rounded end.
        // Short remnants also thin out rather than ending in a bright dot.
        let thickness = min(1, visibleLength / 12)
        let tipLength = min(arcLength, visibleLength / 2)
        let steps = max(2, Int(ceil(visibleLength)))
        var outer: [CGPoint] = []
        var inner: [CGPoint] = []

        for step in 0...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let distance = visibleLength * fraction
            let point: CGPoint
            let inward: CGVector
            if distance < arcLength {
                let angle = .pi - distance / radius
                point = CGPoint(x: rect.minX + radius + radius * cos(angle),
                                y: rect.midY + radius * sin(angle))
                inward = CGVector(dx: -cos(angle), dy: -sin(angle))
            } else if distance <= arcLength + straightLength {
                point = CGPoint(x: rect.minX + radius + distance - arcLength, y: rect.maxY)
                inward = CGVector(dx: 0, dy: -1)
            } else {
                let angle = .pi / 2 - (distance - arcLength - straightLength) / radius
                point = CGPoint(x: rect.maxX - radius + radius * cos(angle),
                                y: rect.midY + radius * sin(angle))
                inward = CGVector(dx: -cos(angle), dy: -sin(angle))
            }
            let tipProgress = min(1, min(distance, visibleLength - distance) / tipLength)
            let width = thickness * sin(.pi / 2 * tipProgress)
            outer.append(point)
            inner.append(CGPoint(x: point.x + inward.dx * width, y: point.y + inward.dy * width))
        }

        var path = Path()
        path.addLines(outer + inner.reversed())
        path.closeSubpath()
        return path
    }
}
