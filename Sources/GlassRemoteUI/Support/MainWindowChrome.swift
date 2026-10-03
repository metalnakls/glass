import AppKit
import SwiftUI

/// Keeps the experimental main window chrome-free without changing sheets.
struct MainWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.configureWindow() }

    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
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
