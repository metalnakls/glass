import Foundation
import Testing
@testable import GlassRemoteCore

@Suite("Presentation-only season naming")
struct SeasonPresentationTests {
    @Test("actual Santa Clarita release keeps its disk root")
    func actualRelease() throws {
        let root = "Santa.Clarita.Diet.s01.WEB-DL.1080p.2xRus.Eng"
        let files = [TorrentFile(name: "Santa.Clarita.Diet.S01E01.So.Then.a.Bat.or.a.Monkey.1080p.2xRus.Eng.mkv", length: 1, bytesCompleted: 0)]
        let plan = try #require(TorrentNameCleaner.plan(rootName: root, files: files, selectedFileIndices: [0]))
        #expect(plan.rootName == root)
        #expect(plan.displayName == "Santa Clarita Diet")
        #expect(plan.season == TorrentSeasonDescriptor(title: "Santa Clarita Diet", season: 1))
        #expect(plan.withDisplayName("My Series").rootName == root)
    }

    @Test("bilingual titles use the original series name")
    func bilingual() throws {
        let root = "Диета из Санта-Клариты Santa Clarita Diet Сезон 2 Серии 1-10 из 10 (Рубен Флейшер) [2017, США]"
        let plan = try #require(TorrentNameCleaner.plan(rootName: root, files: [], selectedFileIndices: []))
        #expect(plan.rootName == root)
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
}
