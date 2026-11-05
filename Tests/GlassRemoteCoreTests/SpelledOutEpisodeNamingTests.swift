import Testing
@testable import GlassRemoteCore

@Suite("Spelled-out episode naming")
struct SpelledOutEpisodeNamingTests {
    private static let titles = ["Warring Factions", "The Interview", "On the Pull", "Mark Makes a Friend", "Dream Job", "Funeral"]

    @Test("Peep Show's original torrent names produce canonical episode filenames", arguments: 1...6)
    func peepShow(episode: Int) {
        let title = Self.titles[episode - 1]
        let original = "Peep Show - Series 1 episode 0\(episode) - \(title).avi"
        #expect(TorrentNameCleaner.cleanMediaFileName(original) == "S01E0\(episode) — \(title).avi")
    }

    @Test("the Add plan carries every episode rename, including unchecked files")
    func addPlan() throws {
        let files = Self.titles.enumerated().map { offset, title in
            TorrentFile(name: "Peep Show/Peep Show - Series 1 episode 0\(offset + 1) - \(title).avi", length: 100, bytesCompleted: 0)
        }
        let plan = try #require(TorrentNameCleaner.plan(rootName: "Peep Show", files: files, selectedFileIndices: [0]))
        #expect(plan.rootName == "Peep Show")
        #expect(plan.season == TorrentSeasonDescriptor(title: "Peep Show", season: 1))
        #expect(plan.pathRenames == files.enumerated().map { offset, file in
            TorrentPathRename(path: file.name, name: "S01E0\(offset + 1) — \(Self.titles[offset]).avi")
        })
    }

    @Test("season and episode words share existing compact-code behavior", arguments: [
        ("Show Season 12 Episode 22 Finale.MKV", "S12E22 — Finale.MKV"),
        ("Show.Series.2.Episode.3.Pilot.1080p.avi", "S02E03 — Pilot.avi"),
        ("Show - SERIES 1 EPISODE 01 - Pilot.avi", "S01E01 — Pilot.avi"),
        ("Show.S02E20.Title.mkv", "S02E20 — Title.mkv"),
        ("Show.2x20.Title.mkv", "S02E20 — Title.mkv"),
        ("Episode 22.avi", "Episode 22.avi"),
        ("Film.2024.1080p.mkv", "Film.mkv")
    ])
    func variants(input: String, expected: String) {
        #expect(TorrentNameCleaner.cleanMediaFileName(input) == expected)
    }
}
