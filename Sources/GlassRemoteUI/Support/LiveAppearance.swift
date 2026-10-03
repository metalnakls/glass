import AppKit
import SwiftUI

/// Native layers and detached hosting views must follow the window's appearance,
/// even when SwiftUI's inherited colour scheme has not been invalidated yet.
struct LiveAppearance: NSViewRepresentable {
    @Binding var colorScheme: ColorScheme?
    func makeNSView(context: Context) -> AppearanceView { AppearanceView() }
    func updateNSView(_ view: AppearanceView, context: Context) {
        view.changed = { scheme in
            // AppKit may call during a SwiftUI update; publish on the next turn.
            DispatchQueue.main.async {
                if colorScheme != scheme { colorScheme = scheme }
            }
        }
        view.refresh()
    }
}

final class AppearanceView: NSView {
    var changed: ((ColorScheme) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
    func refresh() {
        guard window != nil else { return }
        changed?(effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
    }
}
