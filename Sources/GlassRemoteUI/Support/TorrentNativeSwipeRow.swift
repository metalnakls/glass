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
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    removalButton(deleteData: false)
                } onPresentationChanged: { presentationChanged($0) }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    removalButton(deleteData: true)
                } onPresentationChanged: { presentationChanged($0) }
                .onDisappear { presentationChanged(false) }
        } else { TorrentSwipeContent(content: content) }
    }

    private func removalButton(deleteData: Bool) -> some View {
        Button { commit(deleteData) } label: {
            Image(systemName: TorrentRemovalStyle.symbol(deleteData: deleteData))
                .symbolRenderingMode(.palette)
                .foregroundStyle(deleteData ? Color.white : Color.black)
        }
        .accessibilityLabel(glassText(deleteData ? "Delete Torrent + Data" : "Remove Torrent"))
        .tint(deleteData ? .red : .yellow)
        .labelStyle(.iconOnly)
        .font(.system(size: 13, weight: .semibold))
        .controlSize(.small)
    }

    private func commit(_ data: Bool) {
        guard !committed else { return }
        committed = true
        GlassHaptics.perform(.swipe)
        presentationChanged(false)
        let action = remove
        Task { @MainActor in
            // Finish the native action gesture before removing its hosting row.
            // Destruction inside the recognizer callback can re-enter AppKit hit testing.
            try? await Task.sleep(for: .milliseconds(240))
            committed = false
            action(data)
        }
    }
}

/// Read live telemetry in a child body. Evaluating the builder in the swipe
/// wrapper would subscribe its buttons and AppKit anchors to every refresh.
private struct TorrentSwipeContent<Content: View>: View {
    let content: () -> Content
    var body: some View { content() }
}
