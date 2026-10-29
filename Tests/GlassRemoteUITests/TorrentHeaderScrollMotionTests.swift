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
