import SwiftUI

struct RemovalUndoToast: View {
    let removals: [PendingTorrentRemoval]
    let resetToken: UUID
    let duration: TimeInterval
    let undo: () -> Void
    let dismiss: () -> Void

    @State private var countdownProgress = 1.0
    @State private var countdownTask: Task<Void, Never>?
    @GestureState private var dragTranslation = CGSize.zero

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
        .offset(x: dragOffset.width, y: dragOffset.height)
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
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.95))
                        .frame(width: max(0, proxy.size.width * CGFloat(countdownProgress)), height: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .allowsHitTesting(false)
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

    private var dragOffset: CGSize {
        dragTranslation
    }

    private var dragOpacity: Double {
        let distance = min(160, hypot(dragOffset.width, dragOffset.height))
        return 1 - Double(distance / 260)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                if shouldDismiss(with: value) {
                    withAnimation(.snappy(duration: 0.22)) {
                        dismiss()
                    }
                }
            }
    }

    private func shouldDismiss(with value: DragGesture.Value) -> Bool {
        let translation = value.translation
        let predicted = value.predictedEndTranslation
        let distance = hypot(translation.width, translation.height)
        let predictedDistance = hypot(predicted.width, predicted.height)
        return distance > 44 || predictedDistance > 90
    }

    private func restartCountdown() {
        countdownTask?.cancel()

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
