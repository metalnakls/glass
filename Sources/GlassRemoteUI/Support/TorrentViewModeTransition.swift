import AppKit
import SwiftUI
import Observation

/// Requested presentation is independent of the available width.
enum TorrentViewMode: Hashable { case icons, compact, regular }
struct TorrentViewPresentation: Hashable {
    let mode: TorrentViewMode
    let sizeLevel: Int
    static func requested(grid: Bool, iconsEnabled: Bool, compactEnabled: Bool, size: Int) -> Self {
        let level = compactEnabled ? size : max(1, size)
        return Self(mode: iconsEnabled && grid ? .icons : (level == 0 ? .compact : .regular), sizeLevel: level)
    }
}

/// Pure endpoint policy used by the native handoff. Unpaired/offscreen items
/// never get a fabricated start or finish position.
enum TorrentViewModeGeometry {
    struct Match: Equatable {
        let id: String
        let source: CGRect
        let destination: CGRect
    }
    static func usable(_ rect: CGRect, in viewport: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0 && rect.intersects(viewport)
    }
    static func matches(source: [String: CGRect], destination: [String: CGRect], viewport: CGRect) -> [Match] {
        source.keys.sorted().compactMap { id in
            guard let from = source[id], let to = destination[id],
                  usable(from, in: viewport), usable(to, in: viewport) else { return nil }
            return Match(id: id, source: from, destination: to)
        }
    }
}


/// A container can lay out before its native artwork rows exist. Empty visible
/// endpoint maps are therefore not an empty data set and must not consume sources.
enum TorrentViewModeReadiness {
    enum Decision { case wait, ready, settle }
    static func decision(containerLaidOut: Bool, scrollSubmitted: Bool,
                         sourceIDs: Set<String>, destinationIDs: Set<String>,
                         visibleDestinationIDs: Set<String>, hasPendingVisibleLayout: Bool,
                         requiredAnchorID: String? = nil) -> Decision {
        guard containerLaidOut, scrollSubmitted else { return .wait }
        guard !sourceIDs.isEmpty, !destinationIDs.isEmpty,
              !sourceIDs.isDisjoint(with: destinationIDs) else { return .settle }
        if let requiredAnchorID, destinationIDs.contains(requiredAnchorID),
           !visibleDestinationIDs.contains(requiredAnchorID) { return .wait }
        guard !visibleDestinationIDs.intersection(destinationIDs).isEmpty, !hasPendingVisibleLayout else { return .wait }
        // Do not wait for every old source: some legitimately lie outside the
        // destination viewport after reflow. Only measured visible pairs fly.
        return .ready
    }
}

struct TorrentArtworkTransitionContext {
    let owner: TorrentViewModeTransition
    let id: String
    let mode: TorrentViewMode
    let revision: Int
    @MainActor init(owner: TorrentViewModeTransition, id: String, mode: TorrentViewMode) {
        self.owner = owner; self.id = id; self.mode = mode; revision = owner.generation
    }
}

extension EnvironmentValues {
    @Entry var torrentArtworkTransition: TorrentArtworkTransitionContext? = nil
}

@MainActor @Observable
final class TorrentViewModeLabels { var visible = true }

struct TorrentViewModeLabelFade: ViewModifier {
    @Environment(\.torrentArtworkTransition) private var context
    @Environment(\.accessibilityReduceMotion) private var reduced
    @ViewBuilder func body(content: Content) -> some View {
        if let context {
            content.opacity(context.owner.labels.visible ? 1 : 0)
                .animation(GlassMotion.viewModeLabelAnimation(reduceMotion: reduced), value: context.owner.labels.visible)
        } else { content }
    }
}

/// Hosts the actual artwork renderer so it can survive replacement of its List
/// or grid parent. No bitmap capture and no cross-host matchedGeometryEffect.
struct TorrentArtworkSurface: ViewModifier {
    @Environment(\.torrentArtworkTransition) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var direction
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.glassSampleArtwork) private var sampleArtwork

    @ViewBuilder func body(content: Content) -> some View {
        if let context {
            TorrentArtworkAnchor(context: context, content: AnyView(content
                .environment(\.torrentArtworkTransition, nil)
                .environment(\.colorScheme, colorScheme)
                .environment(\.layoutDirection, direction)
                .environment(\.locale, locale)
                .environment(\.isEnabled, enabled)
                .environment(\.glassSampleArtwork, sampleArtwork)))
        } else { content }
    }
}

private struct TorrentArtworkAnchor: NSViewRepresentable {
    let context: TorrentArtworkTransitionContext
    let content: AnyView
    func makeNSView(context: Context) -> ArtworkAnchorView { ArtworkAnchorView() }
    func updateNSView(_ view: ArtworkAnchorView, context: Context) { view.update(self.context, content: content) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ArtworkAnchorView, context: Context) -> CGSize? {
        nsView.host?.fittingSize
    }
    static func dismantleNSView(_ view: ArtworkAnchorView, coordinator: ()) { view.detach() }
}

@MainActor
final class ArtworkAnchorView: NSView {
    var context: TorrentArtworkTransitionContext?
    var host: NSHostingView<AnyView>?
    var laidOut = false
    private var pendingContent: AnyView?
    override var isFlipped: Bool { true }

    func update(_ next: TorrentArtworkTransitionContext, content: AnyView) {
        if context?.id != next.id || context?.mode != next.mode || context?.revision != next.revision {
            detach()
            if host?.superview === self { host?.removeFromSuperview() }
            host = nil
            laidOut = false
        }
        context = next
        pendingContent = content
        if host == nil {
            let renderer = NSHostingView(rootView: content)
            renderer.sizingOptions = [.intrinsicContentSize]
            renderer.frame = bounds
            renderer.autoresizingMask = [.width, .height]
            renderer.wantsLayer = true
            addSubview(renderer)
            host = renderer
        } else if host?.superview === self { host?.rootView = content }
        next.owner.register(self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { context?.owner.register(self) }
    }
    override func layout() {
        super.layout()
        if host?.superview === self { host?.frame = bounds }
        laidOut = bounds.width > 0 && bounds.height > 0
        context?.owner.anchorDidLayout(self)
    }
    func detach() { context?.owner.unregister(self) }
    func takeRenderer() -> NSHostingView<AnyView>? {
        guard let host, host.superview === self else { return nil }
        host.removeFromSuperview()
        return host
    }
    func restore(_ renderer: NSHostingView<AnyView>) {
        guard context != nil else { return }
        if let old = host, old !== renderer { old.removeFromSuperview() }
        renderer.removeFromSuperview()
        renderer.layer?.removeAllAnimations()
        renderer.layer?.opacity = 1
        if let pendingContent { renderer.rootView = pendingContent }
        renderer.frame = bounds
        renderer.autoresizingMask = [.width, .height]
        addSubview(renderer)
        host = renderer
    }
}

struct TorrentViewModeViewport: NSViewRepresentable {
    let owner: TorrentViewModeTransition
    func makeNSView(context: Context) -> ViewModeViewportView {
        let view = ViewModeViewportView()
        view.owner = owner
        owner.attachViewport(view)
        return view
    }
    func updateNSView(_ view: ViewModeViewportView, context: Context) { view.owner = owner; owner.attachViewport(view) }
    static func dismantleNSView(_ view: ViewModeViewportView, coordinator: ()) { view.owner?.detachViewport(view) }
}

@MainActor
final class ViewModeViewportView: NSView {
    weak var owner: TorrentViewModeTransition?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); owner?.viewportDidLayout(bounds.size) }
}

/// A flight keeps both live renderers. Source and target use their own native
/// layout sizes; normalized wrappers scale their drawing, not SwiftUI layout.
@MainActor
private final class ArtworkFlight: NSView {
    let source: NSView
    let target: NSHostingView<AnyView>
    weak var destination: ArtworkAnchorView?
    var destinationRect = CGRect.zero
    let sourceWrapper: NSView
    let targetWrapper: NSView
    override var isFlipped: Bool { true }

    init(source: NSView, sourceRect: CGRect, target: NSHostingView<AnyView>, destination: ArtworkAnchorView) {
        self.source = source; self.target = target; self.destination = destination
        sourceWrapper = Self.normalized(source, size: sourceRect.size)
        targetWrapper = Self.normalized(target, size: sourceRect.size)
        super.init(frame: sourceRect)
        wantsLayer = true
        addSubview(sourceWrapper); addSubview(targetWrapper)
        targetWrapper.wantsLayer = true; sourceWrapper.wantsLayer = true
        targetWrapper.layer?.opacity = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    static func normalized(_ view: NSView, size: CGSize) -> NSView {
        let natural = view.bounds.size
        let wrapper = NSView(frame: CGRect(origin: .zero, size: size))
        wrapper.wantsLayer = true
        wrapper.bounds = CGRect(origin: .zero, size: natural)
        view.removeFromSuperview()
        view.frame = CGRect(origin: .zero, size: natural)
        view.autoresizingMask = []
        wrapper.addSubview(view)
        return wrapper
    }
    func interruptedVisual() -> (NSView, CGRect) {
        let current = layer?.presentation() ?? layer!
        let rect = current.frame
        let transform = current.transform
        let sourceAlpha = sourceWrapper.layer?.presentation()?.opacity ?? sourceWrapper.layer?.opacity ?? 1
        let targetAlpha = targetWrapper.layer?.presentation()?.opacity ?? targetWrapper.layer?.opacity ?? 1
        layer?.removeAllAnimations()
        sourceWrapper.layer?.removeAllAnimations(); targetWrapper.layer?.removeAllAnimations()
        sourceWrapper.layer?.opacity = sourceAlpha; targetWrapper.layer?.opacity = targetAlpha
        removeFromSuperview()
        let wrapper = NSView(frame: CGRect(origin: .zero, size: rect.size))
        wrapper.wantsLayer = true
        wrapper.addSubview(self)
        layer?.anchorPoint = .zero
        layer?.position = .zero
        layer?.transform = transform
        return (wrapper, rect)
    }
}

@MainActor
final class TorrentViewModeTransition {
    let labels = TorrentViewModeLabels()
    private(set) weak var viewport: ViewModeViewportView?
    private weak var layoutBarrier: TorrentViewModeLayoutBarrier.Barrier?
    private var destinationIDs = Set<String>()
    private var anchors: [String: WeakArtworkAnchor] = [:]
    private var sources: [String: (view: NSView, frame: CGRect)] = [:]
    private var flights: [String: ArtworkFlight] = [:]
    private(set) var generation = 0
    private var requested: TorrentViewMode?
    private var destinationReady = false
    private var scrollPrepared = false
    private var activeMode: TorrentViewMode?
    private var resolutionQueued = false
    private var reduced = false
    private(set) var scrollAnchor: String?
    private var scrollAnchorY: CGFloat?
    private var restoredScroll = false
    private var viewportSize = CGSize.zero
    private var scrollObservers: [NSObjectProtocol] = []
    private var pendingScrolls = Set<ObjectIdentifier>()
    isolated deinit { removeScrollObservers() }

    private final class WeakArtworkAnchor {
        weak var value: ArtworkAnchorView?
        init(_ value: ArtworkAnchorView) { self.value = value }
    }
    func attachViewport(_ view: ViewModeViewportView) { viewport = view }
    func detachViewport(_ view: ViewModeViewportView) {
        guard viewport === view else { return }
        cancel()
        viewport = nil
    }
    func registerLayoutBarrier(_ barrier: TorrentViewModeLayoutBarrier.Barrier) {
        guard barrier.revision == generation else { return }
        layoutBarrier = barrier
    }

    var pending: Bool { requested != nil }
    func accepts(_ context: TorrentArtworkTransitionContext) -> Bool {
        context.revision == generation && (activeMode == nil || context.mode == activeMode)
    }
    func register(_ anchor: ArtworkAnchorView) {
        guard let context = anchor.context, accepts(context) else { return }
        activeMode = context.mode
        anchors[context.id] = WeakArtworkAnchor(anchor)
        if pending, context.mode == requested, sources[context.id] != nil, anchor.host?.superview === anchor { anchor.host?.layer?.opacity = 0 }
        if pending { observePendingUserScroll(anchor) }
        scheduleResolution()
    }
    func unregister(_ anchor: ArtworkAnchorView) {
        guard let id = anchor.context?.id, anchors[id]?.value === anchor else { return }
        anchors[id] = nil
    }
    func anchorDidLayout(_ anchor: ArtworkAnchorView) {
        if let id = anchor.context?.id, let flight = flights[id], flight.destination === anchor,
           let frame = visibleFrame(anchor), frame != flight.destinationRect {
            // Direct resize/layout is authoritative. Settle immediately instead
            // of flying to obsolete coordinates and snapping on completion.
            cancel()
        }
        register(anchor)
    }
    func viewportDidLayout(_ size: CGSize) {
        if viewportSize != .zero, viewportSize != size, (pending || !flights.isEmpty) { cancel() }
        viewportSize = size
        scheduleResolution()
    }
    private func removeScrollObservers() {
        for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) }
        scrollObservers.removeAll()
        pendingScrolls.removeAll()
    }
    private func observePendingUserScroll(_ anchor: ArtworkAnchorView) {
        guard let scroll = anchor.enclosingScrollView,
              pendingScrolls.insert(ObjectIdentifier(scroll)).inserted else { return }
        // Direct user input abandons the pending visual handoff. Programmatic
        // scroll restoration emits bounds changes, not native live-scroll events.
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
            scrollObservers.append(NotificationCenter.default.addObserver(forName: name, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
    }
    private func observeDirectScroll(_ destinations: [ArtworkAnchorView]) {
        removeScrollObservers()
        var seen = Set<ObjectIdentifier>()
        for anchor in destinations {
            guard let clip = anchor.enclosingScrollView?.contentView,
                  seen.insert(ObjectIdentifier(clip)).inserted else { continue }
            clip.postsBoundsChangedNotifications = true
            let restingBounds = clip.bounds
            scrollObservers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self, weak clip] _ in
                MainActor.assumeIsolated {
                    guard let clip, clip.bounds != restingBounds else { return }
                    self?.cancel()
                }
            })
        }
    }

    func prepare(to mode: TorrentViewMode, selection: String?, reduceMotion: Bool, destinationIDs: Set<String>) {
        let sourceRevision = generation
        let sourceMode = activeMode
        generation += 1
        self.destinationIDs = destinationIDs
        removeScrollObservers()
        guard let viewport, viewport.window != nil else { cancel(); activeMode = mode; return }
        let interrupted = flights.mapValues { $0.interruptedVisual() }
        flights.removeAll()
        for (id, value) in interrupted {
            value.0.frame.origin = value.1.origin
            viewport.addSubview(value.0)
            sources[id] = (value.0, value.1)
        }
        for (id, weak) in anchors {
            guard sources[id] == nil, let anchor = weak.value,
                  anchor.context?.revision == sourceRevision, anchor.context?.mode == sourceMode,
                  let rect = visibleFrame(anchor),
                  let renderer = anchor.takeRenderer() else { continue }
            let visual = ArtworkFlight.normalized(renderer, size: rect.size)
            visual.frame.origin = rect.origin
            viewport.addSubview(visual)
            sources[id] = (visual, rect)
        }
        scrollAnchor = selection.flatMap { sources[$0] != nil && destinationIDs.contains($0) ? $0 : nil }
            ?? sources.filter { destinationIDs.contains($0.key) }.min(by: { $0.value.frame.minY < $1.value.frame.minY })?.key
        scrollAnchorY = scrollAnchor.flatMap { sources[$0]?.frame.minY }
        activeMode = mode
        labels.visible = false
        requested = mode; destinationReady = false; scrollPrepared = false; restoredScroll = false; reduced = reduceMotion
    }
    func destinationDidLayout(_ mode: TorrentViewMode, revision: Int, contentIDs: Set<String>) {
        guard mode == requested, revision == generation else { return }
        destinationIDs = contentIDs
        destinationReady = true
        scheduleResolution()
    }
    func didSubmitScrollRestoration() {
        scrollPrepared = true
        // Submission is not layout completion. Require a native layout pass
        // after the scroll request before measuring endpoints or starting flights.
        destinationReady = false
        layoutBarrier?.needsLayout = true
    }
    func scheduleResolution() {
        guard pending, destinationReady, scrollPrepared, !resolutionQueued else { return }
        resolutionQueued = true
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resolutionQueued = false
            guard self.generation == token else { self.scheduleResolution(); return }
            self.resolve()
        }
    }
    private func visibleFrame(_ anchor: ArtworkAnchorView) -> CGRect? {
        guard let viewport, anchor.window === viewport.window, anchor.window != nil,
              anchor.laidOut, !anchor.isHiddenOrHasHiddenAncestor else { return nil }
        let frame = anchor.convert(anchor.bounds, to: viewport)
        guard TorrentViewModeGeometry.usable(frame, in: viewport.bounds) else { return nil }
        var ancestor = anchor.superview
        while let current = ancestor {
            if let clip = current as? NSClipView,
               !anchor.convert(anchor.bounds, to: clip).intersects(clip.bounds) { return nil }
            ancestor = current.superview
        }
        return frame
    }
    private func resolve() {
        guard let viewport, let requested else { return }
        let destinations = anchors.compactMapValues { weak -> ArtworkAnchorView? in
            guard let value = weak.value, let context = value.context,
                  context.mode == requested, context.revision == generation,
                  destinationIDs.contains(context.id), visibleFrame(value) != nil else { return nil }
            return value
        }
        let hasPendingVisibleLayout = anchors.values.contains { weak in
            guard let anchor = weak.value, let context = anchor.context, accepts(context),
                  context.mode == requested, destinationIDs.contains(context.id), anchor.window === viewport.window,
                  !anchor.laidOut, !anchor.isHiddenOrHasHiddenAncestor else { return false }
            return TorrentViewModeGeometry.usable(anchor.convert(anchor.bounds, to: viewport), in: viewport.bounds)
        }
        let readiness = TorrentViewModeReadiness.decision(
            containerLaidOut: destinationReady, scrollSubmitted: scrollPrepared,
            sourceIDs: Set(sources.keys), destinationIDs: destinationIDs,
            visibleDestinationIDs: Set(destinations.keys), hasPendingVisibleLayout: hasPendingVisibleLayout,
            requiredAnchorID: scrollAnchor)
        guard readiness != .wait else { return }
        if readiness == .settle { cancel(); return }
        if !restoredScroll {
            restoredScroll = true
            if let id = scrollAnchor, let anchor = destinations[id], let targetY = scrollAnchorY,
               let frame = visibleFrame(anchor), let scroll = anchor.enclosingScrollView {
                let clip = scroll.contentView
                let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - clip.bounds.height)
                let y = max(0, min(maximum, clip.bounds.origin.y + frame.minY - targetY))
                let target = CGPoint(x: clip.bounds.origin.x, y: y)
                if target != clip.bounds.origin {
                    destinationReady = false
                    clip.scroll(to: target)
                    scroll.reflectScrolledClipView(clip)
                    layoutBarrier?.needsLayout = true
                    return
                }
            }
        }
        let token = generation
        let matched = Dictionary(uniqueKeysWithValues: TorrentViewModeGeometry.matches(
            source: sources.mapValues(\.frame),
            destination: destinations.compactMapValues { visibleFrame($0) }, viewport: viewport.bounds
        ).map { ($0.id, $0) })
        for (id, source) in sources {
            guard let anchor = destinations[id], let rect = matched[id]?.destination,
                  let target = anchor.takeRenderer() else {
                source.view.removeFromSuperview()
                continue
            }
            target.layer?.opacity = 1
            let flight = ArtworkFlight(source: source.view, sourceRect: source.frame, target: target, destination: anchor)
            flight.destinationRect = rect
            viewport.addSubview(flight)
            flights[id] = flight
            animate(flight, to: rect, reduced: reduced) { [weak self, weak flight] in
                guard let self, self.generation == token, let flight, self.flights[id] === flight else { return }
                if let destination = flight.destination, destination.window != nil, destination.context?.mode == requested {
                    destination.restore(flight.target)
                }
                flight.removeFromSuperview()
                self.flights[id] = nil
                if self.flights.isEmpty { self.removeScrollObservers() }
            }
        }
        sources.removeAll()
        if !flights.isEmpty { observeDirectScroll(Array(destinations.values)) }
        self.requested = nil
        labels.visible = true
        for weak in anchors.values {
            if let anchor = weak.value, anchor.host?.superview === anchor { anchor.host?.layer?.opacity = 1 }
        }
    }
    private func animate(_ flight: ArtworkFlight, to destination: CGRect, reduced: Bool, completion: @escaping @MainActor () -> Void) {
        guard let layer = flight.layer else { completion(); return }
        let duration = reduced ? GlassMotion.viewModeReducedDuration : GlassMotion.viewModeDuration
        let origin = flight.frame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.anchorPoint = .zero
        layer.position = destination.origin
        let scale = CATransform3DMakeScale(destination.width / origin.width, destination.height / origin.height, 1)
        layer.transform = reduced ? CATransform3DIdentity : scale
        if reduced {
            flight.frame = destination
            flight.sourceWrapper.frame = flight.bounds
            flight.targetWrapper.frame = flight.bounds
        }
        let movement = CAAnimationGroup()
        if !reduced {
            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = NSValue(point: origin.origin); position.toValue = NSValue(point: destination.origin)
            let transform = CABasicAnimation(keyPath: "transform")
            transform.fromValue = NSValue(caTransform3D: CATransform3DIdentity); transform.toValue = NSValue(caTransform3D: scale)
            movement.animations = [position, transform]
        }
        movement.duration = duration
        movement.timingFunction = GlassMotion.viewModeTiming
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        layer.add(movement, forKey: "viewMode")
        for (child, from, to) in [(flight.sourceWrapper, Float(1), Float(0)), (flight.targetWrapper, Float(0), Float(1))] {
            child.layer?.opacity = to
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from; fade.toValue = to
            fade.duration = reduced ? duration : GlassMotion.viewModeFadeDuration
            fade.timingFunction = GlassMotion.viewModeFadeTiming
            child.layer?.add(fade, forKey: "viewModeFade")
        }
        CATransaction.commit()
    }
    func cancel() {
        removeScrollObservers()
        let activeFlights = Array(flights.values)
        flights.removeAll()
        requested = nil; destinationReady = false
        for flight in activeFlights {
            if let destination = flight.destination, destination.window != nil { destination.restore(flight.target) }
            flight.removeFromSuperview()
        }
        flights.removeAll()
        for source in sources.values { source.view.removeFromSuperview() }
        sources.removeAll()
        for weak in anchors.values {
            if let anchor = weak.value, anchor.host?.superview === anchor { anchor.host?.layer?.opacity = 1 }
        }
        requested = nil; destinationReady = false
        labels.visible = true
    }
}

/// The active native container has completed a layout pass, even when it has no
/// artwork rows. This closes unmatched handoffs without guessing a time delay.
struct TorrentViewModeLayoutBarrier: NSViewRepresentable {
    let owner: TorrentViewModeTransition
    let mode: TorrentViewMode
    let revision: Int
    let contentIDs: Set<String>
    func makeNSView(context: Context) -> Barrier { Barrier() }
    func updateNSView(_ view: Barrier, context: Context) {
        view.owner = owner; view.mode = mode; view.revision = revision
        view.contentIDs = contentIDs
        owner.registerLayoutBarrier(view)
        view.needsLayout = true
    }
    final class Barrier: NSView {
        weak var owner: TorrentViewModeTransition?
        var mode: TorrentViewMode?
        var revision = 0
        var contentIDs = Set<String>()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
        override func layout() {
            super.layout()
            if window != nil, let mode { owner?.destinationDidLayout(mode, revision: revision, contentIDs: contentIDs) }
        }
    }
}
