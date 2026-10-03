import Foundation
import Observation
import Testing
@testable import GlassRemoteUI

@Suite("Shared live tuning")
struct AppearancePreferencesTests {
    @MainActor @Test("an edit invalidates another window's reader and persists independently")
    func sharedEdits() throws {
        let suite = "GlassTests.Appearance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Saved release defaults are intentionally user-adjustable.
        defaults.set(0.92, forKey: "GlassList.headerFadeStrengthDark")
        defaults.set(0.92, forKey: "GlassList.headerFadeStrengthLight")
        let preferences = AppearancePreferences(defaults: defaults)
        let invalidated = Flag()
        withObservationTracking {
            #expect(preferences.value(for: "GlassList.headerFadeStrengthDark", fallback: Double(0.92)) == 0.92)
        } onChange: { invalidated.set() }
        preferences.set(Double(0.11), for: "GlassList.headerFadeStrengthDark")
        #expect(invalidated.value)
        #expect(preferences.value(for: "GlassList.headerFadeStrengthDark", fallback: Double(0.92)) == 0.11)
        #expect(preferences.value(for: "GlassList.headerFadeStrengthLight", fallback: Double(0.92)) == 0.92)
        #expect(defaults.double(forKey: "GlassList.headerFadeStrengthDark") == 0.11)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}
