import Foundation
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Saved release appearance")
struct GlassAppearanceDefaultsTests {
    @Test("bundled defaults keep separate theme colours and do not overwrite user tuning")
    func registration() throws {
        let suite = "GlassTests.Defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.12, forKey: "GlassList.headerFadeStrengthDark")
        defaults.set(1.25, forKey: "GlassList.iconGlassBlur")
        defaults.set(2.5, forKey: "GlassList.iconGlassHDRDark")
        GlassAppearanceDefaults.register(in: defaults, domainName: suite)
        #expect(defaults.string(forKey: "GlassList.highlightColorLight") == GlassAppearanceDefaults.bundled["GlassList.highlightColorLight"] as? String)
        #expect(defaults.string(forKey: "GlassList.highlightColorDark") == GlassAppearanceDefaults.bundled["GlassList.highlightColorDark"] as? String)
        #expect(defaults.double(forKey: "GlassList.headerFadeStrengthDark") == 0.12)
        #expect(defaults.bool(forKey: "GlassList.stateGlass") == GlassAppearanceDefaults.bundled["GlassList.stateGlass"] as? Bool)
        defaults.set("credential", forKey: "serverPassword")
        let snapshot = GlassAppearanceDefaults.snapshot(in: defaults)
        #expect(snapshot["serverPassword"] == nil)
        #expect(snapshot["GlassList.headerFadeStrengthDark"] as? Double == 0.12)
        #expect(snapshot["GlassList.iconGlassBlur"] as? Double == 1.25)
        #expect(snapshot["GlassList.iconGlassHDRDark"] as? Double == 2.5)
    }

    @Test("every Tune appearance control is included in the saved snapshot")
    func tuneControlCoverage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/GlassRemoteUI/Views/SelectionAppearanceView.swift"), encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"@AppearanceStorage\("([^"]+)""#)
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source))
        let keys = matches.compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } }
        let missing = keys.filter { GlassAppearanceDefaults.bundled[$0] == nil }
        #expect(missing.isEmpty, "Tune controls missing from the saved configuration: \(missing)")
    }

    @Test("compact inspector search survives saving and Tune validation")
    func compactSearchSnapshot() throws {
        let suite = "GlassTests.SearchTune.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "GlassInspector.permanentSearch")
        let snapshot = GlassAppearanceDefaults.snapshot(in: defaults)
        #expect(snapshot["GlassInspector.permanentSearch"] as? Bool == false)
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        let values = try GlassTuningUpdates.validate(data, against: GlassAppearanceDefaults.bundled)
        #expect(values["GlassInspector.permanentSearch"] as? Bool == false)
    }

    @Test("legacy shared strength seeds both independent modes")
    func migration() throws {
        let suite = "GlassTests.Defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.92, forKey: "GlassList.headerFadeStrength")
        GlassAppearanceDefaults.register(in: defaults, domainName: suite)
        defaults.set(0.11, forKey: "GlassList.headerFadeStrengthDark")
        #expect(defaults.double(forKey: "GlassList.headerFadeStrengthLight") == 0.92)
        #expect(defaults.double(forKey: "GlassList.headerFadeStrengthDark") == 0.11)
    }
}
