import AppKit
import SwiftUI

/// Keeps the experimental main window chrome-free without changing sheets.
struct MainWindowChrome: NSViewRepresentable {
    var widthChanged: ((CGFloat) -> Void)?

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.widthChanged = widthChanged
        view.configureWindow()
        view.reportWidth()
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stopObserving() }

    final class Anchor: NSView {
        var widthChanged: ((CGFloat) -> Void)?
        private var reportedWidth: CGFloat?
        private var titlebarDragOverlay: TitlebarDragOverlay?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            configureWindow()
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowResized),
                    name: NSWindow.didResizeNotification, object: window)
                reportWidth()
            }
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
            reportedWidth = nil
            titlebarDragOverlay?.removeFromSuperview()
            titlebarDragOverlay = nil
        }

        @objc private func windowResized(_ notification: Notification) {
            configureWindow()
            reportWidth()
        }

        func reportWidth() {
            guard let window, widthChanged != nil else { return }
            let width = window.contentLayoutRect.width
            guard reportedWidth != width else { return }
            reportedWidth = width
            // Publish after SwiftUI has finished updating the representable.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      self.reportedWidth == width else { return }
                self.widthChanged?(width)
            }
        }

        override func layout() {
            super.layout()
            configureWindow()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configureWindow() {
            guard let window, let contentView = window.contentView else { return }
            guard window.sheetParent == nil else {
                updateTitlebarDragOverlay(in: window, contentView: contentView)
                return
            }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let control = window.standardWindowButton(button), !control.isHidden {
                    control.isHidden = true
                }
            }
            if window.toolbar != nil { window.toolbar = nil }
            updateTitlebarDragOverlay(in: window, contentView: contentView)
        }

        private func updateTitlebarDragOverlay(in window: NSWindow, contentView: NSView) {
            guard TitlebarDragOverlay.shouldInstall(in: window) else {
                titlebarDragOverlay?.removeFromSuperview()
                titlebarDragOverlay = nil
                return
            }

            let overlay: TitlebarDragOverlay
            if let titlebarDragOverlay, titlebarDragOverlay.superview === contentView {
                overlay = titlebarDragOverlay
            } else {
                titlebarDragOverlay?.removeFromSuperview()
                overlay = TitlebarDragOverlay(frame: contentView.bounds)
                overlay.autoresizingMask = [.width, .height]
                contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
                titlebarDragOverlay = overlay
            }
            overlay.frame = contentView.bounds
            overlay.titlebarBand = { [weak overlay, weak window] in
                guard let overlay, let window else { return .zero }
                return overlay.measuredTitlebarBand(in: window)
            }
        }
    }
}

final class TitlebarDragOverlay: NSView {
    static func shouldInstall(in window: NSWindow) -> Bool {
        shouldInstall(isSheet: window.sheetParent != nil, isFullscreen: window.styleMask.contains(.fullScreen))
    }

    static func shouldInstall(isSheet: Bool, isFullscreen: Bool) -> Bool {
        !isSheet && !isFullscreen
    }

    var titlebarBand: () -> NSRect = { .zero }
    var performDrag: (NSWindow, NSEvent) -> Void = { window, event in
        window.performDrag(with: event)
    }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func measuredTitlebarBand(in window: NSWindow) -> NSRect {
        let contentRect = convert(window.contentLayoutRect, from: nil)
        let height: CGFloat
        let y: CGFloat
        if isFlipped {
            y = bounds.minY
            height = max(0, contentRect.minY - bounds.minY)
        } else {
            y = contentRect.maxY
            height = max(0, bounds.maxY - contentRect.maxY)
        }
        return NSRect(x: bounds.minX, y: y, width: bounds.width, height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        return titlebarBand().contains(localPoint) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        performDrag(window, event)
    }
}
