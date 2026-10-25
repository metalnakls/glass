import Foundation
@testable import GlassRemoteCore
import Testing

@Suite("YINA shared show store")
struct YinaShowStoreTests {
    @Test("creates a random descriptor once and keeps it across transfer sources")
    func descriptorIdentity() async throws {
        let root = try temporaryDirectory()
        let otherRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let store = YinaShowStore(rootURL: root)
        let first = try await store.createDescriptorIfAbsent(transferHash: "AB12CD34", createdAt: date(100))
        let second = try await store.createDescriptorIfAbsent(transferHash: "ef56ab78", createdAt: date(200))
        let independent = try await YinaShowStore(rootURL: otherRoot).createDescriptorIfAbsent(transferHash: "AB12CD34", createdAt: date(100))
        #expect(first.showID == second.showID)
        #expect(first.showID != independent.showID)
        #expect(first.createdAt == date(100))
        #expect(try await store.readDescriptor() == first)
        #expect(first.showID != YinaShowStore.deterministicShowID(for: " AB12CD34\n"))
    }

    @Test("concurrent creators keep the exclusive winner's descriptor")
    func concurrentDescriptorCreation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = YinaShowStore(rootURL: root)
        let secondStore = YinaShowStore(rootURL: root)
        async let first = firstStore.createDescriptorIfAbsent(createdAt: date(100))
        async let second = secondStore.createDescriptorIfAbsent(createdAt: date(200))
        let (firstResult, secondResult) = try await (first, second)
        #expect(firstResult == secondResult)
        #expect(try await firstStore.readDescriptor() == firstResult)
    }

    @Test("reads v1 root index as a descriptor adapter without changing its bytes")
    func legacyCompatibility() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try makeIndex()
        let url = root.appendingPathComponent(".yina.json")
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: url)
        let store = YinaShowStore(rootURL: root)

        let descriptor = try #require(await store.readDescriptor())
        #expect(descriptor.showID == YinaShowStore.deterministicShowID(for: legacy.hashString))
        #expect(descriptor.createdAt == legacy.capturedAt)
        #expect(try await store.readLegacyIndex() == legacy)
        #expect(try Data(contentsOf: url) == data)
        #expect(try await store.createDescriptorIfAbsent(transferHash: "cafebabe") == descriptor)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("isolates transfer snapshots by run writer and filters stale or foreign snapshots")
    func transferSnapshots() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YinaShowStore(rootURL: root)
        let descriptor = try await store.createDescriptorIfAbsent(transferHash: "ab12cd34", createdAt: date(100))
        let writerA = UUID(), writerB = UUID()
        let current = try makeIndex(hash: "ab12cd34", capturedAt: date(1_000))
        let stale = try makeIndex(hash: "ef56ab78", capturedAt: date(1_000 - ShowEpisodeIndex.freshnessLimit - 1))
        try await store.publishTransferSnapshot(current, showID: descriptor.showID, writerID: writerA)
        try await store.publishTransferSnapshot(stale, showID: descriptor.showID, writerID: writerB)

        let snapshots = try await store.readTransferSnapshots(showID: descriptor.showID, at: date(1_000))
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.writerID == writerA)
        #expect(snapshots.first?.index == current)
        do {
            try await store.publishTransferSnapshot(current, showID: UUID(), writerID: writerA)
            Issue.record("A foreign show ID was accepted")
        } catch { #expect(error as? YinaShowStore.Error == .identityMismatch) }
    }

    @Test("caps aggregate bytes read across transfer writers")
    func aggregateTransferReadBudget() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writerA = UUID(), writerB = UUID()
        let publisher = YinaShowStore(rootURL: root)
        let descriptor = try await publisher.createDescriptorIfAbsent(createdAt: date(100))
        try await publisher.publishTransferSnapshot(makeIndex(hash: "ab12cd34"), showID: descriptor.showID, writerID: writerA)
        try await publisher.publishTransferSnapshot(makeIndex(hash: "ef56ab78"), showID: descriptor.showID, writerID: writerB)
        let snapshotA = root.appendingPathComponent(".yina/transfers/\(writerA.uuidString.lowercased())/ab12cd34.json")
        let snapshotB = root.appendingPathComponent(".yina/transfers/\(writerB.uuidString.lowercased())/ef56ab78.json")
        let sizeA = (try FileManager.default.attributesOfItem(atPath: snapshotA.path)[.size] as? NSNumber)?.intValue ?? 0
        let sizeB = (try FileManager.default.attributesOfItem(atPath: snapshotB.path)[.size] as? NSNumber)?.intValue ?? 0
        let limitedReader = YinaShowStore(rootURL: root, aggregateReadByteLimit: max(sizeA, sizeB) + 1)
        do {
            _ = try await limitedReader.readTransferSnapshots(showID: descriptor.showID, at: date(1_000))
            Issue.record("The aggregate transfer read budget was exceeded")
        } catch { #expect(error as? YinaShowStore.Error == .aggregateReadLimitExceeded) }
    }

    @Test("keeps progress per participant and writer and rejects invalid coverage")
    func independentProgress() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YinaShowStore(rootURL: root)
        let descriptor = try await store.createDescriptorIfAbsent(transferHash: "ab12cd34", createdAt: date(100))
        let participant = UUID(), writerA = UUID(), writerB = UUID()
        let interval = try YinaCoverageInterval(start: 4, end: 9)
        let a = try YinaProgressSnapshot(showID: descriptor.showID, participantID: participant, writerID: writerA,
                                         revision: 3, updatedAt: date(200), relativePath: "Season 1/E01.mkv",
                                         position: 10, duration: 20, activity: .paused, coverage: [interval])
        let b = try YinaProgressSnapshot(showID: descriptor.showID, participantID: participant, writerID: writerB,
                                         revision: 1, updatedAt: date(201), relativePath: "Season 1/E02.mkv",
                                         position: 2, duration: 30, activity: .playing)
        try await store.publishProgress(a)
        try await store.publishProgress(b)
        let result = try await store.readProgress(showID: descriptor.showID, at: date(300))
        #expect(Set(result.map(\.writerID)) == [writerA, writerB])
        #expect(result.contains(a) && result.contains(b))
        do {
            try await store.publishProgress(a)
            Issue.record("A duplicate writer revision was accepted")
        } catch { #expect(error as? YinaShowStore.Error == .progressRevisionNotIncreasing) }
        let progressFile = root.appendingPathComponent(".yina/progress/\(participant.uuidString.lowercased())/\(writerA.uuidString.lowercased()).json")
        var legacyObject = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: progressFile)) as? [String: Any])
        legacyObject.removeValue(forKey: "coverage")
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: progressFile)
        let adapted = try await store.readProgress(showID: descriptor.showID, at: date(300))
        #expect(adapted.first(where: { $0.writerID == writerA })?.coverage.isEmpty == true)
        #expect(throws: YinaShowStore.Error.invalidProgress) {
            try YinaProgressSnapshot(showID: descriptor.showID, participantID: participant, writerID: writerA,
                                     revision: 4, relativePath: "../outside.mkv", position: 1, duration: 20, activity: .playing)
        }
        #expect(throws: YinaShowStore.Error.invalidProgress) { try YinaCoverageInterval(start: 5, end: 5) }
    }

    @Test("publishes per-writer download demand with idempotent revisions and freshness filtering")
    func downloadDemand() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YinaShowStore(rootURL: root)
        let descriptor = try await store.createDescriptorIfAbsent(createdAt: date(100))
        let participant = UUID(), writer = UUID(), request = UUID()
        let demand = try YinaDownloadDemand(showID: descriptor.showID, requestID: request,
                                            participantID: participant, writerID: writer,
                                            revision: 1, updatedAt: date(1_000), relativePath: "Season 1/E01.mkv",
                                            hashString: "AB12CD34", fileIndex: 7)
        try await store.publishDemand(demand)
        try await store.publishDemand(demand)
        #expect(try await store.readDemand(showID: descriptor.showID, at: date(1_001)) == [demand])
        #expect(try await store.readDemand(showID: descriptor.showID, at: date(1_000 + YinaShowStore.demandFreshnessLimit + 1)).isEmpty)
        #expect(try await store.readDemand(showID: descriptor.showID, at: date(999)).isEmpty)

        let canceled = try YinaDownloadDemand(showID: descriptor.showID, requestID: request,
                                              participantID: participant, writerID: writer,
                                              revision: 2, updatedAt: date(1_002), relativePath: "Season 1/E01.mkv",
                                              hashString: "ab12cd34", fileIndex: 7, cancelled: true)
        try await store.publishDemand(canceled)
        #expect(try await store.readDemand(showID: descriptor.showID, at: date(1_003)) == [canceled])
        do {
            try await store.publishDemand(demand)
            Issue.record("An older demand revision was accepted")
        } catch { #expect(error as? YinaShowStore.Error == .demandRevisionNotIncreasing) }
        #expect(throws: YinaShowStore.Error.invalidDemand) {
            try YinaDownloadDemand(showID: descriptor.showID, requestID: request,
                                   participantID: participant, writerID: writer, revision: 3,
                                   relativePath: "Season 1/E01.mkv", hashString: "ab12cd34")
        }
    }

    @Test("does not follow a symlinked protocol directory")
    func rejectsSymlinkedWriterDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YinaShowStore(rootURL: root)
        let descriptor = try await store.createDescriptorIfAbsent(transferHash: "ab12cd34", createdAt: date(100))
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let protocolRoot = root.appendingPathComponent(".yina", isDirectory: true)
        try FileManager.default.createDirectory(at: protocolRoot, withIntermediateDirectories: true)
        let transfers = protocolRoot.appendingPathComponent("transfers", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: transfers, withDestinationURL: outside)
        do {
            try await store.publishTransferSnapshot(makeIndex(), showID: descriptor.showID, writerID: UUID())
            Issue.record("A symlinked protocol directory was accepted")
        } catch { #expect(error as? YinaShowStore.Error == .unsafeExistingPath) }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func makeIndex(hash: String = "ab12cd34", capturedAt: Date = Date(timeIntervalSince1970: 1_000)) throws -> ShowEpisodeIndex {
        let file = TorrentFile(name: "Series/Season 1/S01E01.mkv", length: 100, bytesCompleted: 50)
        let stats = TorrentFileStats(bytesCompleted: 50, wanted: true, priority: 0)
        let details = TorrentDetails(id: 1, hashString: hash, name: "Series", percentDone: 0.5,
                                     files: [file], fileStats: [stats])
        return try ShowEpisodeIndex(details: details, relativePathPrefix: "Series", capturedAt: capturedAt)
    }
}
