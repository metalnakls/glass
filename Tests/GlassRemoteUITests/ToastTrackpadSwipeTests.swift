import Testing
@testable import GlassRemoteUI

@Suite("Toast trackpad swipe")
struct ToastTrackpadSwipeTests {
    @Test("horizontal trackpad swipe dismisses in either direction")
    func bothDirections() {
        for direction in [-1.0, 1.0] {
            var motion = ToastSwipeMotion()
            let captured1 = motion.update(x: 30 * direction, y: 1, timestamp: 1, ended: false)
            #expect(captured1)
            let captured2 = motion.update(x: 30 * direction, y: 1, timestamp: 1.02, ended: false)
            #expect(captured2)
            let captured3 = motion.update(x: 0, y: 0, timestamp: 1.03, ended: true)
            #expect(captured3)
            #expect(motion.shouldDismiss)
        }
    }

    @Test("vertical scrolling is never captured by the toast")
    func verticalScrolling() {
        var motion = ToastSwipeMotion()
        let captured4 = motion.update(x: 1, y: 12, timestamp: 1, ended: false)
            #expect(!captured4)
        let captured5 = motion.update(x: 30, y: 1, timestamp: 1.02, ended: false)
            #expect(!captured5)
        let captured6 = motion.update(x: 0, y: 0, timestamp: 1.03, ended: true)
            #expect(!captured6)
    }

    @Test("short swipe returns to rest and a paused flick does not dismiss")
    func shortSwipe() {
        var motion = ToastSwipeMotion()
        _ = motion.update(x: 5, y: 0, timestamp: 1, ended: false)
        _ = motion.update(x: 15, y: 0, timestamp: 1.01, ended: false)
        _ = motion.update(x: 0, y: 0, timestamp: 1.3, ended: true)
        #expect(!motion.shouldDismiss)
    }

    @Test("quick flick uses the predicted travel")
    func flick() {
        var motion = ToastSwipeMotion()
        _ = motion.update(x: 5, y: 0, timestamp: 1, ended: false)
        _ = motion.update(x: 15, y: 0, timestamp: 1.01, ended: false)
        _ = motion.update(x: 0, y: 0, timestamp: 1.02, ended: true)
        #expect(motion.shouldDismiss)
    }
}
