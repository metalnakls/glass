import SwiftUI

extension View {
    @ViewBuilder
    func glassSoftTopScrollEdge() -> some View {
        if #available(macOS 27.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}
