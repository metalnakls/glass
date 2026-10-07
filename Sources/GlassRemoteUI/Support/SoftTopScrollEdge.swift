import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func glassFlatSwipeActions<Actions: View>(
        onPresentationChanged: @escaping (Bool) -> Void,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        if #available(macOS 27.0, *) {
            swipeActions(edge: .trailing, allowsFullSwipe: false, content: actions, onPresentationChanged: onPresentationChanged)
        } else {
            swipeActions(edge: .trailing, allowsFullSwipe: false, content: actions)
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
    func glassContextMenu<MenuContent: View>(
        select: @escaping () -> Void,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) -> some View {
        contextMenu(menuItems: menu)
            .background {
                SecondaryClickSelectionGesture { _, _ in select() }
            }
    }
}
