import AppKit
import SwiftUI

/// Native checkbox semantics plus painting one wanted value across a file list.
struct TorrentWantedCheckbox: NSViewRepresentable {
    let value: Bool
    let enabled: Bool
    let label: String
    let scope: UUID
    let id: String
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> Button {
        let button = Button(checkboxWithTitle: "", target: nil, action: nil)
        button.target = button
        button.action = #selector(Button.activate)
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        button.state = value ? .on : .off
        button.isEnabled = enabled
        button.setAccessibilityLabel(label)
        button.scope = scope; button.rowID = id; button.changed = changed
    }
    final class Button: NSButton {
        var scope = UUID()
        var rowID = ""
        var changed: (Bool) -> Void = { _ in }
        @objc func activate() { changed(state == .on) }
        func beginPaint() -> Bool {
            let value = state != .on
            state = value ? .on : .off
            changed(value)
            return value
        }
        func paint(from previous: CGPoint, to point: CGPoint, value: Bool,
                   visited: inout Set<String>, in root: NSView) {
            func visit(_ view: NSView) {
                if let button = view as? Button, button.scope == scope,
                   button.isEnabled, !button.isHiddenOrHasHiddenAncestor,
                   !button.visibleRect.isEmpty, !visited.contains(button.rowID),
                   TorrentCheckboxSweep.intersects(from: previous, to: point,
                       rect: button.convert(button.visibleRect, to: nil)) {
                    visited.insert(button.rowID)
                    button.state = value ? .on : .off
                    button.changed(value)
                }
                for child in view.subviews { visit(child) }
            }
            visit(root)
        }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled, let window else { return }
            // Pointer painting must not leave a keyboard-focus ring on its
            // starting checkbox. Keep the current native keyboard responder.
            let value = beginPaint()
            var visited: Set<String> = [rowID]
            var previous = event.locationInWindow
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let point = next.locationInWindow
                if let content = enclosingScrollView?.documentView ?? window.contentView {
                    paint(from: previous, to: point, value: value, visited: &visited, in: content)
                }
                previous = point
                if next.type == .leftMouseUp { break }
                enclosingScrollView?.contentView.autoscroll(with: next)
            }
        }
    }
}

/// Segment clipping catches intermediate checkboxes even when drag events skip rows.
enum TorrentCheckboxSweep {
    static func intersects(from a: CGPoint, to b: CGPoint, rect: CGRect) -> Bool {
        var lower: CGFloat = 0, upper: CGFloat = 1
        for (start, delta, minimum, maximum) in [(a.x, b.x-a.x, rect.minX, rect.maxX),
                                                (a.y, b.y-a.y, rect.minY, rect.maxY)] {
            if delta == 0 { if start < minimum || start > maximum { return false } }
            else {
                let t1 = (minimum-start)/delta, t2 = (maximum-start)/delta
                lower = max(lower, min(t1,t2)); upper = min(upper, max(t1,t2))
                if lower > upper { return false }
            }
        }
        return true
    }
}
