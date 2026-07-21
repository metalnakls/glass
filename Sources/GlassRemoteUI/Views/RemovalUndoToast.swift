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
    @GestureState private var dragTranslation: CGFloat = 0

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
        .offset(x: dragTranslation)
        .opacity(dragOpacity)
        .padding(.bottom, 14)
        .zIndex(1)
        .onAppear(perform: restartCountdown)
        .onChange(of: resetToken) { _, _ in
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
    }

    private var toastSurface: some View {
        toastContent
            .overlay(alignment: .bottomLeading) {
                if !accessibilityReduceMotion {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.95))
                            .frame(width: proxy.size.width, height: 2)
                            .scaleEffect(x: max(0, countdownProgress), anchor: .leading)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipShape(Capsule())
    }

    private var toastContent: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(message)
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
            undo()
        } label: {
            Text("Undo")
                .fontWeight(.medium)
                .foregroundStyle(.tint)
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var message: String {
        if removals.count == 1, let removal = removals.first {
            return removal.deleteData ? "Deleted data for \(removal.torrent.name)" : "Removed \(removal.torrent.name)"
        }

        if removals.allSatisfy(\.deleteData) {
            return "Deleted data for \(removals.count) torrents"
        }
        return "Removed \(removals.count) torrents"
    }

    private var iconName: String {
        removals.contains { $0.deleteData } ? "trash.slash" : "trash"
    }

    private var dragOpacity: Double {
        let distance = min(160, abs(dragTranslation))
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
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    withAnimation(accessibilityReduceMotion ? nil : .snappy(duration: 0.22)) {
                        dismiss()
                    }
                }
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
