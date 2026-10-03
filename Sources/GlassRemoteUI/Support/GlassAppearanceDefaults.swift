import AppKit
import Foundation

@MainActor
public enum GlassAppearanceDefaults {
    static var bundled: [String: Any] {
        guard let url = Bundle.module.url(forResource: "AppearanceDefaults", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return values
    }

    public static func register(in defaults: UserDefaults = .standard, domainName: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) {
        // Seed independent strengths before registration masks the legacy fallback.
        let saved = defaults.persistentDomain(forName: domainName) ?? [:]
        if let legacy = saved["GlassList.headerFadeStrength"] as? Double {
            for key in ["GlassList.headerFadeStrengthLight", "GlassList.headerFadeStrengthDark"]
                where saved[key] == nil { defaults.set(legacy, forKey: key) }
        }
        if saved["GlassList.selectedHDRWhiteLight"] == nil, let legacy = saved["GlassList.selectedHDRWhite"] {
            defaults.set(legacy, forKey: "GlassList.selectedHDRWhiteLight")
        }
        defaults.register(defaults: bundled)
    }

    static func snapshot(in defaults: UserDefaults = .standard) -> [String: Any] {
        var values = bundled
        for key in values.keys {
            if let value = defaults.object(forKey: key) { values[key] = value }
        }
        return values
    }

    static func save() throws -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("--tune-appearance") else { return false }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AppearanceDefaults.json")
        let panel = NSSavePanel()
        panel.title = "Save appearance defaults"
        panel.message = "Save this file in the project Resources folder. Future builds use these values as their defaults."
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = source.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let data = try JSONSerialization.data(withJSONObject: snapshot(), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return true
    }
}
