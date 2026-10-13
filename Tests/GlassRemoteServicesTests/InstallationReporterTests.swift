import Foundation
import Testing
@testable import GlassRemoteServices

@MainActor @Suite struct InstallationReporterTests {
    @Test func acknowledgesOnlySuccessAndKeepsIdentityAcrossVersions() async throws {
        let suite = "GlassReporterTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reports: [InstallationReporter.Report] = []
        let sender: (URLRequest) async throws -> Int = { request in
            reports.append(try JSONDecoder().decode(InstallationReporter.Report.self, from: request.httpBody!))
            return 204
        }
        let reporter = InstallationReporter(defaults: defaults, send: sender)
        await reporter.report(version: "8.2", osVersion: "27.0.0", macModel: "Mac14,2")
        await reporter.report(version: "8.2", osVersion: "27.0.0", macModel: "Mac14,2")
        let relaunched = InstallationReporter(defaults: defaults, send: sender)
        await relaunched.report(version: "8.2", osVersion: "27.0.0", macModel: "Mac14,2")
        await relaunched.report(version: "8.3", osVersion: "27.0.0", macModel: "Mac14,2")
        #expect(reports.count == 2)
        #expect(reports[0].installationID == reports[1].installationID)
        #expect(reports[1].appVersion == "8.3")
    }

    @Test func failedReportRetriesOnNextLaunch() async throws {
        let suite = "GlassReporterTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let failed = InstallationReporter(defaults: defaults, send: { _ in 503 })
        await failed.report(version: "8.2", osVersion: "27.0", macModel: "Mac14,2")
        #expect(defaults.data(forKey: "GlassMetrics.lastAcknowledged") == nil)
        let identifier = defaults.string(forKey: "GlassMetrics.installationID")
        var calls = 0
        let retry = InstallationReporter(defaults: defaults, send: { _ in calls += 1; return 204 })
        await retry.report(version: "8.2", osVersion: "27.0", macModel: "Mac14,2")
        #expect(calls == 1)
        #expect(defaults.string(forKey: "GlassMetrics.installationID") == identifier)
    }
}
