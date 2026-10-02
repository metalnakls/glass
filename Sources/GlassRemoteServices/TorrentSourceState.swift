import Foundation
import GlassRemoteCore
import Observation

/// Live state belongs to its provider, independently of window selection.
@MainActor
@Observable
public final class TorrentSourceState: Identifiable {
    public let id: UUID
    public internal(set) var records: [TorrentRecord] = []
    public internal(set) var structureRevision = 0
    public internal(set) var stats: SessionStats?
    public internal(set) var isLoading = false
    public internal(set) var isShowingCachedTorrents = false
    public internal(set) var isSessionStale = false
    public internal(set) var refreshErrorMessage: String?
    internal var hasRefreshed = false

    init(id: UUID) {
        self.id = id
    }
}
