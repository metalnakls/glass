/// A repeated swipe removes that priority; the opposite swipe selects its priority directly.
enum TorrentFilePriority {
    static func swiping(current: Int, high: Bool) -> Int {
        let requested = high ? 1 : -1
        return current == requested ? 0 : requested
    }
}
