import AppKit
import SwiftUI

/// A SwiftUI-owned action that closes a panel presented with
/// `glassCenteredPanel(isPresented:size:content:)`.
public struct GlassPanelDismissAction: Sendable {
    private let action: @MainActor @Sendable () -> Void
    let isAvailable: Bool

    init(isAvailable: Bool = false, action: @escaping @MainActor @Sendable () -> Void = {}) {
        self.isAvailable = isAvailable
        self.action = action
    }

    @MainActor public func callAsFunction() {
        action()
    }
}

private struct GlassPanelDismissActionKey: EnvironmentKey {
    static let defaultValue = GlassPanelDismissAction()
}

public extension EnvironmentValues {
    var glassPanelDismiss: GlassPanelDismissAction {
        get { self[GlassPanelDismissActionKey.self] }
        set { self[GlassPanelDismissActionKey.self] = newValue }
    }
}

/// Shared content dimensions for torrent import and add panels.
public enum GlassCenteredPanelSize {
    public static let addTorrent = CGSize(width: 640, height: 580)
}

public extension View {
    /// Presents content in a centered, closable AppKit panel that can extend
    /// beyond the parent window while remaining centered over it.
    func glassCenteredPanel<PanelContent: View>(
        isPresented: Binding<Bool>,
        size: CGSize,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> PanelContent
    ) -> some View {
        background {
            GlassCenteredPanelHost(
                isPresented: isPresented,
                size: size,
                onDismiss: onDismiss,
                content: content
            )
            .frame(width: 1, height: 1)
            .hidden()
            .accessibilityHidden(true)
        }
    }
}

private struct GlassCenteredPanelHost<PanelContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let size: CGSize
    let onDismiss: (() -> Void)?
    let content: () -> PanelContent

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PanelAnchorView {
        let view = PanelAnchorView()
        view.onWindowChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.anchorWindowDidChange(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: PanelAnchorView, context: Context) {
        let dismissAction = GlassPanelDismissAction(isAvailable: true) { [weak coordinator = context.coordinator] in
            coordinator?.dismissPanel()
        }
        let hostedContent = AnyView(content().environment(\.glassPanelDismiss, dismissAction))
        context.coordinator.update(
            parentWindow: nsView.window,
            isPresented: $isPresented,
            size: size,
            content: hostedContent,
            onDismiss: onDismiss
        )
    }

    static func dismantleNSView(_ nsView: PanelAnchorView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject {
        private var panel: GlassDismissiblePanel?
        private var hostingController: NSHostingController<AnyView>?
        private var panelDelegate: GlassPanelWindowDelegate?
        private var isPresentedBinding: Binding<Bool> = .constant(false)
        private var onDismiss: (() -> Void)?
        private var size = CGSize.zero

        func update(
            parentWindow: NSWindow?,
            isPresented: Binding<Bool>,
            size: CGSize,
            content: AnyView,
            onDismiss: (() -> Void)?
        ) {
            isPresentedBinding = isPresented
            self.size = size
            self.onDismiss = onDismiss

            if panel == nil {
                createPanel(content: content)
            } else {
                hostingController?.rootView = content
            }

            attach(to: parentWindow)
            if isPresented.wrappedValue {
                showPanel()
            } else if panel?.isVisible == true {
                panel?.close()
            }
        }

        func anchorWindowDidChange(_ window: NSWindow?) {
            attach(to: window)
            if isPresentedBinding.wrappedValue {
                showPanel()
            }
        }

        func dismissPanel() {
            guard let panel else {
                isPresentedBinding.wrappedValue = false
                onDismiss?()
                return
            }
            if panel.isVisible {
                panel.close()
            } else {
                isPresentedBinding.wrappedValue = false
                onDismiss?()
            }
        }

        func tearDown() {
            panel?.close()
            if let panel, let parent = panel.parent {
                parent.removeChildWindow(panel)
            }
            panel?.delegate = nil
            panel = nil
            hostingController = nil
            panelDelegate = nil
        }

        private func createPanel(content: AnyView) {
            let hostingController = NSHostingController(rootView: content)
            let panel = GlassDismissiblePanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = ""
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            panel.contentViewController = hostingController
            panel.setContentSize(size)

            let panelDelegate = GlassPanelWindowDelegate { [weak self] in
                guard let self else { return }
                isPresentedBinding.wrappedValue = false
                onDismiss?()
            }
            panel.delegate = panelDelegate
            panel.escapeAction = { [weak self] in self?.dismissPanel() }

            self.hostingController = hostingController
            self.panelDelegate = panelDelegate
            self.panel = panel
        }

        private func attach(to parentWindow: NSWindow?) {
            guard let panel, let parentWindow else { return }
            if panel.parent !== parentWindow {
                if let oldParent = panel.parent {
                    oldParent.removeChildWindow(panel)
                }
                parentWindow.addChildWindow(panel, ordered: .above)
            }
        }

        private func showPanel() {
            guard let panel else { return }
            panel.setContentSize(size)
            if let parent = panel.parent {
                let frame = parent.frame
                panel.setFrameOrigin(NSPoint(
                    x: frame.midX - panel.frame.width / 2,
                    y: frame.midY - panel.frame.height / 2
                ))
            } else {
                panel.center()
            }
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
private final class PanelAnchorView: NSView {
    var onWindowChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

@MainActor
private final class GlassDismissiblePanel: NSPanel {
    var escapeAction: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        escapeAction?()
    }
}

@MainActor
private final class GlassPanelWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
