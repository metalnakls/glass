import SwiftUI

/// Missing data is an app-owned status, never a fabricated preview document.
struct GlassUnavailablePreview: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ContentUnavailableView(glassText("No data found"), systemImage: "questionmark.folder")
            .frame(width: GlassModalMetrics.addTorrent.width, height: GlassModalMetrics.addTorrent.height)
            .glassFloatingChrome(top: { EmptyView() }, bottom: {
                HStack {
                    GlassPillButton(iconOnly: true) { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(glassText("Close"))
                    Spacer()
                }
            })
            .onExitCommand { dismiss() }
    }
}
