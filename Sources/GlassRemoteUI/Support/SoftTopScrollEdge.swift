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

    @ViewBuilder
    func glassSwipeActionsContainer() -> some View {
        if #available(macOS 27.0, *) {
            swipeActionsContainer()
        } else {
            self
        }
    }

    @ViewBuilder
    func glassSelectOnSecondaryClick(_ action: @escaping () -> Void) -> some View {
        if #available(macOS 26.0, *) {
            gesture(SecondaryClickSelectionGesture(action: action))
        } else {
            self
        }
    }
}
