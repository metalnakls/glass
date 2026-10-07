import AppKit
import SwiftUI

/// Keep native selection and keyboard navigation, with the foreground owning its highlight.
struct TorrentFileListStyling: NSViewRepresentable {
    var onDeselect: (Int) -> Void = { _ in }
    var controlInset: CGFloat = 0
    var nativeHighlight = false
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.onDeselect = onDeselect; view.controlInset = controlInset; view.nativeHighlight = nativeHighlight; view.apply() }

    final class Anchor: NSView {
        var onDeselect: (Int) -> Void = { _ in }
        var controlInset: CGFloat = 0
        var nativeHighlight = false
        private weak var table: NSTableView?
        private var monitor: Any?
        private var selectedClick: (row: Int, point: NSPoint)?
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil, let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            apply()
        }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); apply() }
        func apply() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    self.table = table
                    table.selectionHighlightStyle = nativeHighlight ? .regular : .none
                    table.focusRingType = .none
                    if window != nil && monitor == nil {
                        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                            self?.handle(event)
                            return event
                        }
                    }
                    return
                }
                ancestor = view.superview
            }
        }

        private func handle(_ event: NSEvent) {
            guard let table, event.window === window else { selectedClick = nil; return }
            let point = table.convert(event.locationInWindow, from: nil)
            if event.type == .leftMouseDown {
                selectedClick = nil
                guard event.clickCount == 1, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
                      table.visibleRect.contains(point), point.x > controlInset else { return }
                let row = table.row(at: point)
                guard row >= 0, table.selectedRowIndexes.contains(row) else { return }
                if table.hitTest(point) is NSControl { return }
                selectedClick = (row, point)
            } else if let click = selectedClick {
                selectedClick = nil
                guard abs(point.x - click.point.x) < 3, abs(point.y - click.point.y) < 3,
                      table.row(at: point) == click.row else { return }
                // Let native selection finish first; keyboard and modifier selection stay native.
                Task { @MainActor [weak self] in self?.onDeselect(click.row) }
            }
        }
    }
}
