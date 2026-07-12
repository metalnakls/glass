import SwiftUI

struct GlassActivityIndicator: View {
    let label: LocalizedStringKey

    var body: some View {
        Image(systemName: "progress.indicator")
            .symbolEffect(.rotate.wholeSymbol, options: .repeat(.continuous))
            .accessibilityLabel(label)
    }
}
