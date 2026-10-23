import AppKit
import SwiftUI

/// Extends the same window's transparent canvas only for the empty Inspector.
struct InspectorPup: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.scheduleUpdate() }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.removePup() }

    final class Anchor: NSView {
        private var canvas: Canvas?
        private weak var owner: NSWindow?
        private var updating = false
        private var retired = false
        private static let overhang: CGFloat = 58

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleUpdate()
        }
        override func layout() { super.layout(); scheduleUpdate() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func scheduleUpdate() {
            guard !updating, !retired else { return }
            DispatchQueue.main.async { [weak self] in self?.updatePup() }
        }

        private func updatePup() {
            guard !updating, !retired, let window, !window.styleMask.contains(.fullScreen),
                  window.sheetParent == nil, let content = window.contentView else { return }
            updating = true
            defer { updating = false }
            if canvas == nil {
                owner = window
                let frame = window.frame
                let wrapper = Canvas(frame: content.frame)
                wrapper.originalOpaque = window.isOpaque
                wrapper.originalBackground = window.backgroundColor
                wrapper.body = content
                window.isOpaque = false
                window.backgroundColor = .clear
                window.contentView = wrapper
                wrapper.addSubview(content)
                canvas = wrapper
                window.setFrame(NSRect(x: frame.minX, y: frame.minY - Self.overhang,
                    width: frame.width, height: frame.height + Self.overhang), display: true)
                wrapper.layoutBody()
                NotificationCenter.default.addObserver(self, selector: #selector(enterFullscreen),
                    name: NSWindow.willEnterFullScreenNotification, object: window)
            }
            guard let canvas else { return }
            canvas.pupCenter = convert(bounds, to: canvas).midX
            canvas.layoutBody()
            window.invalidateShadow()
        }

        @objc private func enterFullscreen() {
            let parent = owner
            removePup()
            retired = false
            NotificationCenter.default.addObserver(self, selector: #selector(exitFullscreen),
                name: NSWindow.didExitFullScreenNotification, object: parent)
        }
        @objc private func exitFullscreen() {
            NotificationCenter.default.removeObserver(self)
            scheduleUpdate()
        }

        func removePup() {
            retired = true
            NotificationCenter.default.removeObserver(self)
            guard let canvas, let owner, owner.contentView === canvas, let body = canvas.body else { return }
            updating = true
            let frame = owner.frame
            body.removeFromSuperview()
            owner.contentView = body
            owner.isOpaque = canvas.originalOpaque
            owner.backgroundColor = canvas.originalBackground
            owner.setFrame(NSRect(x: frame.minX, y: frame.minY + Self.overhang,
                width: frame.width, height: frame.height - Self.overhang), display: true)
            owner.invalidateShadow()
            self.canvas = nil
            updating = false
        }

        final class Artwork: NSImageView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func isAccessibilityElement() -> Bool { false }
        }
        final class Canvas: NSView {
            var body: NSView?
            var originalOpaque = true
            var originalBackground: NSColor = .windowBackgroundColor
            var pupCenter: CGFloat = 0
            private let pup = Bundle.module.url(forResource: "InspectorPup", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            private lazy var artwork: Artwork = {
                let view = Artwork()
                view.image = pup
                view.imageScaling = .scaleProportionallyUpOrDown
                addSubview(view)
                return view
            }()
            override var isOpaque: Bool { false }
            override func resizeSubviews(withOldSize oldSize: NSSize) { layoutBody() }
            func layoutBody() {
                body?.frame = NSRect(x: 0, y: Anchor.overhang, width: bounds.width,
                    height: max(0, bounds.height - Anchor.overhang))
                artwork.frame = NSRect(x: pupCenter - 74, y: 2, width: 148, height: 148)
                needsDisplay = true
            }
            override func draw(_ dirtyRect: NSRect) {
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: Anchor.overhang, width: bounds.width,
                    height: max(0, bounds.height - Anchor.overhang)), xRadius: 10, yRadius: 10).fill()

            }
        }
    }
}
