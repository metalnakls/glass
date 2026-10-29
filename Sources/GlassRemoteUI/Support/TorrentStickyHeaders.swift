import AppKit
import SwiftUI

struct StickyTitleLabel: View {
    let title: String
    let inset: CGFloat
    var body: some View {
        Text(title).font(.largeTitle.bold()).foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, inset).padding(.vertical, GlassListMetrics.titleVerticalInset)
    }
}

struct TorrentStickyTitle: View {
    let title: String
    let id: String
    let rowIndex: Int
    let inset: CGFloat
    let controller: TorrentStickyHeaders
    var body: some View {
        HeaderAnchor(controller: controller, id: id, title: title, index: rowIndex, inset: inset)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
            .onGeometryChange(for: CGRect.self) { proxy in proxy.frame(in: .global) } action: { _ in
                controller.layoutDidChange()
            }
    }
}

/// Converts the actual inline title frames into one continuous pin/push layout.
/// Both titles keep their measured x coordinate, height and internal padding.
enum TorrentStickyHeaderGeometry {
    struct Placement: Equatable {
        let index: Int
        let frame: CGRect
        var pinned = false
        var retiring = false
        var exitProgress: CGFloat = 0
    }
    struct Layout: Equatable {
        let titles: [Placement]
        let backdropHeight: CGFloat
        // Keep the owning header's geometry after its text leaves the viewport;
        // the gradient below it still needs to travel the remaining distance.
        var backdropTitle: Placement? = nil
    }
    static func displayLayout(frames: [CGRect], viewport: CGRect, sticky: Layout?) -> Layout {
        let visibleBounds = CGRect(origin: .zero, size: viewport.size)
        var titles = (sticky?.titles ?? []).filter { $0.frame.intersects(visibleBounds) }
        let placed = Set(titles.map(\.index))
        for (index, frame) in frames.enumerated() where !placed.contains(index) && frame.intersects(viewport) {
            titles.append(Placement(index: index, frame: frame.offsetBy(dx: -viewport.minX, dy: -viewport.minY)))
        }
        return Layout(titles: titles, backdropHeight: sticky?.backdropHeight ?? 0,
                      backdropTitle: sticky?.backdropTitle)
    }
    static func layout(frames: [CGRect], viewport: CGRect, feather: CGFloat = 48, topInset: CGFloat = 0, releasePoints: [CGFloat]? = nil, stickyAllowed: [Bool]? = nil) -> Layout? {
        guard let index = frames.indices.last(where: { frames[$0].minY < viewport.minY + topInset }) else { return nil }
        guard stickyAllowed?[index] != false else { return nil }
        let original = frames[index]
        let next = index + 1 < frames.count ? frames[index + 1] : nil
        var pinned = original.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
        let end = releasePoints?[index] ?? next?.minY ?? .greatestFiniteMagnitude
        pinned.origin.y = min(topInset, end - viewport.minY - original.height)
        func placement(_ index: Int, _ frame: CGRect) -> Placement {
            let progress = min(1, max(0, (topInset - frame.minY) / (topInset + frame.height)))
            return Placement(index: index, frame: frame, pinned: true, retiring: progress > 0, exitProgress: progress)
        }
        var titles = [placement(index, pinned)]
        // The incoming title pins at the breathing-room inset. The previous
        // title still has that inset's worth of travel before clearing the top.
        if index > 0, stickyAllowed?[index - 1] != false {
            let previous = frames[index - 1]
            let previousEnd = releasePoints?[index - 1] ?? original.minY
            let bottom = previousEnd - viewport.minY
            if bottom > 0, bottom < topInset + previous.height {
                var outgoing = previous.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
                outgoing.origin.y = bottom - previous.height
                titles.append(placement(index - 1, outgoing))
            }
        }
        let height = topInset + original.height + feather
        if let next, next.minY - viewport.minY < height {
            titles.append(Placement(index: index + 1, frame: next.offsetBy(dx: -viewport.minX, dy: -viewport.minY)))
        }
        return Layout(titles: titles, backdropHeight: height, backdropTitle: titles.first)
    }
}

private struct HeaderAnchor: NSViewRepresentable {
    let controller: TorrentStickyHeaders
    let id: String
    let title: String
    let index: Int
    let inset: CGFloat
    func makeNSView(context: Context) -> Anchor { Anchor(titleHost: controller.titleHost(id: id, title: title, inset: inset)) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Anchor, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        return nsView.titleHost.fittingSize(width: width)
    }
    func updateNSView(_ view: Anchor, context: Context) {
        view.controller = controller; view.id = id; view.title = title; view.index = index; view.inset = inset
        view.titleHost.setTitle(title, inset: inset)
        view.connect()
        // Register local frame changes here. The document-geometry observer
        // also catches padding that moves a SwiftUI ancestor of this anchor.
        view.needsLayout = true
    }
    final class Anchor: NSView {
        weak var controller: TorrentStickyHeaders?
        var id = "", title = ""
        var index = 0
        var inset: CGFloat = 0
        let titleHost: TitleHost
        init(titleHost: TitleHost) {
            self.titleHost = titleHost
            super.init(frame: .zero)
            // This row reserves space only. Its title stays in the overlay,
            // so pinning never removes content from a native List cell.
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            connect()
        }
        override func setFrameOrigin(_ origin: NSPoint) { super.setFrameOrigin(origin); connect() }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); connect() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        func connect() {
            guard !titleHost.isRetiring, window != nil, bounds.width > 0, bounds.height > 0 else { return }
            var parent = superview
            while let view = parent {
                if let table = view as? NSTableView {
                    controller?.register(table: table, anchor: self, host: titleHost, id: id, title: title, index: index, inset: inset)
                    return
                }
                parent = view.superview
            }
        }
    }
}

@MainActor
final class TorrentStickyHeaders: NSObject {
    static let topInset: CGFloat = GlassListMetrics.pinnedTitleInset
    /// Release uses displayed native rows, independent of short-section eligibility.
    static func releasePoints(headerIndices: [Int], rowCount: Int, pushLead: CGFloat, rowFrame: (Int) -> CGRect) -> [CGFloat] {
        headerIndices.enumerated().map { offset, index in
            let end = offset + 1 < headerIndices.count ? headerIndices[offset + 1] : rowCount
            let release = max(index + 1, end - 2)
            let boundary = release < rowCount ? rowFrame(release).minY : (rowCount > 0 ? rowFrame(rowCount - 1).maxY : 0)
            return boundary - pushLead
        }
    }

    /// Production pin configuration; tests exercise this entry point as well.
    static func stickyLayout(frames: [CGRect], viewport: CGRect, appearance: TorrentHeaderAppearance,
                             releases: [CGFloat], stickyAllowed: [Bool]) -> TorrentStickyHeaderGeometry.Layout? {
        TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport, feather: appearance.reach,
            topInset: topInset, releasePoints: releases, stickyAllowed: stickyAllowed)
    }
    private let measuringTitle = TitleHost(title: " ", inset: 0)
    var titleHeight: CGFloat { measuringTitle.fittingSize(width: 400).height }
    fileprivate var barSurface: NSView {
        overlay.externallyHosted = true
        return overlay.pinnedSurface
    }
    struct Header { var id: String; var title: String; var index: Int; var inset: CGFloat; var stickyAllowed = false }
    /// Identity of the section layout: only this invalidates the derived
    /// float-permission and release points, never a scroll offset.
    private struct SectionStructure: Equatable {
        let indices: [Int]
        let rowCount: Int
        let releasePoints: [CGFloat]
        let pushLead: CGFloat
        let stickyAllowed: [Bool]
    }
    private var structureCache: (structure: SectionStructure, stickyAllowed: [Bool], releases: [CGFloat])?

    private struct Measurement: Equatable {
        let leading: CGFloat
        let trailing: CGFloat
        let top: CGFloat
        let height: CGFloat
        func frame(in row: CGRect) -> CGRect {
            CGRect(x: row.minX + leading, y: row.minY + top,
                   width: max(0, row.width - leading - trailing), height: height)
        }
    }
    private weak var table: NSTableView?
    private var headers: [String: Header] = [:]
    private var measurements: [String: Measurement] = [:]
    private struct AnchorReference { weak var view: NSView? }
    private var anchors: [String: AnchorReference] = [:]
    private var titleHosts: [String: TitleHost] = [:]
    private let overlay = HeaderBackdrop()
    private var appearance = TorrentHeaderAppearance()
    private var updateScheduled = false
    private var rowIDs: [String?] = []
    private var inlineMotionUntil = Date.distantPast
    private var lastViewportOrigin: CGPoint?
    func configureAppearance(_ appearance: TorrentHeaderAppearance) {
        self.appearance = appearance
        overlay.configure(appearance)
        scheduleUpdate()
    }

    fileprivate func titleHost(id: String, title: String, inset: CGFloat) -> TitleHost {
        if let host = titleHosts[id] { host.setTitle(title, inset: inset); return host }
        let host = TitleHost(title: title, inset: inset)
        titleHosts[id] = host
        return host
    }

    fileprivate func register(table: NSTableView, anchor: NSView, host: TitleHost, id: String, title: String, index: Int, inset: CGFloat) {
        guard index < table.numberOfRows else { return }
        let measured = table.convert(anchor.bounds, from: anchor)
        let row = table.rect(ofRow: index)
        guard table.row(at: CGPoint(x: measured.midX, y: measured.midY)) == index else { return }
        if let previous = titleHosts[id], previous !== host { previous.removeFromSuperview() }
        titleHosts[id] = host
        let measurement = Measurement(leading: measured.minX - row.minX, trailing: row.maxX - measured.maxX,
                                      top: measured.minY - row.minY, height: measured.height)
        let changed = measurements[id] != measurement || headers[id].map { $0.title != title || $0.index != index || $0.inset != inset } ?? true
        anchors[id] = AnchorReference(view: anchor)
        measurements[id] = measurement
        headers[id] = Header(id: id, title: title, index: index, inset: inset, stickyAllowed: headers[id]?.stickyAllowed ?? false)
        let needsAttach = self.table !== table
        attach(table)
        if changed || needsAttach { scheduleUpdate() }
    }
    func attach(_ table: NSTableView) {
        guard self.table !== table, let scroll = table.enclosingScrollView else { return }
        NotificationCenter.default.removeObserver(self)
        lastViewportOrigin = nil
        overlay.removeFromSuperview()
        self.table = table
        structureCache = nil
        table.floatsGroupRows = false
        // Inline titles move with the document in the native scroll transaction.
        // Pinned titles live in the stationary viewport; only pushing moves them.
        table.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.frame = table.bounds
        overlay.attachViewport(to: scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleUpdate), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: NSView.frameDidChangeNotification, object: table)
        // Resolve the latest viewport once per queued update. A large native
        // scroll jump must not animate through each crossed section.
        scheduleUpdate()
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        lastViewportOrigin = nil
        overlay.removeFromSuperview()
        overlay.detachViewport()
        table = nil
        structureCache = nil
    }

    func configure(_ layout: TorrentListLayout, lowercase: Bool, inset: CGFloat) {
        if !rowIDs.isEmpty, rowIDs != layout.nativeRowIDs { inlineMotionUntil = Date().addingTimeInterval(0.35) }
        rowIDs = layout.nativeRowIDs
        let sections = layout.titledSections(lowercase: lowercase)
        let removed = Set(headers.keys).subtracting(sections.map(\.id))
        for id in removed {
            if let host = titleHosts.removeValue(forKey: id) { overlay.retire(id: id, host: host) }
        }
        headers = Dictionary(uniqueKeysWithValues: sections.map { section in
            (section.id, Header(id: section.id, title: section.title, index: layout.headerIndices[section.id]!, inset: inset, stickyAllowed: section.allowsStickyHeader))
        })
        measurements = measurements.filter { headers[$0.key] != nil }
        anchors = anchors.filter { headers[$0.key] != nil }
        for header in headers.values { _ = titleHost(id: header.id, title: header.title, inset: header.inset) }
        scheduleUpdate()
    }
    func layoutDidChange() { scheduleUpdate() }
    @objc private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.update()
        }
    }
    @objc private func update() {
        guard let table, let scroll = table.enclosingScrollView else { return }
        let clip = scroll.contentView
        // A padded SwiftUI ancestor can move without changing the anchor's
        // own frame. Geometry notifications read the final native position;
        // offscreen/recycled anchors keep their last row-relative measurement.
        for (id, reference) in anchors {
            guard let anchor = reference.view, anchor.window === table.window, anchor.isDescendant(of: table),
                  let header = headers[id], header.index < table.numberOfRows else { continue }
            let measured = table.convert(anchor.bounds, from: anchor)
            let row = table.rect(ofRow: header.index)
            guard table.row(at: CGPoint(x: measured.midX, y: measured.midY)) == header.index else { continue }
            measurements[id] = Measurement(leading: measured.minX - row.minX, trailing: row.maxX - measured.maxX,
                top: measured.minY - row.minY, height: measured.height)
        }
        let ordered = headers.values.filter { $0.index < table.numberOfRows }.sorted { $0.index < $1.index }
        let frames = ordered.map { header in
            let row = table.rect(ofRow: header.index)
            // Offscreen headers retain their last measured row-relative geometry.
            let measured = measurements[header.id]
            return measured?.frame(in: row) ?? row
        }
        let viewport = table.convert(clip.bounds, from: clip)
        let didScroll = lastViewportOrigin.map { $0 != viewport.origin } ?? false
        lastViewportOrigin = viewport.origin
        let releasePoints = Self.releasePoints(headerIndices: ordered.map(\.index),
            rowCount: table.numberOfRows, pushLead: appearance.pushLead, rowFrame: { table.rect(ofRow: $0) })
        let structure = SectionStructure(indices: ordered.map(\.index), rowCount: table.numberOfRows, releasePoints: releasePoints,
                                         pushLead: appearance.pushLead, stickyAllowed: ordered.map(\.stickyAllowed))
        if structureCache?.structure != structure {
            structureCache = (structure: structure,
                              stickyAllowed: ordered.map(\.stickyAllowed),
                              releases: releasePoints)
        }
        let stickyAllowed = structureCache?.stickyAllowed ?? []
        let releases = structureCache?.releases ?? []
        // Pinning is a function of the current document and viewport. A section
        // edit must not leave a frozen position to be released by the next gesture.
        let sticky = Self.stickyLayout(frames: frames, viewport: viewport, appearance: appearance, releases: releases, stickyAllowed: stickyAllowed)
        let layout = TorrentStickyHeaderGeometry.displayLayout(frames: frames, viewport: viewport, sticky: sticky)
        if overlay.frame != table.bounds { overlay.frame = table.bounds }
        overlay.attachViewport(to: scroll)
        overlay.isHidden = false
        overlay.present(layout: layout, headers: ordered, hosts: titleHosts,
                        viewport: viewport, animateInline: !didScroll && Date() < inlineMotionUntil && NSApp.currentEvent?.type != .scrollWheel)
    }
    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        overlay.removeFromSuperview(); overlay.detachViewport()
    }
}

final class HeaderBackdrop: NSView {
    let pinnedSurface = HeaderViewportSurface()
    var externallyHosted = false
    private let effect = TorrentHeaderMaterialView()
    private var titles: [String: TitleHost] = [:]
    private(set) var backdropIsActive = false
    private var settings = TorrentHeaderAppearance()
    private var backdropHeaderID: String?
    private weak var viewportScrollView: NSScrollView?
    func attachViewport(to scroll: NSScrollView) {
        viewportScrollView = scroll
        // Background filters sample their parent's rendered content. Keep the
        // blur beside the native clip view, outside SwiftUI's empty bar host.
        if effect.superview !== scroll {
            scroll.addSubview(effect, positioned: .above, relativeTo: scroll.contentView)
            effect.layer?.zPosition = TorrentListRenderOrder.sectionHeader
        }
        guard !externallyHosted else { return }
        if pinnedSurface.superview !== scroll {
            scroll.addSubview(pinnedSurface, positioned: .above, relativeTo: scroll.contentView)
        }
        if pinnedSurface.frame != scroll.contentView.frame { pinnedSurface.frame = scroll.contentView.frame }
        pinnedSurface.isHidden = false
    }
    func detachViewport() {
        effect.removeFromSuperview()
        viewportScrollView = nil
        if !externallyHosted { pinnedSurface.removeFromSuperview() }
    }
    func configure(_ settings: TorrentHeaderAppearance) {
        self.settings = settings
        effect.configure(strength: settings.strength)
    }
    func retire(id: String, host: TitleHost) {
        titles[id] = nil
        guard host.window != nil else { return }
        let parent: NSView = host.superview === pinnedSurface ? pinnedSurface : self
        let position = parent.convert(host.bounds, from: host)
        host.isRetiring = true
        host.isPinned = parent === pinnedSurface
        if host.superview !== parent { parent.addSubview(host) }
        host.frame = position
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ReduceMotion.enabled ? 0 : settings.titleOut
            host.animator().setFrameOrigin(CGPoint(x: position.minX, y: position.minY - 20))
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(settings.titleOut))
            host.removeFromSuperview()
        }
    }

    func dismiss() {
        hideTitles()
        setBackdropActive(false)
    }
    private func setBackdropActive(_ active: Bool) {
        guard backdropIsActive != active else { return }
        backdropIsActive = active
        animateBackdrop(active)
    }
    private func animateBackdrop(_ active: Bool) {
        // Scroll travel moves the full material and gradient with their title.
        // Opacity changes only when the surface enters/leaves use, not on push.
        // A live-scroll/layout caller can disable actions in its transaction.
        // Re-enable them only for this fade, then restore the caller's state.
        // NSAnimationContext's duration alone does not override that flag.
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ReduceMotion.enabled ? 0 : (active ? settings.backgroundIn : settings.backgroundOut)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            effect.animator().alphaValue = active ? 1 : 0
        }
        CATransaction.commit()
    }
    func hideTitles(except retained: Set<String> = []) {
        for (id, host) in titles where !retained.contains(id) {
            host.isPinned = false
            host.isHidden = true
        }
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.zPosition = TorrentListRenderOrder.sectionHeader
        layer?.masksToBounds = true
        effect.alphaValue = 0
        pinnedSurface.addSubview(effect)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(layout: TorrentStickyHeaderGeometry.Layout, headers: [TorrentStickyHeaders.Header], hosts: [String: TitleHost], backdropActive: Bool? = nil, viewport: CGRect? = nil, animateInline: Bool = false) {
        isHidden = false
        let pinnedTitle = layout.backdropTitle ?? layout.titles.first { $0.pinned }
        if let pinnedTitle { backdropHeaderID = headers[pinnedTitle.index].id }
        // When scrolling back to inline, a finishing fade follows that same
        // title rather than staying behind at the pin line.
        let backdropTitle = pinnedTitle ?? layout.titles.first { headers[$0.index].id == backdropHeaderID }
        let effectHeight = layout.backdropHeight > 0 ? layout.backdropHeight : effect.frame.height
        let relativeTop = backdropTitle.map { $0.frame.minY - TorrentStickyHeaders.topInset }
        setBackdropActive(backdropActive ?? (pinnedTitle != nil && (relativeTop ?? 0) + effectHeight > 0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let viewport = viewport ?? bounds
        let viewportOffset: CGPoint
        if externallyHosted, let table = superview as? NSTableView, let clip = table.enclosingScrollView?.contentView {
            viewportOffset = pinnedSurface.convert(clip.bounds.origin, from: clip)
        } else { viewportOffset = .zero }
        // One measured translation for title, material and gradient. Preserve
        // the full gradient height; clipping at the viewport reveals its tail
        // naturally as the complete surface scrolls out.
        effect.configure(strength: settings.strength, titleHeight: backdropTitle?.frame.height)
        let effectFrame: CGRect
        if let scroll = viewportScrollView, let relativeTop {
            let clip = scroll.contentView
            effectFrame = scroll.convert(CGRect(x: clip.bounds.minX, y: clip.bounds.minY + relativeTop,
                width: viewport.width, height: effectHeight), from: clip)
        } else if viewportScrollView != nil {
            effectFrame = effect.frame
        } else {
            let fadeTop = relativeTop.map { viewportOffset.y + $0 } ?? effect.frame.minY
            effectFrame = CGRect(x: viewportOffset.x, y: fadeTop, width: viewport.width, height: effectHeight)
        }
        if effect.frame != effectFrame { effect.frame = effectFrame }
        // Keep the whole gradient while fading out. Every title shares the
        // foreground plane above it, including incoming inline titles.
        CATransaction.commit()
        let visible = Set(layout.titles.map { headers[$0.index].id })
        hideTitles(except: visible)
        for placement in layout.titles {
            let header = headers[placement.index]
            guard let host = hosts[header.id] else { continue }
            // In the SwiftUI overlay, inline and pinned titles share one plane
            // above the native blur. Pinning never changes their compositing.
            let inViewport = externallyHosted || placement.pinned
            let parent: NSView = inViewport ? pinnedSurface : self
            let frame = inViewport ? placement.frame.offsetBy(dx: viewportOffset.x, dy: viewportOffset.y)
                : placement.frame.offsetBy(dx: viewport.minX, dy: viewport.minY)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Move the one cached title only when it pins or returns inline.
            // A pinned title never counter-scrolls inside the moving document.
            if host.superview !== parent { parent.addSubview(host) }
            host.isPinned = placement.pinned
            host.alphaValue = 1
            if !animateInline || placement.pinned { host.layer?.removeAllAnimations() }
            host.isHidden = false
            titles[header.id] = host
            // Scroll coordinates must bypass any inherited AppKit animation
            // context.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animateInline && !placement.pinned && !ReduceMotion.enabled ? 0.25 : 0
                context.allowsImplicitAnimation = context.duration > 0
                if host.frame.size != frame.size { host.setFrameSize(frame.size) }
                if host.frame.origin != frame.origin {
                    if context.duration > 0 { host.animator().setFrameOrigin(frame.origin) }
                    else { host.setFrameOrigin(frame.origin) }
                }
            }
            CATransaction.commit()
            // The native material is below every title; the title stays sharp.
        }
    }
}

/// Stationary sibling of the native clip view. Elastic and concurrent document
/// scrolling cannot move a pinned title before its next main-thread callback.
final class HeaderViewportSurface: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.zPosition = TorrentListRenderOrder.sectionHeader
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class TitleHost: NSView {
    var isPinned = false
    var isRetiring = false
    private let hosting: NSHostingController<StickyTitleLabel>
    private var titleKey = ""
    private var currentTitle = ""
    private var currentInset: CGFloat = 0
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init(title: String, inset: CGFloat) {
        hosting = NSHostingController(rootView: StickyTitleLabel(title: title, inset: inset))
        super.init(frame: .zero)
        wantsLayer = true
        currentTitle = title; currentInset = inset
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        if let view = hosting.view as? NSHostingView<StickyTitleLabel> {
            view.sizingOptions = []
            view.safeAreaRegions = []
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }
        addSubview(hosting.view)
        titleKey = "\(title):\(inset)"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var measuredWidth: CGFloat?
    private var measuredHeight: CGFloat = 0
    func fittingSize(width: CGFloat) -> CGSize {
        if measuredWidth != width {
            measuredHeight = hosting.sizeThatFits(in: CGSize(width: width, height: 1000)).height
            measuredWidth = width
        }
        return CGSize(width: width, height: measuredHeight)
    }
    func setTitle(_ title: String, inset: CGFloat) {
        let key = "\(title):\(inset)"
        guard titleKey != key else { return }
        titleKey = key
        measuredWidth = nil
        currentTitle = title; currentInset = inset
        hosting.rootView = StickyTitleLabel(title: title, inset: inset)
    }
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        if hosting.view.frame != bounds { hosting.view.frame = bounds }
    }
    override func layout() {
        super.layout()
        if hosting.view.frame != bounds { hosting.view.frame = bounds }
    }
}

extension View {
    /// Owns the header's reserved space and its scroll-effect policy together.
    func torrentStickyHeaders(_ controller: TorrentStickyHeaders) -> some View {
        self
            .ignoresSafeArea(.container, edges: .top)
            // safeAreaBar adds a separate window-anchored AppKit pocket even
            // when scrollEdgeEffectHidden is true. Reserve the same space
            // without registering another material behind our moving surface.
            .safeAreaInset(edge: .top, spacing: 0) {
                TorrentHeaderSurface(controller: controller)
                    .frame(height: controller.titleHeight)
                    .allowsHitTesting(false)
            }
            .glassScrollEdges(.sectionTitles)
    }
}

struct TorrentHeaderSurface: NSViewRepresentable {
    let controller: TorrentStickyHeaders
    func makeNSView(context: Context) -> NSView { controller.barSurface }
    func updateNSView(_ view: NSView, context: Context) {}
}
