import AppKit
import SwiftUI

extension View {
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
        if #available(macOS 26.0, *) {
            gesture(SecondaryClickSelectionGesture { event, view in
                select()
                // Present the native menu directly, without SwiftUI's contextual row outline.
                let hostingMenu = NSHostingMenu(rootView: menu())
                NSMenu.popUpContextMenu(hostingMenu, with: event, for: view)
            })
        } else {
            contextMenu(menuItems: menu)
        }
    }
}
