import AppKit
import SwiftUI

struct RemovalUndoToast: View {
    let removals: [PendingTorrentRemoval]
    let resetToken: UUID
    let duration: TimeInterval
    let undo: () -> Void
    let dismiss: () -> Void

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
                        withAnimation(accessibilityReduceMotion ? nil : .snappy(duration: 0.22)) {
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
                    ToastCountdownContour()
                        .trim(from: 0, to: max(0, countdownProgress))
                        .stroke(Color.primary.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
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
                    withAnimation(accessibilityReduceMotion ? nil : .snappy(duration: 0.22)) {
                        finishGesture(dismiss)
                    }
                }
            }
    }

    private func finishGesture(_ action: @escaping () -> Void) {
        // Removing this toast in its own recognizer callback can deallocate
        // SwiftUI's gesture source while AppKit is still hit testing it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
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
            withAnimation(.linear(duration: duration)) {
                countdownProgress = 0
            }
        }
    }
}

/// The countdown follows the lower capsule edge, including its rounded ends.
/// It is part of the toast's boundary, rather than another line beneath its label.
private struct ToastCountdownContour: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.height / 2, rect.width / 2)
        let k: CGFloat = 0.5522847498
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            control1: CGPoint(x: rect.minX, y: rect.maxY - radius + k * radius),
            control2: CGPoint(x: rect.minX + radius - k * radius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
            control1: CGPoint(x: rect.maxX - radius + k * radius, y: rect.maxY),
            control2: CGPoint(x: rect.maxX, y: rect.maxY - radius + k * radius))
        return path
    }
}
