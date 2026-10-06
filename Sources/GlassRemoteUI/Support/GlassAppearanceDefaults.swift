import AppKit
import Foundation

@MainActor
public enum GlassAppearanceDefaults {
    static var remote: [String: Any] = [:]
    static var effective: [String: Any] { bundled.merging(remote) { _, new in new } }

    static var bundled: [String: Any] {
        guard let url = Bundle.module.url(forResource: "AppearanceDefaults", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return inspectorDefaults.merging(values) { _, saved in saved }
    }

    private static let inspectorDefaults: [String: Any] = [
        "GlassInspector.blurEnabled": false,
        "GlassInspector.blurRadius": 6.0,
        "GlassInspector.blurEaseIn": 0.25,
        "GlassInspector.blurEaseOut": 0.35
    ]

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
        defaults.register(defaults: effective)
        if defaults === UserDefaults.standard { GlassTuningUpdates.shared.loadCached() }
    }

    /// Saved with the appearance tune so new windows share the chosen dimensions.
    public static var mainWindowSize: CGSize {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: "GlassWindow.defaultWidth")
        let height = defaults.double(forKey: "GlassWindow.defaultHeight")
        return CGSize(width: width.isFinite && width >= 680 ? width : 760,
                      height: height.isFinite && height >= 260 ? height : 444)
    }

    static func snapshot(in defaults: UserDefaults = .standard) -> [String: Any] {
        var values = bundled
        for key in values.keys {
            if let value = defaults.object(forKey: key) { values[key] = value }
        }
        return values
    }

    static func save() throws -> Bool {
        guard GlassTuningMode.isEnabled else { return false }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AppearanceDefaults.json")
        let panel = NSSavePanel()
        panel.title = glassText("Save appearance defaults")
        panel.message = glassText("Save this file in the project Resources folder. Publish this file with Scripts/push-tunes to update appearance without an app release.")
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = source.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        if let window = NSApp.windows.first(where: { $0.title == "Glass" && $0.sheetParent == nil }) {
            let size = window.contentLayoutRect.size
            UserDefaults.standard.set(size.width, forKey: "GlassWindow.defaultWidth")
            UserDefaults.standard.set(size.height, forKey: "GlassWindow.defaultHeight")
        }
        let data = try JSONSerialization.data(withJSONObject: snapshot(), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return true
    }
}
