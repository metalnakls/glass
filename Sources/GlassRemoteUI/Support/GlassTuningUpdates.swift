import Foundation
import CoreFoundation

/// Appearance-only data. Never accepts server settings, credentials, or executable content.
@MainActor
public final class GlassTuningUpdates {
    public static let shared = GlassTuningUpdates()
    static let feed = URL(string: "https://raw.githubusercontent.com/metalnakls/glass/main/Sources/GlassRemoteUI/Resources/AppearanceDefaults.json")!
    private let defaults: UserDefaults
    private let cacheURL: URL
    private var checking = false
    private var lastAttempt: Date?
    private let download: (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(defaults: UserDefaults = .standard, cacheURL: URL? = nil,
         download: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
             let (data, response) = try await URLSession.shared.data(for: request)
             guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
             return (data, response)
         }) {
        self.defaults = defaults
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glass/appearance-defaults.json")
        self.download = download
    }

    static func validate(_ data: Data, against baseline: [String: Any]) throws -> [String: Any] {
        guard data.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], !object.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        var values: [String: Any] = [:]
        for (key, value) in object {
            // Ignore future keys so older clients can still consume newer configs.
            guard let original = baseline[key] else { continue }
            if let original = original as? NSNumber, let number = value as? NSNumber {
                let boolean = CFGetTypeID(original) == CFBooleanGetTypeID()
                guard boolean == (CFGetTypeID(number) == CFBooleanGetTypeID()),
                      boolean || (number.doubleValue.isFinite && range(for: key).contains(number.doubleValue)) else {
                    throw URLError(.cannotParseResponse)
                }
                values[key] = number
            } else if original is String, let color = value as? String,
                      color.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil {
                values[key] = color
            } else {
                throw URLError(.cannotParseResponse)
            }
        }
        guard !values.isEmpty else { throw URLError(.cannotParseResponse) }
        return values
    }

    private static func range(for key: String) -> ClosedRange<Double> {
        if key == "GlassWindow.defaultWidth" { return 680...16384 }
        if key == "GlassWindow.defaultHeight" { return 260...16384 }
        let name = String(key.dropFirst("GlassList.".count))
        switch name {
        case "iconGlassFrost", "iconGlassBrightness", "iconGlassTintStrength": return 0...1
        case "iconShadowStrength": return 0...0.65
        case "iconShadowSoftness": return 0...32
        case "iconShadowOffset": return 0...24
        case "iconGlassOpacity": return 0.1...1
        case "iconGlassBlur": return 0...6
        case "iconGlassHDRLight", "iconGlassHDRDark": return 0...3
        case "iconGlassHDRSoftness": return 0...4
        case "iconGlassHDRWidth": return 0.5...3
        case "columnDarkBrightness", "columnLightBrightness", "headerFadeStrengthDark", "headerFadeStrengthLight": return 0...1
        case "shadowTopStrength", "shadowBottomStrength": return 0...0.65
        case "funScale": return 1...1.8
        case "funTilt", "progressGlowBlur": return 0...16
        case "headerBackgroundIn", "headerBackgroundOut", "headerTitleIn", "headerTitleOut", "selectionEaseIn", "selectionEaseOut": return 0...1.5
        case "selectedHDRWhiteLight", "selectedHDRWhiteDark": return 0...3
        case "progressGlowStrength": return 0...2
        case "progressLineWidth": return 0.5...5
        case "highlightWidth": return -80...160
        case "itemVerticalPadding": return -10...30
        case "leftPadding", "rightPadding": return 0...160
        case "headerPushLead", "sectionSpacing", "headerBottomPadding": return 0...120
        case "selectedHDRSpread", "shadowTopLift", "shadowBottomLift": return 0...24
        case "selectedHDRSoftness", "shadowTopSoftness", "shadowBottomSoftness", "dropBlurRadius", "stateGap", "filePriorityGap": return 0...32
        default: return 0...240
        }
    }

    func loadCached() {
        guard let data = try? Data(contentsOf: cacheURL),
              let values = try? Self.validate(data, against: GlassAppearanceDefaults.bundled) else { return }
        apply(values)
    }

    private func apply(_ values: [String: Any]) {
        GlassAppearanceDefaults.remote = values
        defaults.register(defaults: GlassAppearanceDefaults.effective)
        for (key, value) in values { defaults.set(value, forKey: key) }
        if defaults === UserDefaults.standard { AppearancePreferences.shared.invalidate() }
    }

    /// Launch / activation checks are throttled; the menu command bypasses the interval.
    @discardableResult
    public func refresh(force: Bool = false) async -> Bool {
        guard !checking, force || lastAttempt.map({ Date().timeIntervalSince($0) >= 86_400 }) ?? true else { return false }
        checking = true
        lastAttempt = Date()
        defer { checking = false }
        do {
            var request = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            if FileManager.default.fileExists(atPath: cacheURL.path), let tag = defaults.string(forKey: "GlassTuning.etag") {
                request.setValue(tag, forHTTPHeaderField: "If-None-Match")
            }
            let (data, response) = try await download(request)
            if response.statusCode == 304 { loadCached(); return true }
            guard response.statusCode == 200 else { return false }
            let values = try Self.validate(data, against: GlassAppearanceDefaults.bundled)
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            if let tag = response.value(forHTTPHeaderField: "ETag") { defaults.set(tag, forKey: "GlassTuning.etag") }
            else { defaults.removeObject(forKey: "GlassTuning.etag") }
            apply(values)
            return true
        } catch {
            // Offline, unpublished, and invalid feeds leave the last valid appearance untouched.
            return false
        }
    }
}
