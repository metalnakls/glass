import SwiftUI

struct GlassActivityIndicator: View {
    let label: LocalizedStringKey

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .accessibilityLabel(label)
    }
}
