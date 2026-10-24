import Foundation
import GlassRemoteCore
import Testing
@testable import GlassRemoteServices

@Suite("Season completion titles")
struct TorrentCompletionTitleTests {
    private func title(_ season: Int, series: String = "Walking Dead") -> TorrentCompletionTitle {
        .init(name: series, storedName: .init(rootName: series, displayName: series,
            season: .init(title: series, season: season)), downloadDirectory: "/downloads")
    }

    @Test("each season is identified independently when several exist")
    func distinctSeasons() {
        let siblings = (1...4).map { title($0) }
        for season in 1...4 {
            #expect(title(season).resolved(among: siblings) == "Walking Dead \(season)")
        }
        #expect(title(3).resolved(among: [title(3), title(3)]) == "Walking Dead")
        #expect(title(3).resolved(among: [title(3), title(4, series: "Other Series")]) == "Walking Dead")
        #expect(title(3).resolved(among: [title(4, series: "The Walking Dead")]) == "Walking Dead 3")
    }

    @Test("native season folders and older numbered display names supply context")
    func olderImports() {
        let native = TorrentCompletionTitle(name: "Season 4", storedName: nil, downloadDirectory: "/downloads/Walking Dead")
        let older = TorrentCompletionTitle(name: "Original", storedName: .init(rootName: "Original", displayName: "Walking Dead 2"), downloadDirectory: nil)
        #expect(title(3).resolved(among: [native]) == "Walking Dead 3")
        #expect(native.resolved(among: [title(3)]) == "Walking Dead 4")
        #expect(title(3).resolved(among: [older]) == "Walking Dead 3")
    }

    @Test("stale saved names and unrelated movie titles do not change notifications")
    func preservedNames() {
        let stale = TorrentCompletionTitle(name: "Renamed Movie.MKV", storedName: .init(rootName: "Walking Dead",
            displayName: "Walking Dead", season: .init(title: "Walking Dead", season: 3)), downloadDirectory: nil)
        #expect(stale.resolved(among: [title(4)]) == "Renamed Movie.MKV")
        let movie = TorrentCompletionTitle(name: "My Movie.MKV", storedName: nil, downloadDirectory: nil)
        #expect(movie.resolved(among: [title(4)]) == "My Movie.MKV")
    }
}
