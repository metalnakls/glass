import AppKit
import SwiftUI

/// Keep native List selection and keyboard handling, while drawing the requested neutral highlight in SwiftUI.
struct TorrentListSelectionStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionView { SelectionView() }
    func updateNSView(_ view: SelectionView, context: Context) { view.configure() }

    final class SelectionView: NSView {
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }

        func configure() {
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
