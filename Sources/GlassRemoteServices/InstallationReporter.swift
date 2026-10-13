import Foundation
import Darwin

/// One anonymous record per preferences installation, not a hardware identity.
@MainActor
public final class InstallationReporter {
    public static let shared = InstallationReporter()
    struct Report: Codable, Equatable {
        let installationID: String
        let appVersion: String
        let osVersion: String
        let macModel: String
    }
    private let defaults: UserDefaults
    private let send: (URLRequest) async throws -> Int
    private var inFlight = false
    private var retryAfter = Date.distantPast

    init(defaults: UserDefaults = .standard, send: @escaping (URLRequest) async throws -> Int = { request in
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }) {
        self.defaults = defaults
        self.send = send
    }

    public func reportCurrentInstallation() async {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return }
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return }
        let model = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        await report(version: version, osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", macModel: model)
    }

    func report(version: String, osVersion: String, macModel: String) async {
        guard !inFlight, Date() >= retryAfter else { return }
        let key = "GlassMetrics.installationID"
        let identifier = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(identifier.uuidString, forKey: key)
        let report = Report(installationID: identifier.uuidString, appVersion: version, osVersion: osVersion, macModel: macModel)
        guard let body = try? JSONEncoder().encode(report),
              defaults.data(forKey: "GlassMetrics.lastAcknowledged") .flatMap({ try? JSONDecoder().decode(Report.self, from: $0) }) != report else { return }
        inFlight = true
        defer { inFlight = false }
        var request = URLRequest(url: URL(string: "https://glass.metalglass.workers.dev/installations")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            guard try await send(request) == 204 else { retryAfter = Date().addingTimeInterval(60); return }
            defaults.set(body, forKey: "GlassMetrics.lastAcknowledged")
            retryAfter = .distantPast
        } catch {
            retryAfter = Date().addingTimeInterval(60)
        }
    }
}
