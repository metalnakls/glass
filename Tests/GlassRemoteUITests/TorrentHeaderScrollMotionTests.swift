import AppKit
import Testing
@testable import GlassRemoteUI

struct TorrentHeaderScrollMotionTests {
    @Test("slow scrolling keeps floating headers visible")
    func slowScroll() {
        var motion = TorrentHeaderScrollMotion()
        motion.begin(offset: 0, at: 0)
        for frame in 1...60 {
            motion.record(offset: CGFloat(frame * 2), at: Double(frame) / 60, viewportHeight: 400)
            #expect(!motion.suppressesFloatingTitles)
        }
    }

    @Test("fast scrolling is recognized when native notifications arrive between display frames", arguments: [1.0, -1.0])
    func coalescedFling(direction: CGFloat) {
        var motion = TorrentHeaderScrollMotion()
        motion.begin(offset: 1000, at: 0)
        // The same 1,200 pt/s gesture sampled at 240 Hz must not be mistaken for
        // a 600 pt/s gesture because each interval was rounded up separately.
        for sample in 1...24 {
            motion.record(offset: 1000 + direction * CGFloat(sample * 5),
                          at: Double(sample) / 240, viewportHeight: 400)
        }
        #expect(motion.suppressesFloatingTitles)
    }

    @MainActor @Test("fast-scroll visibility stays continuous across the pin boundary in either direction", arguments: [false, true])
    func fastPinHandoff(reverse: Bool) {
        let backdrop = HeaderBackdrop(frame: .init(x: 0, y: 0, width: 500, height: 400))
        backdrop.externallyHosted = true
        let title = TitleHost(title: "Completed", inset: 16)
        let headers = [TorrentStickyHeaders.Header(id: "finished", title: "Completed", index: 0, inset: 16)]
        let frames = [CGRect(x: 0, y: 200, width: 500, height: 47)]
        var offsets = Array(stride(from: CGFloat(130), through: 185, by: 1))
        if reverse { offsets.reverse() }
        var previous: CGFloat?
        for offset in offsets {
            let viewport = CGRect(x: 0, y: offset, width: 500, height: 400)
            let sticky = TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport,
                topInset: TorrentStickyHeaders.topInset, releasePoints: [1000])
            let layout = TorrentStickyHeaderGeometry.displayLayout(frames: frames, viewport: viewport, sticky: sticky)
            backdrop.present(layout: layout, headers: headers, hosts: ["finished": title], suppressFloatingTitles: true)
            if let previous {
                #expect(abs(title.alphaValue - previous) < 0.05,
                        "one point of scrolling changed title visibility from \(previous) to \(title.alphaValue)")
            }
            previous = title.alphaValue
        }
    }

    @MainActor @Test("native fast-scroll fades interpolate and newly crossed floating titles do not flash")
    func nativeVisibilityTransition() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 500, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let backdrop = HeaderBackdrop(frame: .init(x: 0, y: 0, width: 500, height: 400))
        backdrop.externallyHosted = true
        window.contentView = backdrop.pinnedSurface
        window.orderFront(nil)
        var appearance = TorrentHeaderAppearance()
        appearance.titleIn = 0.4
        backdrop.configure(appearance)
        let first = TitleHost(title: "Loading", inset: 16)
        let second = TitleHost(title: "Completed", inset: 16)
        let headers = [TorrentStickyHeaders.Header(id: "loading", title: "Loading", index: 0, inset: 16),
                       TorrentStickyHeaders.Header(id: "finished", title: "Completed", index: 4, inset: 16)]
        func present(_ index: Int, fast: Bool) {
            backdrop.present(layout: .init(titles: [.init(index: index,
                frame: .init(x: 0, y: 20, width: 500, height: 47), pinned: true)], backdropHeight: 115),
                headers: headers, hosts: ["loading": first, "finished": second], suppressFloatingTitles: fast)
        }
        present(0, fast: false)
        try await Task.sleep(for: .milliseconds(40))
        present(0, fast: true)
        try await Task.sleep(for: .milliseconds(30))
        let disappearing = try #require(first.layer?.presentation()?.opacity)
        if !ReduceMotion.enabled { #expect(disappearing > 0 && disappearing < 1) }
        present(1, fast: true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(second.layer?.presentation()?.opacity == 0)
        // Re-enter the previous section while its old fade is still running.
        present(0, fast: true)
        try await Task.sleep(for: .milliseconds(10))
        #expect(first.layer?.presentation()?.opacity == 0)
        present(1, fast: true)
        present(1, fast: false)
        try await Task.sleep(for: .milliseconds(80))
        let returning = try #require(second.layer?.presentation()?.opacity)
        if !ReduceMotion.enabled { #expect(returning > 0 && returning < 1) }
        // Reverse back into a fling while restoration is still in progress.
        present(1, fast: true)
        try await Task.sleep(for: .milliseconds(20))
        let interrupted = try #require(second.layer?.presentation()?.opacity)
        if !ReduceMotion.enabled { #expect(interrupted <= returning + 0.1) }
        try await Task.sleep(for: .milliseconds(160))
        #expect(second.layer?.presentation()?.opacity == 0)
    }

    @Test("flings suppress floating headers and threshold jitter cannot restore them")
    func flingAndHysteresis() {
        var motion = TorrentHeaderScrollMotion()
        motion.begin(offset: 0, at: 0)
        motion.record(offset: 40, at: 0.016, viewportHeight: 400)
        #expect(motion.suppressesFloatingTitles)
        motion.record(offset: 60, at: 0.032, viewportHeight: 400)
        motion.record(offset: 80, at: 0.048, viewportHeight: 400)
        #expect(motion.suppressesFloatingTitles)
        // A reversal is still a fast scroll, not an instruction to flash a title.
        motion.record(offset: 40, at: 0.064, viewportHeight: 400)
        #expect(motion.suppressesFloatingTitles)
        for frame in 1...7 {
            motion.record(offset: 40 + CGFloat(frame), at: 0.064 + Double(frame) * 0.016, viewportHeight: 400)
        }
        #expect(!motion.suppressesFloatingTitles)
    }

    @Test("stopping or a new isolated mouse event clears suppression")
    func stoppedScroll() {
        var motion = TorrentHeaderScrollMotion()
        motion.begin(offset: 0, at: 0)
        motion.record(offset: 40, at: 0.016, viewportHeight: 400)
        #expect(motion.suppressesFloatingTitles)
        #expect(motion.idleDeadline == 0.016 + TorrentHeaderScrollMotion.idleTime)
        motion.end()
        #expect(!motion.suppressesFloatingTitles)
        #expect(motion.idleDeadline == nil)
        motion.record(offset: 50, at: 1, viewportHeight: 400)
        #expect(!motion.suppressesFloatingTitles)
    }

    @MainActor @Test("fast-scroll suppression leaves inline labels and the native bar surface visible")
    func onlyFloatingTitles() {
        let backdrop = HeaderBackdrop(frame: .init(x: 0, y: 0, width: 500, height: 400))
        backdrop.externallyHosted = true
        let floating = TitleHost(title: "Loading", inset: 16)
        let inline = TitleHost(title: "Completed", inset: 16)
        let headers = [TorrentStickyHeaders.Header(id: "loading", title: "Loading", index: 0, inset: 16),
                       TorrentStickyHeaders.Header(id: "finished", title: "Completed", index: 4, inset: 16)]
        let layout = TorrentStickyHeaderGeometry.Layout(titles: [
            .init(index: 0, frame: .init(x: 0, y: 20, width: 500, height: 47), pinned: true),
            .init(index: 1, frame: .init(x: 0, y: 200, width: 500, height: 47))
        ], backdropHeight: 115)
        backdrop.present(layout: layout, headers: headers, hosts: ["loading": floating, "finished": inline],
                         suppressFloatingTitles: true)
        #expect(floating.isScrollSuppressed)
        #expect(!inline.isScrollSuppressed)
        #expect(inline.alphaValue == 1)
        #expect(!backdrop.pinnedSurface.isHidden)
        #expect(backdrop.pinnedSurface.alphaValue == 1)
        #expect(backdrop.backdropIsActive)
        backdrop.present(layout: layout, headers: headers, hosts: ["loading": floating, "finished": inline])
        #expect(!floating.isScrollSuppressed)
        #expect(floating.frame.minY == 20)
    }
}
