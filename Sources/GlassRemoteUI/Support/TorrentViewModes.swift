import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum TorrentIconGridMetrics {
    static let artworkHeight: CGFloat = 56
    static let spacing: CGFloat = 4
    static var padding: CGFloat { GlassContentMargins.systemValue / 2 }
    static var titleHeight: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .body)
        return 2 * ceil(font.ascender - font.descender + font.leading)
    }
    static var footerHeight: CGFloat { GlassListMetrics.stateDiameter(compact: true) + 2 * TorrentRowColumns.statePadding }
    static var height: CGFloat { artworkHeight + titleHeight + footerHeight + 2 * spacing + 2 * padding }
}

/// Finder-sized identity artwork for dense rows; no poster tilt or overflow.
struct TorrentCompactIcon: View {
    let name: String
    var folder = false
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: folder ? .folder : (UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)))
            .resizable().scaledToFit()
            .frame(width: TorrentRowColumns.compactArtworkWidth, height: TorrentRowColumns.compactArtworkWidth)
            .accessibilityHidden(true)
    }
}

/// The grid uses the same native material and gradient as list header chrome.
@MainActor enum TorrentHeaderMaterialStyle {
    static func configure(_ effect: NSVisualEffectView, mask: CAGradientLayer) {
        effect.material = .headerView
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        mask.locations = [0, 0.25, 1]
        mask.startPoint = CGPoint(x: 0.5, y: 1)
        mask.endPoint = CGPoint(x: 0.5, y: 0)
        effect.layer?.mask = mask
    }
}

struct TorrentGridHeaderMaterial: View {
    nonisolated static let coordinateSpace = "GlassIconGridViewport"
    @AppearanceStorage("GlassList.headerFadeReach") private var reach = 48.0
    @Environment(\.torrentGridHasScrolled) private var hasScrolled
    @State private var pinned = false
    var body: some View {
        GeometryReader { geometry in
            Material().frame(height: geometry.size.height + max(0, reach))
                .opacity(hasScrolled && pinned ? 1 : 0)
        }
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.frame(in: .named(Self.coordinateSpace)).minY <= 0
        } action: { pinned = $0 }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
    private struct Material: NSViewRepresentable {
        func makeNSView(context: Context) -> Surface { Surface() }
        func updateNSView(_ view: Surface, context: Context) {}
        final class Surface: NSVisualEffectView {
            private let fade = CAGradientLayer()
            override init(frame: NSRect) {
                super.init(frame: frame)
                TorrentHeaderMaterialStyle.configure(self, mask: fade)
            }
            required init?(coder: NSCoder) { fatalError() }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func layout() {
                super.layout()
                CATransaction.begin(); CATransaction.setDisableActions(true)
                fade.frame = bounds
                CATransaction.commit()
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var torrentGridHasScrolled = false
}
