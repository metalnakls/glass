import Foundation

/// Presentation only: native List continues to own scrolling and row geometry.
struct TorrentHeaderScrollMotion {
    // Viewports/second keeps the gesture comparable in small and large windows.
    // Visibility changes continuously between these speeds; there is no latched
    // hidden state or threshold-triggered restoration during a gesture.
    static let showSpeed: CGFloat = 0.8
    static let hideSpeed: CGFloat = 2.5
    static let idleTime: TimeInterval = 0.16
    // Seconds: filter a few display frames of velocity to reject event jitter,
    // while allowing a slow stroke to restore its title within the same gesture.
    static let speedResponseTime: TimeInterval = 0.06
    // Seconds: a short native opacity transition clears an already visible
    // title without a cut. Restoration keeps its separate saved Tune duration.
    static let suppressionFadeDuration: TimeInterval = 0.12
    private var sample: (offset: CGFloat, time: TimeInterval)?
    private var lastEventTime: TimeInterval?
    private var filteredSpeed: CGFloat = 0
    var floatingTitleVisibility: CGFloat {
        let progress = min(1, max(0, (filteredSpeed - Self.showSpeed) / (Self.hideSpeed - Self.showSpeed)))
        return 1 - progress * progress * (3 - 2 * progress)
    }
    var idleDeadline: TimeInterval? { lastEventTime.map { $0 + Self.idleTime } }

    mutating func begin(offset: CGFloat, at time: TimeInterval) {
        sample = (offset, time)
        lastEventTime = time
    }

    mutating func record(offset: CGFloat, at time: TimeInterval, viewportHeight: CGFloat) {
        guard let previous = sample else {
            // Legacy wheels have no begin/end pair and settle by inactivity.
            sample = (offset, time)
            lastEventTime = time
            return
        }
        guard time > previous.time else { return }
        lastEventTime = time
        // Accumulate sub-frame movement instead of rounding every interval up,
        // which underestimated fast gestures with closely spaced notifications.
        let elapsed = time - previous.time
        guard elapsed >= 1.0 / 120 else { return }
        sample = (offset, time)
        let speed = abs(offset - previous.offset) / elapsed / max(1, viewportHeight)
        let response = 1 - exp(-elapsed / Self.speedResponseTime)
        filteredSpeed += (speed - filteredSpeed) * response
    }

    mutating func end() {
        sample = nil
        lastEventTime = nil
        filteredSpeed = 0
    }
}
