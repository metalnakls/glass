import AppKit
import SwiftUI
import Testing
@testable import GlassRemoteUI

@MainActor
@Suite("AppKit workspace split")
struct AppKitWorkspaceSplitViewTests {
    @Test("owns three semantic split items and scopes accessories")
    func splitStructure() {
        let controller = makeController()

        #expect(controller.splitViewItems.count == 3)
        #expect(controller.sidebarItem.behavior == .sidebar)
        #expect(controller.mainItem.behavior == .default)
        #expect(controller.inspectorItem.behavior == .inspector)
        #expect(controller.sidebarItem.topAlignedAccessoryViewControllers.count == 1)
        #expect(controller.mainItem.topAlignedAccessoryViewControllers.count == 1)
        #expect(controller.inspectorItem.topAlignedAccessoryViewControllers.isEmpty)
        #expect(controller.inspectorItem.canCollapse == false)
        #expect(controller.inspectorItem.canCollapseFromWindowResize == false)
    }

    @Test("filter is a native stateful glass button")
    func filterButton() {
        let controller = makeController()
        var didToggleFilter = false

        controller.updateChrome(
            windowTitle: "Ultra – 192.168.1.1",
            title: "Ultra",
            subtitle: "192.168.1.1",
            isFilterActive: true,
            isSidebarCollapsed: false,
            toggleFilter: { didToggleFilter = true },
            sidebarCollapsedDidChange: { _ in }
        )

        #expect(controller.workspaceAccessory.filterButton.bezelStyle == .glass)
        #expect(controller.workspaceAccessory.filterButton.borderShape == .circle)
        #expect(controller.workspaceAccessory.filterButton.state == .on)

        controller.workspaceAccessory.filterButton.performClick(nil)
        #expect(didToggleFilter)
    }

    @Test("sidebar restore control moves into the main accessory")
    func sidebarRestoreControl() {
        let controller = makeController()

        controller.setSidebarCollapsed(false)
        #expect(controller.workspaceAccessory.sidebarButton.isHidden)

        controller.setSidebarCollapsed(true)
        #expect(controller.sidebarItem.isCollapsed)
        #expect(controller.workspaceAccessory.sidebarButton.isHidden == false)
    }

    private func makeController() -> GlassWorkspaceSplitViewController<EmptyView, EmptyView, EmptyView> {
        GlassWorkspaceSplitViewController(
            sidebar: EmptyView(),
            main: EmptyView(),
            inspector: EmptyView()
        )
    }
}
