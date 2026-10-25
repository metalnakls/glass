import Foundation
import Testing
@testable import GlassRemoteCore

@Suite("Show episode availability index")
struct ShowEpisodeIndexTests {
    private let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("round trips a season folder and preserves transfer identities")
    func roundTrip() throws {
        let index = try makeIndex(files: [
            ("Series/Season 02/Series.S02E03.720p.mkv", 100, 100, true),
            ("Series/Season 02/Series.S02E04.720p.mkv", 20, 100, true)
        ], prefix: "Series")

        let data = try JSONEncoder().encode(index)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["hashString"] as? String == "ab12cd34")
        #expect(object["capturedAt"] is String)
        let decoded = try JSONDecoder().decode(ShowEpisodeIndex.self, from: data)
        #expect(decoded == index)
        #expect(decoded.schemaVersion == ShowEpisodeIndex.currentSchemaVersion)
        #expect(decoded.hashString == "ab12cd34")
        #expect(decoded.episodes.map(\.relativePath) == [
            "Season 02/Series.S02E03.720p.mkv", "Season 02/Series.S02E04.720p.mkv"
        ])
        #expect(decoded.episodes.map(\.id.fileIndex) == [0, 1])
        #expect(decoded.episodes.map(\.availability) == [.complete, .partial])
    }

    @Test("keeps unwanted and incomplete episodes in the index")
    func unwantedEpisodesRetained() throws {
        let index = try makeIndex(files: [
            ("Show/Season 1/Show.S01E01.mkv", 0, 100, false),
            ("Show/Season 1/Show.S01E02.mkv", 0, 100, true),
            ("Show/Season 1/Show.S01E03.mkv", 100, 100, false),
            ("Show/Specials/Behind the Scenes.mkv", 10, 20, true),
            ("Show/Season 1/Show.S01E04-E05.mkv", 5, 10, true)
        ], prefix: "Show")

        #expect(index.episodes.count == 5)
        #expect(index.episodes[0].wanted == false)
        #expect(index.episodes[0].availability == .notSelected)
        #expect(index.episodes[1].availability == .selected)
        #expect(index.episodes[2].availability == .complete)
        #expect(index.episodes[3].season == nil)
        #expect(index.episodes[3].episode == nil)
        #expect(index.episodes[3].availability == .partial)
        #expect(index.episodes[4].season == nil)
        #expect(index.episodes[4].episode == nil)
    }

    @Test("requires an explicit root prefix and rejects traversal")
    func pathSafety() throws {
        let unsafeDetails = details(files: [("../outside/Show.S01E01.mkv", 0, 10, true)])
        #expect(throws: ShowEpisodeIndex.ValidationError.self) {
            try ShowEpisodeIndex(details: unsafeDetails, relativePathPrefix: "")
        }
        #expect(throws: ShowEpisodeIndex.ValidationError.self) {
            try ShowEpisodeIndex(details: details(files: [("Show/Show.S01E01.mkv", 0, 10, true)]), relativePathPrefix: "../Show")
        }
    }

    @Test("rejects unsupported schema and malformed byte totals")
    func decodingValidation() throws {
        let index = try makeIndex(files: [("Show.S01E01.mkv", 5, 10, true)], prefix: "")
        let encoded = try JSONEncoder().encode(index)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = ShowEpisodeIndex.currentSchemaVersion + 1
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ShowEpisodeIndex.ValidationError.self) {
            try JSONDecoder().decode(ShowEpisodeIndex.self, from: unsupported)
        }

        object["schemaVersion"] = ShowEpisodeIndex.currentSchemaVersion
        var episodes = try #require(object["episodes"] as? [[String: Any]])
        episodes[0]["bytesCompleted"] = 11
        object["episodes"] = episodes
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ShowEpisodeIndex.ValidationError.self) {
            try JSONDecoder().decode(ShowEpisodeIndex.self, from: malformed)
        }
    }

    @Test("turns stale snapshots unknown and never treats torrent completion as episode completion")
    func stalenessAndPerFileProgress() throws {
        let index = try makeIndex(
            files: [("Show.S01E01.mkv", 40, 100, true)],
            prefix: "",
            torrentPercentDone: 1
        )
        let episode = try #require(index.episodes.first)
        #expect(index.availability(of: episode, at: capturedAt.addingTimeInterval(ShowEpisodeIndex.freshnessLimit)) == .partial)
        #expect(index.availability(of: episode, at: capturedAt.addingTimeInterval(ShowEpisodeIndex.freshnessLimit + 1)) == .unknown)
        #expect(index.availability(of: episode, at: capturedAt.addingTimeInterval(-1)) == .unknown)
    }

    @Test("rejects mismatched file and file-stat counts")
    func countValidation() throws {
        var value = details(files: [("Show.S01E01.mkv", 0, 10, true)])
        value = TorrentDetails(
            id: value.id, hashString: value.hashString, name: value.name, percentDone: value.percentDone,
            files: value.files, fileStats: []
        )
        #expect(throws: ShowEpisodeIndex.ValidationError.self) {
            try ShowEpisodeIndex(details: value, relativePathPrefix: "")
        }
    }

    @Test("uses the conservative file-byte count when details disagree")
    func conservativeFileProgress() throws {
        let details = TorrentDetails(
            id: 1,
            hashString: "ab12cd34",
            name: "Series",
            files: [TorrentFile(name: "Series.S01E01.mkv", length: 100, bytesCompleted: 90)],
            fileStats: [TorrentFileStats(bytesCompleted: 40, wanted: true, priority: 0)]
        )
        let index = try ShowEpisodeIndex(details: details, relativePathPrefix: "", capturedAt: capturedAt)
        #expect(index.episodes.first?.bytesCompleted == 40)
        #expect(index.episodes.first?.availability == .partial)
    }

    private func makeIndex(
        files: [(String, UInt64, UInt64, Bool)],
        prefix: String,
        torrentPercentDone: Double? = nil
    ) throws -> ShowEpisodeIndex {
        try ShowEpisodeIndex(details: details(files: files, torrentPercentDone: torrentPercentDone),
                             relativePathPrefix: prefix, capturedAt: capturedAt)
    }

    private func details(
        files: [(String, UInt64, UInt64, Bool)],
        torrentPercentDone: Double? = nil
    ) -> TorrentDetails {
        TorrentDetails(
            id: 1,
            hashString: "ab12cd34",
            name: "Series Season 2 Pack",
            percentDone: torrentPercentDone,
            files: files.map { TorrentFile(name: $0.0, length: $0.2, bytesCompleted: $0.1) },
            fileStats: files.map { TorrentFileStats(bytesCompleted: $0.1, wanted: $0.3, priority: 0) }
        )
    }
}
