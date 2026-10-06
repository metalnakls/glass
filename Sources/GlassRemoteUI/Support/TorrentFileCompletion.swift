import GlassRemoteCore

/// One completion rule for checkbox presentation, selection and bulk edit filtering.
enum TorrentFileCompletion {
    static func isComplete(_ details: TorrentDetails, index: Int) -> Bool {
        guard details.files.indices.contains(index) else { return false }
        let file = details.files[index]
        let completed = details.fileStats.indices.contains(index) ? details.fileStats[index].bytesCompleted ?? file.bytesCompleted : file.bytesCompleted
        return completed >= file.length
    }
}
