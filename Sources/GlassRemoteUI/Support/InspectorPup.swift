import AppKit
import SwiftUI

/// Decorative, click-through artwork attached to the empty Inspector.
/// The parent retains its native frame, layout, resizing and shadow.
struct InspectorPup: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.scheduleUpdate() }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.removePup() }

    final class Anchor: NSView {
        private var panel: PupPanel?
        private weak var owner: NSWindow?
        private var retired = false
        private var updateScheduled = false
        private var enteringFullscreen = false
        // 148-point artwork crosses the window edge by 58 points.
        private static let artworkSize: CGFloat = 148
        private static let overhang: CGFloat = 58

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleUpdate()
        }
        override func layout() { super.layout(); scheduleUpdate() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func scheduleUpdate() {
            guard !retired, !updateScheduled else { return }
            updateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                self.updatePup()
            }
        }

        private func updatePup() {
            guard !retired, let window, window.sheetParent == nil else { return }
            if owner !== window {
                detach()
                owner = window
                let artwork = NSImageView(frame: NSRect(x: 0, y: 0,
                    width: Self.artworkSize, height: Self.artworkSize))
                artwork.image = Bundle.module.url(forResource: "InspectorPup", withExtension: "png")
                    .flatMap(NSImage.init(contentsOf:))
                artwork.imageScaling = .scaleProportionallyUpOrDown
                artwork.setAccessibilityElement(false)
                let overlay = PupPanel(contentRect: artwork.bounds, styleMask: .borderless,
                    backing: .buffered, defer: false)
                overlay.isReleasedWhenClosed = false
                overlay.backgroundColor = .clear
                overlay.isOpaque = false
                overlay.hasShadow = true
                overlay.ignoresMouseEvents = true
                overlay.hidesOnDeactivate = false
                overlay.isExcludedFromWindowsMenu = true
                overlay.contentView = artwork
                panel = overlay
                for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.didExitFullScreenNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(parentChanged), name: name, object: window)
                }
                for name in [NSWindow.willMiniaturizeNotification, NSWindow.willCloseNotification,
                             NSWindow.willEnterFullScreenNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(parentHiding), name: name, object: window)
                }
            }
            guard let panel else { return }
            guard window.isVisible, !window.isMiniaturized, !enteringFullscreen,
                  !window.styleMask.contains(.fullScreen) else { panel.orderOut(nil); return }
            let center = window.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: 0), to: nil))
            panel.setFrame(NSRect(x: center.x - Self.artworkSize / 2,
                y: window.frame.minY - Self.overhang,
                width: Self.artworkSize, height: Self.artworkSize), display: true)
            if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
            panel.orderFront(nil)
            panel.invalidateShadow()
        }

        @objc private func parentChanged(_ notification: Notification) {
            if notification.name == NSWindow.didExitFullScreenNotification { enteringFullscreen = false }
            scheduleUpdate()
        }
        @objc private func parentHiding(_ notification: Notification) {
            if notification.name == NSWindow.willEnterFullScreenNotification { enteringFullscreen = true }
            panel?.orderOut(nil)
        }
        private func detach() {
            NotificationCenter.default.removeObserver(self)
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
                panel.close()
            }
            panel = nil
            owner = nil
            enteringFullscreen = false
        }
        func removePup() { retired = true; detach() }

        final class PupPanel: NSPanel {
            override var canBecomeKey: Bool { false }
            override var canBecomeMain: Bool { false }
        }
    }
}
