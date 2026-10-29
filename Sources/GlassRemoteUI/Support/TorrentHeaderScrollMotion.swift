import Foundation

/// Presentation only: native List continues to own scrolling and row geometry.
struct TorrentHeaderScrollMotion {
    // Viewports/second keeps the gesture comparable in small and large windows.
    // Separate thresholds plus a short settling interval avoid threshold flicker.
    static let hideSpeed: CGFloat = 2.5
    static let showSpeed: CGFloat = 0.8
    static let settlingTime: TimeInterval = 0.08
    static let idleTime: TimeInterval = 0.16
    // Seconds: a short native opacity transition clears an already visible
    // title without a cut. Restoration keeps its separate saved Tune duration.
    static let suppressionFadeDuration: TimeInterval = 0.12
    private var sample: (offset: CGFloat, time: TimeInterval)?
    private var lastEventTime: TimeInterval?
    private var slowSince: TimeInterval?
    private(set) var suppressesFloatingTitles = false
    var idleDeadline: TimeInterval? { lastEventTime.map { $0 + Self.idleTime } }

    mutating func begin(offset: CGFloat, at time: TimeInterval) {
        sample = (offset, time)
        lastEventTime = time
        slowSince = nil
    }

    mutating func record(offset: CGFloat, at time: TimeInterval, viewportHeight: CGFloat) {
        guard let previous = sample else { begin(offset: offset, at: time); return }
        guard time > previous.time else { return }
        let idle = time - (lastEventTime ?? previous.time) >= Self.idleTime
        lastEventTime = time
        guard !idle else {
            sample = (offset, time)
            suppressesFloatingTitles = false
            slowSince = nil
            return
        }
        // Accumulate sub-frame movement instead of rounding every interval up,
        // which underestimated fast gestures with closely spaced notifications.
        let elapsed = time - previous.time
        guard elapsed >= 1.0 / 120 else { return }
        sample = (offset, time)
        let speed = abs(offset - previous.offset) / elapsed / max(1, viewportHeight)
        if speed >= Self.hideSpeed {
            suppressesFloatingTitles = true
            slowSince = nil
        } else if speed <= Self.showSpeed {
            if slowSince == nil { slowSince = time }
            if time - (slowSince ?? time) >= Self.settlingTime {
                suppressesFloatingTitles = false
            }
        } else { slowSince = nil }
    }

    mutating func end() {
        sample = nil
        lastEventTime = nil
        slowSince = nil
        suppressesFloatingTitles = false
    }
}
