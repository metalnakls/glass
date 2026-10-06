import AppKit
import SwiftUI

/// Keep native selection and keyboard navigation, with the foreground owning its highlight.
struct TorrentFileListStyling: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.apply() }

    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); apply() }
        func apply() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    table.selectionHighlightStyle = .none
                    table.focusRingType = .none
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
