import Foundation

public struct TorrentSeasonStoragePlan: Sendable {
    public let downloadDirectory: String
    public let namingPlan: TorrentAddNamingPlan

    public init(downloadDirectory: String, namingPlan: TorrentAddNamingPlan) {
        self.downloadDirectory = downloadDirectory
        self.namingPlan = namingPlan
    }

    public static func baseDirectory(base: String, title: String) -> String {
        let baseURL = URL(fileURLWithPath: base).standardizedFileURL
        if baseURL.lastPathComponent == title { return baseURL.deletingLastPathComponent().path }
        return baseURL.path
    }
}

