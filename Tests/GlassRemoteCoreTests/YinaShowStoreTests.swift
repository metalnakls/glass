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

    @Test("migrates v1 root inventory into the single hidden folder without changing its bytes")
    func legacyCompatibility() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try makeIndex()
        let original = root.appendingPathComponent(".yina.json")
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: original)
        let store = YinaShowStore(rootURL: root)

        let descriptor = try #require(await store.readDescriptor())
        #expect(descriptor.showID == YinaShowStore.deterministicShowID(for: legacy.hashString))
        #expect(descriptor.createdAt == legacy.capturedAt)
        #expect(try await store.readLegacyIndex() == legacy)
        #expect(try Data(contentsOf: root.appendingPathComponent(".yina/legacy-index.json")) == data)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".yina/show.json").path))
        #expect(try await store.createDescriptorIfAbsent(transferHash: "cafebabe") == descriptor)
    }

    @Test("moves a v2 root descriptor byte-for-byte while preserving its identity")
    func descriptorMigration() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let original = root.appendingPathComponent(".yina.json")
        let data = Data("{\"schemaVersion\":2,\"showID\":\"\(id.uuidString)\",\"createdAt\":\"1970-01-01T00:01:40.000Z\"}".utf8)
        try data.write(to: original)
        let store = YinaShowStore(rootURL: root)
        let descriptor = try #require(await store.readDescriptor())
        #expect(descriptor.showID == id)
        #expect(descriptor.createdAt == date(100))
        #expect(try Data(contentsOf: root.appendingPathComponent(".yina/show.json")) == data)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try await store.readLegacyIndex() == nil)
    }

    @Test("recovers a migrated v1 index when the identity publication was interrupted")
    func orphanLegacyIndex() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(".yina", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = try makeIndex()
        let data = try JSONEncoder().encode(index)
        try data.write(to: directory.appendingPathComponent("legacy-index.json"))
        let store = YinaShowStore(rootURL: root)
        let descriptor = try #require(await store.readDescriptor())
        #expect(descriptor.showID == YinaShowStore.deterministicShowID(for: index.hashString))
        #expect(try Data(contentsOf: directory.appendingPathComponent("legacy-index.json")) == data)
    }

    @Test("preserves root data on conflicting, extended, and symbolic-link migrations")
    func migrationRefusesUnsafeData() async throws {
        let index = try makeIndex()
        let data = try JSONEncoder().encode(index)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent(".yina.json")
        try data.write(to: original)
        let hidden = root.appendingPathComponent(".yina", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let foreign = Data("{\"schemaVersion\":2,\"showID\":\"\(UUID().uuidString)\",\"createdAt\":\"1970-01-01T00:01:40.000Z\"}".utf8)
        try foreign.write(to: hidden.appendingPathComponent("show.json"))
        let store = YinaShowStore(rootURL: root)
        do { _ = try await store.readDescriptor(); Issue.record("conflicting descriptor migrated") }
        catch { #expect(error as? YinaShowStore.Error == .identityMismatch) }
        #expect(try Data(contentsOf: original) == data)

        let extendedRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: extendedRoot) }
        let extended = Data(String(decoding: data, as: UTF8.self).dropLast().appending(",\"future\":true}").utf8)
        let extendedURL = extendedRoot.appendingPathComponent(".yina.json")
        try extended.write(to: extendedURL)
        do { _ = try await YinaShowStore(rootURL: extendedRoot).readDescriptor(); Issue.record("unknown field migrated") }
        catch { #expect(error as? YinaShowStore.Error == .unsafeExistingPath) }
        #expect(try Data(contentsOf: extendedURL) == extended)

        let linkedRoot = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: linkedRoot); try? FileManager.default.removeItem(at: outside) }
        let linkedOriginal = linkedRoot.appendingPathComponent(".yina.json")
        try data.write(to: linkedOriginal)
        try FileManager.default.createSymbolicLink(at: linkedRoot.appendingPathComponent(".yina"), withDestinationURL: outside)
        do { _ = try await YinaShowStore(rootURL: linkedRoot).readDescriptor(); Issue.record("symlink directory migrated") }
        catch { #expect(error as? YinaShowStore.Error == .unsafeExistingPath) }
        #expect(try Data(contentsOf: linkedOriginal) == data)
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

    @Test("validates interrupted migration markers and keeps recent writers' markers")
    func migrationQuarantineRecovery() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try makeIndex()
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: root.appendingPathComponent(".yina.json"))
        let store = YinaShowStore(rootURL: root)
        _ = try await store.readDescriptor()
        let marker = root.appendingPathComponent(".yina/.legacy-root-\(UUID().uuidString).pending")
        try data.write(to: marker)
        _ = try await store.readDescriptor()
        #expect(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31)],
                                              ofItemAtPath: marker.path)
        _ = try await store.readDescriptor()
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        let conflicting = root.appendingPathComponent(".yina/.legacy-root-\(UUID().uuidString).pending")
        let unknown = Data(String(decoding: data, as: UTF8.self).dropLast().appending(",\"future\":true}").utf8)
        try unknown.write(to: conflicting)
        do { _ = try await store.readDescriptor(); Issue.record("unknown quarantine was discarded") }
        catch { #expect(error as? YinaShowStore.Error == .unsafeExistingPath) }
        #expect(try Data(contentsOf: conflicting) == unknown)
    }

    @Test("concurrent Glass migrators converge on the same v1 identity")
    func concurrentLegacyMigration() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try makeIndex()
        try JSONEncoder().encode(legacy).write(to: root.appendingPathComponent(".yina.json"))
        let first = YinaShowStore(rootURL: root), second = YinaShowStore(rootURL: root)
        async let left = first.readDescriptor()
        async let right = second.readDescriptor()
        let (a, b) = try await (left, right)
        #expect(a == b)
        #expect(a?.showID == YinaShowStore.deterministicShowID(for: legacy.hashString))
    }

    @Test("persists accepted and failed request revisions across independent receipt writers")
    func demandReceipts() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YinaShowStore(rootURL: root)
        let descriptor = try await store.createDescriptorIfAbsent()
        let request = UUID(), requester = UUID(), writerA = UUID(), writerB = UUID()
        let accepted = try YinaDemandReceipt(
            showID: descriptor.showID, requestID: request, requestWriterID: requester,
            receiptWriterID: writerA, revision: 1, requestRevision: 1,
            updatedAt: date(100), outcome: .accepted
        )
        let failed = try YinaDemandReceipt(
            showID: descriptor.showID, requestID: request, requestWriterID: requester,
            receiptWriterID: writerB, revision: 1, requestRevision: 1,
            updatedAt: date(101), outcome: .failed, reason: .priorityFailed
        )
        try await store.publishReceipt(accepted)
        try await store.publishReceipt(accepted)
        try await store.publishReceipt(failed)
        let records = try await store.readReceipts(showID: descriptor.showID, requestID: request)
        #expect(Set(records) == Set([accepted, failed]))
        do { _ = try await store.readReceipts(showID: UUID(), requestID: request)
             Issue.record("foreign show receipt was accepted") }
        catch { #expect(error as? YinaShowStore.Error == .identityMismatch) }
        #expect(try await store.readReceipts(showID: descriptor.showID, requestID: request).count == 2)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            ".yina/receipts/\(writerA.uuidString.lowercased())/\(request.uuidString.lowercased()).json"
        ).path))

        // An explicit newer demand revision can supersede a failed outcome without changing request identity.
        let retry = try YinaDemandReceipt(
            showID: descriptor.showID, requestID: request, requestWriterID: requester,
            receiptWriterID: writerB, revision: 2, requestRevision: 2,
            updatedAt: date(103), outcome: .accepted
        )
        try await store.publishReceipt(retry)
        #expect(Set(try await store.readReceipts(showID: descriptor.showID, requestID: request)) ==
                Set([accepted, retry]))
        let future = try YinaDemandReceipt(
            showID: descriptor.showID, requestID: request, requestWriterID: requester,
            receiptWriterID: UUID(), revision: 1, requestRevision: 2,
            updatedAt: Date().addingTimeInterval(60), outcome: .accepted
        )
        try await store.publishReceipt(future)
        #expect(try await store.readReceipts(showID: descriptor.showID, requestID: request).contains {
            $0.receiptWriterID == future.receiptWriterID && $0.requestRevision == 2 && $0.outcome == .accepted
        })
        do { try await store.publishReceipt(failed); Issue.record("old receipt overwrote newer retry") }
        catch { #expect(error as? YinaShowStore.Error == .receiptRevisionNotIncreasing) }
    }

    @Test("rejects invalid receipt reasons and unsafe existing receipt paths")
    func receiptValidation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YinaShowStore(rootURL: root)
        let descriptor = try await store.createDescriptorIfAbsent()
        let request = UUID(), requester = UUID(), writer = UUID()
        #expect(throws: YinaShowStore.Error.invalidReceipt) {
            try YinaDemandReceipt(showID: descriptor.showID, requestID: request,
                                  requestWriterID: requester, receiptWriterID: writer,
                                  revision: 1, requestRevision: 1, outcome: .failed)
        }
        #expect(throws: YinaShowStore.Error.invalidReceipt) {
            try YinaDemandReceipt(showID: descriptor.showID, requestID: request,
                                  requestWriterID: requester, receiptWriterID: writer,
                                  revision: 1, requestRevision: 1, outcome: .accepted,
                                  reason: .selectionFailed)
        }
        let directory = root.appendingPathComponent(".yina/receipts/\(writer.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.json")
        try Data("foreign".utf8).write(to: outside)
        let target = directory.appendingPathComponent("\(request.uuidString.lowercased()).json")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        let receipt = try YinaDemandReceipt(showID: descriptor.showID, requestID: request,
                                            requestWriterID: requester, receiptWriterID: writer,
                                            revision: 1, requestRevision: 1, outcome: .accepted)
        do { try await store.publishReceipt(receipt); Issue.record("symlink receipt overwritten") }
        catch { #expect(error as? YinaShowStore.Error == .unsafeExistingPath) }
        #expect(try Data(contentsOf: outside) == Data("foreign".utf8))
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
