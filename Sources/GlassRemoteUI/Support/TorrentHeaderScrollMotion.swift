import Foundation

/// Presentation only: native List continues to own scrolling and row geometry.
struct TorrentHeaderScrollMotion {
    // Viewports/second keeps the gesture comparable in small and large windows.
    // Separate thresholds plus a short settling interval avoid threshold flicker.
    static let hideSpeed: CGFloat = 2.5
    static let showSpeed: CGFloat = 0.8
    static let settlingTime: TimeInterval = 0.08
    static let idleTime: TimeInterval = 0.16
    private var sample: (offset: CGFloat, time: TimeInterval)?
    private var slowSince: TimeInterval?
    private(set) var suppressesFloatingTitles = false
    var idleDeadline: TimeInterval? { sample.map { $0.time + Self.idleTime } }

    mutating func begin(offset: CGFloat, at time: TimeInterval) {
        sample = (offset, time)
        slowSince = nil
    }

    mutating func record(offset: CGFloat, at time: TimeInterval, viewportHeight: CGFloat) {
        defer { sample = (offset, time) }
        guard let previous = sample, time > previous.time else { return }
        guard time - previous.time < Self.idleTime else {
            suppressesFloatingTitles = false
            slowSince = nil
            return
        }
        // Coalesced notifications in one frame must not turn a tiny movement
        // into an enormous speed. Sample no faster than a 120 Hz display.
        let elapsed = max(time - previous.time, 1.0 / 120)
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
        slowSince = nil
        suppressesFloatingTitles = false
    }
}
