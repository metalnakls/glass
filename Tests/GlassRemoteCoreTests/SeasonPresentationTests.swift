import Foundation
import Testing
@testable import GlassRemoteCore

@Suite("Presentation-only season naming")
struct SeasonPresentationTests {
    @Test("series matching tolerates articles and release separators without changing titles")
    func seriesIdentity() {
        #expect(TorrentSeriesIdentity.key(for: "THE.Expanse") == TorrentSeriesIdentity.key(for: "Expanse"))
        #expect(TorrentSeriesIdentity.key(for: "The Walking Dead") == TorrentSeriesIdentity.key(for: "Walking Dead"))
        #expect(TorrentSeriesIdentity.key(for: "Thelma") != TorrentSeriesIdentity.key(for: "Lma"))
        #expect(TorrentSeriesIdentity.key(for: "Other Series") != TorrentSeriesIdentity.key(for: "Walking Dead"))
    }

    @Test("actual Santa Clarita release cleans its shared disk root")
    func actualRelease() throws {
        let root = "Santa.Clarita.Diet.s01.WEB-DL.1080p.2xRus.Eng"
        let files = [TorrentFile(name: "Santa.Clarita.Diet.S01E01.So.Then.a.Bat.or.a.Monkey.1080p.2xRus.Eng.mkv", length: 1, bytesCompleted: 0)]
        let plan = try #require(TorrentNameCleaner.plan(rootName: root, files: files, selectedFileIndices: [0]))
        #expect(plan.rootName == "Santa Clarita Diet")
        #expect(plan.displayName == "Santa Clarita Diet")
        #expect(plan.season == TorrentSeasonDescriptor(title: "Santa Clarita Diet", season: 1))
        #expect(plan.withDisplayName("My Series").rootName == "My Series")
    }

    @Test("bilingual titles use the original series name")
    func bilingual() throws {
        let root = "Диета из Санта-Клариты Santa Clarita Diet Сезон 2 Серии 1-10 из 10 (Рубен Флейшер) [2017, США]"
        let plan = try #require(TorrentNameCleaner.plan(rootName: root, files: [], selectedFileIndices: []))
        #expect(plan.rootName == "Santa Clarita Diet")
        #expect(plan.displayName == "Santa Clarita Diet")
        #expect(plan.season?.season == 2)
    }

    @Test("old saved names remain readable and season identity survives restart")
    func persistence() throws {
        let old = try JSONDecoder().decode(TorrentStoredDisplayName.self, from: Data("{\"rootName\":\"Fargo\",\"displayName\":\"Fargo 5\"}".utf8))
        #expect(old.season == nil)
        let name = TorrentStoredDisplayName(rootName: "Original", displayName: "Santa Clarita Diet", season: .init(title: "Santa Clarita Diet", season: 2))
        #expect(try JSONDecoder().decode(TorrentStoredDisplayName.self, from: JSONEncoder().encode(name)) == name)
    }
    @Test("unchecked episodes keep the complete smart naming plan")
    func uncheckedNaming() throws {
        let files = ["Friends.S01E01.Pilot.mkv", "Friends.S02E01.Next.720p.mkv"].map {
            TorrentFile(name: "Friends/" + $0, length: 1, bytesCompleted: 0)
        }
        let all = try #require(TorrentNameCleaner.plan(rootName: "Friends", files: files, selectedFileIndices: [0, 1]))
        #expect(TorrentNameCleaner.plan(rootName: "Friends", files: files, selectedFileIndices: [0]) == all)
        #expect(TorrentNameCleaner.plan(rootName: "Friends", files: files, selectedFileIndices: []) == all)
        #expect(all.season == nil)
    }

}
