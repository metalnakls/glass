import SwiftUI

/// One trailing control envelope for transfer, retry, and draft resume actions.
/// Keep native glass inside the shared breathing room used by row columns.
struct TorrentRowStateSlot: ViewModifier {
    let compact: Bool

    func body(content: Content) -> some View {
        let diameter = GlassListMetrics.stateDiameter(compact: compact)
        content
            .frame(width: diameter, height: diameter)
            .padding(TorrentRowColumns.statePadding)
    }
}
