import Foundation
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Config-only tuning updates", .serialized)
struct GlassTuningUpdatesTests {
    @Test func explicitUpdateChecksIncludeTuning() {
        var tuneChecks = 0
        var appChecks = 0
        let availability = GlassUpdateAvailability(refreshTuning: { tuneChecks += 1 })
        availability.setCheckForUpdates { appChecks += 1 }
        availability.checkForUpdates()
        #expect(tuneChecks == 1)
        #expect(appChecks == 1)
    }

    @Test func explicitTuneRefreshBypassesDailyThrottle() async throws {
        let suite = "GlassTests.ForceTune.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
            GlassAppearanceDefaults.remote = [:]
        }
        var requests = 0
        let client = GlassTuningUpdates(defaults: defaults, cacheURL: folder.appendingPathComponent("tune.json")) { request in
            requests += 1
            return (Data("{\"GlassInspector.permanentSearch\":false}".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await client.refresh())
        #expect(await client.refresh() == false)
        #expect(await client.refresh(force: true))
        #expect(requests == 2)
        #expect(defaults.object(forKey: "GlassInspector.permanentSearch") as? Bool == false)
        defaults.set(true, forKey: "GlassInspector.permanentSearch")
        client.loadCached()
        #expect(defaults.bool(forKey: "GlassInspector.permanentSearch") == false)
    }

    @Test func validation() throws {
        let baseline = GlassAppearanceDefaults.bundled
        #expect(throws: (any Error).self) { try GlassTuningUpdates.validate(Data("{\"GlassList.funMode\":1}".utf8), against: baseline) }
        #expect(throws: (any Error).self) { try GlassTuningUpdates.validate(Data("{\"GlassList.highlightColorDark\":\"bad\"}".utf8), against: baseline) }
        #expect(throws: (any Error).self) { try GlassTuningUpdates.validate(Data("{\"GlassList.leftPadding\":999999}".utf8), against: baseline) }
        #expect(throws: (any Error).self) { try GlassTuningUpdates.validate(Data("{\"password\":\"secret\"}".utf8), against: baseline) }
        let values = try GlassTuningUpdates.validate(Data("{\"GlassList.highlightColorDark\":\"101010\",\"future\":true}".utf8), against: baseline)
        #expect(values.count == 1)
    }

    @Test func skipsUnsupportedValuesWithoutDiscardingSavedTune() throws {
        let baseline = GlassAppearanceDefaults.bundled
        let data = Data("""
        {
          "GlassList.initialPadding": 0,
          "GlassList.loadingSort": "transmission",
          "GlassList.highlightColorDark": "bad",
          "GlassList.funMode": 1,
          "future.setting": true
        }
        """.utf8)
        let values = try GlassTuningUpdates.validate(data, against: baseline)
        #expect(values.count == 1)
        #expect((values["GlassList.initialPadding"] as? NSNumber)?.doubleValue == 0)
    }

    @Test func savedWindowDimensionsAreAccepted() throws {
        let baseline = GlassAppearanceDefaults.bundled
        let data = Data("{\"GlassWindow.defaultWidth\":792,\"GlassWindow.defaultHeight\":459}".utf8)
        let values = try GlassTuningUpdates.validate(data, against: baseline)
        #expect((values["GlassWindow.defaultWidth"] as? NSNumber)?.doubleValue == 792)
        #expect((values["GlassWindow.defaultHeight"] as? NSNumber)?.doubleValue == 459)
        #expect(throws: (any Error).self) {
            try GlassTuningUpdates.validate(Data("{\"GlassWindow.defaultWidth\":true}".utf8), against: baseline)
        }
        #expect(throws: (any Error).self) {
            try GlassTuningUpdates.validate(Data("{\"GlassWindow.defaultHeight\":100000}".utf8), against: baseline)
        }
    }

    @Test func deliveryAndOfflineCache() async throws {
        let suite = "GlassTests.Tunes.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
            GlassAppearanceDefaults.remote = [:]
        }
        let cache = folder.appendingPathComponent("tunes.json")
        defaults.set("FFFFFF", forKey: "GlassList.highlightColorDark")
        let data = Data("{\"GlassList.highlightColorDark\":\"121212\",\"GlassList.headerFadeStrengthDark\":0.2,\"GlassList.headerFadeStrengthLight\":0.9}".utf8)
        var requests = 0
        let client = GlassTuningUpdates(defaults: defaults, cacheURL: cache) { request in
            requests += 1
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "revision1"])!)
        }
        #expect(await client.refresh())
        #expect(defaults.string(forKey: "GlassList.highlightColorDark") == "121212")
        #expect(defaults.double(forKey: "GlassList.headerFadeStrengthDark") == 0.2)
        #expect(defaults.double(forKey: "GlassList.headerFadeStrengthLight") == 0.9)
        #expect(try Data(contentsOf: cache) == data)
        #expect(await client.refresh() == false)
        #expect(requests == 1)
        let invalid = GlassTuningUpdates(defaults: defaults, cacheURL: cache) { request in
            (Data("broken".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await invalid.refresh() == false)
        #expect(try Data(contentsOf: cache) == data)
        defaults.set("FFFFFF", forKey: "GlassList.highlightColorDark")
        let offline = GlassTuningUpdates(defaults: defaults, cacheURL: cache) { _ in throw URLError(.notConnectedToInternet) }
        offline.loadCached()
        #expect(defaults.string(forKey: "GlassList.highlightColorDark") == "121212")
        #expect(await offline.refresh() == false)
        let unchanged = GlassTuningUpdates(defaults: defaults, cacheURL: cache) { request in
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == "revision1")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await unchanged.refresh(force: true))
    }
}
