import Foundation
import Testing
@testable import GlassRemoteUI

struct MotionComparisonTests {
    @Test("each comparison saves an independent choice across reopen")
    func choicesRoundTrip() throws {
        var choices = MotionComparisonChoices()
        choices[.keyboard] = .before
        choices[.timing] = .after
        choices[.scrolling] = .neither
        let restored = try JSONDecoder().decode(MotionComparisonChoices.self,
            from: JSONEncoder().encode(choices))
        #expect(restored == choices)
        #expect(restored[.keyboard] == .before)
        #expect(restored[.timing] == .after)
        #expect(restored[.scrolling] == .neither)
        #expect(restored[.press] == nil)
        #expect(restored[.reduced] == nil)
    }

    @Test("a revised preference replaces one vote and exports all five topics")
    func revisedChoice() {
        var choices = MotionComparisonChoices()
        choices[.keyboard] = .before
        choices[.keyboard] = .after
        #expect(choices.selections.count == 1)
        #expect(choices.summary.contains("Keyboard search: After"))
        #expect(choices.summary.split(separator: "\n").count == 5)
        choices[.keyboard] = nil
        #expect(choices.selections.isEmpty)
    }
}
