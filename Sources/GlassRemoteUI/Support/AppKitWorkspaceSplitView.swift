import AppKit
import SwiftUI

@MainActor
struct AppKitWorkspaceSplitView<SidebarContent: View, MainContent: View, InspectorContent: View>:
    NSViewControllerRepresentable
{
    @Binding private var isSidebarCollapsed: Bool
    private let windowTitle: String
    private let title: String
    private let subtitle: String
    private let isFilterActive: Bool
    private let toggleFilter: () -> Void
    private let sidebar: SidebarContent
    private let main: MainContent
    private let inspector: InspectorContent

    init(
        isSidebarCollapsed: Binding<Bool>,
        windowTitle: String,
        title: String,
        subtitle: String,
        isFilterActive: Bool,
        toggleFilter: @escaping () -> Void,
        @ViewBuilder sidebar: () -> SidebarContent,
        @ViewBuilder main: () -> MainContent,
        @ViewBuilder inspector: () -> InspectorContent
    ) {
        _isSidebarCollapsed = isSidebarCollapsed
        self.windowTitle = windowTitle
        self.title = title
        self.subtitle = subtitle
        self.isFilterActive = isFilterActive
        self.toggleFilter = toggleFilter
        self.sidebar = sidebar()
        self.main = main()
        self.inspector = inspector()
    }

    func makeNSViewController(context: Context) -> GlassWorkspaceSplitViewController<
        SidebarContent,
        MainContent,
        InspectorContent
    > {
        let controller = GlassWorkspaceSplitViewController(
            sidebar: sidebar,
            main: main,
            inspector: inspector
        )
        update(controller)
        return controller
    }

    func updateNSViewController(
        _ controller: GlassWorkspaceSplitViewController<SidebarContent, MainContent, InspectorContent>,
        context: Context
    ) {
        controller.updateContent(sidebar: sidebar, main: main, inspector: inspector)
        update(controller)
    }

    private func update(
        _ controller: GlassWorkspaceSplitViewController<SidebarContent, MainContent, InspectorContent>
    ) {
        let sidebarBinding = _isSidebarCollapsed
        controller.updateChrome(
            windowTitle: windowTitle,
            title: title,
            subtitle: subtitle,
            isFilterActive: isFilterActive,
            isSidebarCollapsed: isSidebarCollapsed,
            toggleFilter: toggleFilter,
            sidebarCollapsedDidChange: { collapsed in
                guard sidebarBinding.wrappedValue != collapsed else { return }
                sidebarBinding.wrappedValue = collapsed
            }
        )
    }
}

@MainActor
final class GlassWorkspaceSplitViewController<SidebarContent: View, MainContent: View, InspectorContent: View>:
    NSSplitViewController
{
    private let sidebarHostingController: NSHostingController<SidebarContent>
    private let mainHostingController: NSHostingController<MainContent>
    private let inspectorHostingController: NSHostingController<InspectorContent>

    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var mainItem: NSSplitViewItem!
    private(set) var inspectorItem: NSSplitViewItem!
    private(set) var sidebarAccessory: SidebarSplitAccessoryViewController!
    private(set) var workspaceAccessory: WorkspaceSplitAccessoryViewController!

    private var desiredWindowTitle = "Glass"
    private var sidebarCollapsedDidChange: ((Bool) -> Void)?
    private var lastReportedSidebarCollapsed: Bool?
    private var isApplyingSidebarState = false

    init(sidebar: SidebarContent, main: MainContent, inspector: InspectorContent) {
        sidebarHostingController = NSHostingController(rootView: sidebar)
        mainHostingController = NSHostingController(rootView: main)
        inspectorHostingController = NSHostingController(rootView: inspector)
        super.init(nibName: nil, bundle: nil)
        configureSplitView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindow()
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        reportSidebarStateIfNeeded()
    }

    func updateContent(sidebar: SidebarContent, main: MainContent, inspector: InspectorContent) {
        sidebarHostingController.rootView = sidebar
        mainHostingController.rootView = main
        inspectorHostingController.rootView = inspector
    }

    func updateChrome(
        windowTitle: String,
        title: String,
        subtitle: String,
        isFilterActive: Bool,
        isSidebarCollapsed: Bool,
        toggleFilter: @escaping () -> Void,
        sidebarCollapsedDidChange: @escaping (Bool) -> Void
    ) {
        desiredWindowTitle = windowTitle
        self.sidebarCollapsedDidChange = sidebarCollapsedDidChange
        workspaceAccessory.update(
            title: title,
            subtitle: subtitle,
            isFilterActive: isFilterActive,
            isSidebarCollapsed: isSidebarCollapsed,
            toggleFilter: toggleFilter
        )
        setSidebarCollapsed(isSidebarCollapsed)
        configureWindow()
    }

    func setSidebarCollapsed(_ collapsed: Bool) {
        guard sidebarItem.isCollapsed != collapsed else {
            workspaceAccessory.setSidebarCollapsed(collapsed)
            lastReportedSidebarCollapsed = collapsed
            return
        }

        isApplyingSidebarState = true
        sidebarItem.isCollapsed = collapsed
        isApplyingSidebarState = false
        workspaceAccessory.setSidebarCollapsed(collapsed)
        lastReportedSidebarCollapsed = collapsed
    }

    private func configureSplitView() {
        splitView.isVertical = true
        splitView.autosaveName = "GlassRoot.splitView"

        sidebarHostingController.view.frame.size.width = 220
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHostingController)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = true
        sidebarItem.allowsFullHeightLayout = true

        mainItem = NSSplitViewItem(viewController: mainHostingController)

        inspectorHostingController.view.frame.size.width = 280
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHostingController)
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 420
        inspectorItem.canCollapse = false
        inspectorItem.canCollapseFromWindowResize = false
        inspectorItem.allowsFullHeightLayout = true

        addSplitViewItem(sidebarItem)
        addSplitViewItem(mainItem)
        addSplitViewItem(inspectorItem)

        sidebarAccessory = SidebarSplitAccessoryViewController { [weak self] in
            self?.toggleSidebar(nil)
        }
        workspaceAccessory = WorkspaceSplitAccessoryViewController { [weak self] in
            self?.toggleSidebar(nil)
        }
        sidebarItem.addTopAlignedAccessoryViewController(sidebarAccessory)
        mainItem.addTopAlignedAccessoryViewController(workspaceAccessory)
    }

    private func configureWindow() {
        guard let window = view.window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.title = desiredWindowTitle
    }

    private func reportSidebarStateIfNeeded() {
        guard sidebarItem != nil else { return }
        let collapsed = sidebarItem.isCollapsed
        workspaceAccessory?.setSidebarCollapsed(collapsed)
        guard !isApplyingSidebarState, lastReportedSidebarCollapsed != collapsed else { return }
        lastReportedSidebarCollapsed = collapsed
        sidebarCollapsedDidChange?(collapsed)
    }
}

@MainActor
final class SidebarSplitAccessoryViewController: NSSplitViewItemAccessoryViewController {
    private let toggleSidebar: () -> Void

    init(toggleSidebar: @escaping () -> Void) {
        self.toggleSidebar = toggleSidebar
        super.init(nibName: nil, bundle: nil)
        automaticallyAppliesContentInsets = true
        preferredScrollEdgeEffectStyle = .soft
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        let button = makeGlassSymbolButton(
            systemName: "sidebar.left",
            accessibilityLabel: "Toggle Sidebar",
            target: self,
            action: #selector(toggleSidebarPressed(_:))
        )
        container.addSubview(button)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 64),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
    }

    @objc private func toggleSidebarPressed(_ sender: NSButton) {
        toggleSidebar()
    }
}

@MainActor
final class WorkspaceSplitAccessoryViewController: NSSplitViewItemAccessoryViewController {
    let sidebarButton: NSButton
    let filterButton: NSButton

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let toggleSidebar: () -> Void
    private var toggleFilter: () -> Void = {}

    init(toggleSidebar: @escaping () -> Void) {
        self.toggleSidebar = toggleSidebar
        sidebarButton = makeGlassSymbolButton(
            systemName: "sidebar.left",
            accessibilityLabel: "Show Sidebar",
            target: nil,
            action: nil
        )
        filterButton = makeGlassSymbolButton(
            systemName: "line.3.horizontal.decrease",
            accessibilityLabel: "Show Downloading Torrents",
            target: nil,
            action: nil
        )
        super.init(nibName: nil, bundle: nil)

        sidebarButton.target = self
        sidebarButton.action = #selector(toggleSidebarPressed(_:))
        filterButton.target = self
        filterButton.action = #selector(filterPressed(_:))
        filterButton.setButtonType(.toggle)

        automaticallyAppliesContentInsets = true
        preferredScrollEdgeEffectStyle = .soft
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 0

        let preferredTitleFont = NSFont.preferredFont(forTextStyle: .largeTitle)
        let boldDescriptor = preferredTitleFont.fontDescriptor.withSymbolicTraits(.bold)
        titleLabel.font = NSFont(descriptor: boldDescriptor, size: 0) ?? preferredTitleFont
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [sidebarButton, titleStack, spacer, filterButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 68),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 8),
        ])
        view = container
    }

    func update(
        title: String,
        subtitle: String,
        isFilterActive: Bool,
        isSidebarCollapsed: Bool,
        toggleFilter: @escaping () -> Void
    ) {
        loadViewIfNeeded()
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        filterButton.state = isFilterActive ? .on : .off
        filterButton.toolTip = isFilterActive ? "Show All Torrents" : "Show Downloading Torrents"
        filterButton.setAccessibilityLabel(
            isFilterActive ? "Show All Torrents" : "Show Downloading Torrents"
        )
        self.toggleFilter = toggleFilter
        setSidebarCollapsed(isSidebarCollapsed)
    }

    func setSidebarCollapsed(_ collapsed: Bool) {
        loadViewIfNeeded()
        sidebarButton.isHidden = !collapsed
    }

    @objc private func toggleSidebarPressed(_ sender: NSButton) {
        toggleSidebar()
    }

    @objc private func filterPressed(_ sender: NSButton) {
        toggleFilter()
    }
}

@MainActor
private func makeGlassSymbolButton(
    systemName: String,
    accessibilityLabel: String,
    target: AnyObject?,
    action: Selector?
) -> NSButton {
    let button = NSButton()
    button.title = ""
    button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: accessibilityLabel)
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.bezelStyle = .glass
    button.borderShape = .circle
    button.controlSize = .large
    button.isBordered = true
    button.target = target
    button.action = action
    button.toolTip = accessibilityLabel
    button.setAccessibilityLabel(accessibilityLabel)
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
}
