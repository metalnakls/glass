import Foundation
import Testing
@testable import GlassRemoteUI

struct TorrentContentDestinationTests {
    @Test func freshLocationFollowsContent() {
        let local = UUID(), first = UUID(), second = UUID()
        func source(_ names: [String], from selected: UUID, remotes: [UUID]) -> UUID {
            TorrentDownloadDirectoryPolicy.source(for: names, selected: selected, local: local, remotes: remotes)
        }
        #expect(source(["Album/01.FLAC", "Album/Cover.jpg", "Album/foo_dr.txt"], from: second, remotes: [first, second]) == local)
        #expect(source(["Film.mkv"], from: local, remotes: [first, second]) == first)
        #expect(source(["Series/S01E01.avi", "Series/Subtitles.srt"], from: second, remotes: [first, second]) == second)
        #expect(source(["Film.mkv"], from: local, remotes: []) == local)
    }
}
