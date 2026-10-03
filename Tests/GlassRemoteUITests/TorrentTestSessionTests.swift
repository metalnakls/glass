import GlassRemoteCore
import Testing
@testable import GlassRemoteUI

@Suite("Disposable sample torrents")
struct TorrentTestSessionTests {
    @Test("sample mutations cannot affect another library")
    func isolatedMutations() async throws {
        let first = TorrentTestSession()
        let second = TorrentTestSession()
        let original = try await first.fetchSnapshot()
        #expect(original.torrents.count == 11)
        #expect(original.torrents.contains { $0.hasStorageError && $0.isCompleted })
        try await first.stop(ids: ["glass-sample-4"])
        try await first.remove(ids: ["glass-sample-6"], deleteLocalData: true)
        let changed = try await first.fetchSnapshot()
        #expect(changed.torrents.first { $0.hashString == "glass-sample-4" }?.status == 0)
        #expect(changed.torrents.count == 10)
        #expect(try await second.fetchSnapshot().torrents == original.torrents)
    }

    @Test("sample file selection and completion retain the nested tree")
    func fileTreeAndCompletion() async throws {
        let session = TorrentTestSession()
        try await session.setFileWanted(ids: ["glass-sample-9"], fileIndices: [2], wanted: false)
        try await session.setFilePriority(ids: ["glass-sample-9"], fileIndices: [0], priority: 1)
        let details = try await session.fetchTorrentDetails(hashString: "glass-sample-9")
        #expect(details.files.contains { $0.name == "Archive/Notes/Production.txt" })
        #expect(details.fileStats[2].wanted == false)
        #expect(details.fileStats[0].priority == 1)
        await session.completeAll()
        #expect(try await session.fetchSnapshot().torrents.allSatisfy(\.isCompleted))
    }
}
