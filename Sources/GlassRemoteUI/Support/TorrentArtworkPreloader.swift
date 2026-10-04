import AppKit

/// Warm a small viewport buffer through the thumbnail service's existing serial work lane.
@MainActor final class TorrentArtworkPreloader: NSObject {
    private weak var table: NSTableView?
    private var inputs: [TorrentThumbnailInput?] = []
    private var requested: [TorrentThumbnailInput] = []
    private var task: Task<Void, Never>?

    func setInputs(_ inputs: [TorrentThumbnailInput?]) {
        guard self.inputs != inputs else { return }
        self.inputs = inputs
        task?.cancel(); task = nil
        requested = []
        updateViewport()
    }

    func attach(_ table: NSTableView) {
        guard self.table !== table else { updateViewport(); return }
        detach()
        self.table = table
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateViewport),
            name: NSView.frameDidChangeNotification, object: table)
        if let clip = table.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(updateViewport),
                name: NSView.frameDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(updateViewport),
                name: NSView.boundsDidChangeNotification, object: clip)
        }
        updateViewport()
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        task?.cancel(); task = nil
        table = nil
        requested = []
    }

    @objc private func updateViewport() {
        guard let table, table.numberOfRows == inputs.count else { return }
        let visible = table.rows(in: table.visibleRect)
        request(visible: visible)
    }

    func prefetchAround(_ row: Int) { request(visible: NSRange(location: row, length: 1)) }

    static func indices(visible: NSRange, count: Int, buffer: Int = 6) -> [Int] {
        guard visible.location != NSNotFound, visible.length > 0, visible.location < count else { return [] }
        let end = min(count, visible.location + visible.length)
        let visibleRows = Array(visible.location..<end)
        let before = stride(from: visible.location - 1, through: max(0, visible.location - buffer), by: -1)
        let after = end..<min(count, end + buffer)
        // Visible rows first, then interleave equally near rows above and below.
        var result = visibleRows
        let above = Array(before), below = Array(after)
        for distance in 0..<max(above.count, below.count) {
            if distance < below.count { result.append(below[distance]) }
            if distance < above.count { result.append(above[distance]) }
        }
        return result
    }

    private func request(visible: NSRange) {
        let targets = Self.indices(visible: visible, count: inputs.count).compactMap { inputs[$0] }
        guard targets != requested else { return }
        requested = targets
        task?.cancel()
        task = Task { @MainActor in
            for input in targets {
                guard !Task.isCancelled else { return }
                _ = await TorrentThumbnailService.shared.image(for: input)
            }
        }
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        task?.cancel()
    }
}
