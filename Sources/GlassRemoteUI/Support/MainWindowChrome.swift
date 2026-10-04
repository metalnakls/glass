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
        }

        @objc private func windowResized(_ notification: Notification) { reportWidth() }

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
            guard let window, window.sheetParent == nil else { return }
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
        }
    }
}
