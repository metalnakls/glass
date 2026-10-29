import Foundation

/// Presentation only: native List continues to own scrolling and row geometry.
struct TorrentHeaderScrollMotion {
    // Viewports/second keeps the gesture comparable in small and large windows.
    // Once fast, remain suppressed through the gesture instead of toggling as
    // each finger stroke accelerates and slows down.
    static let hideSpeed: CGFloat = 2.5
    static let idleTime: TimeInterval = 0.16
    // Seconds: a short native opacity transition clears an already visible
    // title without a cut. Restoration keeps its separate saved Tune duration.
    static let suppressionFadeDuration: TimeInterval = 0.12
    private var sample: (offset: CGFloat, time: TimeInterval)?
    private var lastEventTime: TimeInterval?
    private var isTracking = false
    private(set) var suppressesFloatingTitles = false
    var idleDeadline: TimeInterval? {
        isTracking ? nil : lastEventTime.map { $0 + Self.idleTime }
    }

    mutating func begin(offset: CGFloat, at time: TimeInterval) {
        sample = (offset, time)
        lastEventTime = time
        isTracking = true
    }

    mutating func finishTracking() { isTracking = false }

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
        if speed >= Self.hideSpeed {
            suppressesFloatingTitles = true
        }
    }

    mutating func end() {
        sample = nil
        lastEventTime = nil
        isTracking = false
        suppressesFloatingTitles = false
    }
}
