import AppKit
import Foundation
import GlassRemoteCore
import UniformTypeIdentifiers

enum ShowEpisodeIndexExporter {
    private static let maximumManifestBytes = 10 * 1024 * 1024

    enum ExportError: LocalizedError, Equatable {
        case noDownloadDirectory
        case noMountedFolderLink
        case invalidFolderBookmark
        case destinationOutsideDownloadRoot
        case unsafeExistingPath
        case wrongFilename
        case incompatibleExistingIndex
        case oversizedManifest
        case noVideos
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDownloadDirectory: "This torrent has no download directory."
            case .noMountedFolderLink: "Connect a local folder for this remote download before exporting."
            case .invalidFolderBookmark: "The mounted download folder is no longer available. Reconnect it and try again."
            case .destinationOutsideDownloadRoot: "Choose a folder inside this torrent’s download location."
            case .unsafeExistingPath: "An existing path resolves outside the selected show folder."
            case .wrongFilename: "The episode index must be named .yina.json."
            case .incompatibleExistingIndex: "The existing .yina.json belongs to another format or torrent, so it was left unchanged."
            case .oversizedManifest: "The episode index is too large to export safely."
            case .noVideos: "This torrent has no video files to include in an episode index."
            case let .writeFailed(message): "Could not write the episode index: \(message)"
            }
        }
    }

    /// Presents an explicit save action, then writes a point-in-time manifest atomically.
    /// The downloaded folder remains untouched except for the sidecar itself.
    @MainActor
    static func export(
        details: TorrentDetails,
        sourceID: UUID,
        isLocal: Bool
    ) async throws -> URL? {
        let snapshotDate = Date.now
        guard let downloadDirectory = details.downloadDir, downloadDirectory.hasPrefix("/") else {
            throw ExportError.noDownloadDirectory
        }
        guard details.files.contains(where: { TorrentNameCleaner.isPreviewableVideo($0.name) }) else {
            throw ExportError.noVideos
        }

        var scopedRoot: URL?
        let downloadRoot: URL
        if isLocal {
            downloadRoot = URL(fileURLWithPath: downloadDirectory, isDirectory: true).standardizedFileURL
        } else {
            guard let link = TorrentThumbnailService.shared.link(for: sourceID) else {
                throw ExportError.noMountedFolderLink
            }
            let resolved = try await resolveMountedDownloadRoot(link: link, directory: downloadDirectory)
            downloadRoot = resolved.downloadRoot
            scopedRoot = resolved.scopedRoot
        }
        defer { scopedRoot?.stopAccessingSecurityScopedResource() }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = ".yina.json"
        panel.isExtensionHidden = true
        panel.canCreateDirectories = false
        panel.directoryURL = inferredShowRoot(details: details, downloadRoot: downloadRoot) ?? downloadRoot
        guard await panel.begin() == .OK, let destination = panel.url else { return nil }
        guard destination.lastPathComponent == ".yina.json" else { throw ExportError.wrongFilename }

        let showRoot = destination.deletingLastPathComponent().standardizedFileURL
        guard let prefix = relativePath(of: showRoot, under: downloadRoot) else {
            throw ExportError.destinationOutsideDownloadRoot
        }
        let snapshot = try ShowEpisodeIndex(details: details, relativePathPrefix: prefix, capturedAt: snapshotDate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumManifestBytes else { throw ExportError.oversizedManifest }

        do {
        try await writeAtomically(data, to: destination, showRoot: showRoot, downloadRoot: downloadRoot,
                                  details: details, prefix: prefix, existingHash: snapshot.hashString)
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return destination
    }

    private static func inferredShowRoot(details: TorrentDetails, downloadRoot: URL) -> URL? {
        let videoPaths = details.files.map(\.name).filter(TorrentNameCleaner.isPreviewableVideo)
        guard !videoPaths.isEmpty,
              videoPaths.allSatisfy(ShowEpisodeIndexExporter.isSafeRelativePath) else { return nil }
        let components = videoPaths.map { $0.split(separator: "/").map(String.init) }
        if components.contains(where: { $0.count == 1 }) { return downloadRoot }
        let firstComponents = Set(components.compactMap(\.first))
        guard firstComponents.count == 1, let first = firstComponents.first,
              !isSeasonFolder(first) else { return nil }
        return downloadRoot.appendingPathComponent(first, isDirectory: true).standardizedFileURL
    }

    private static func isSeasonFolder(_ component: String) -> Bool {
        component.range(of: #"(?i)^(?:season|series|s|сезон)[ ._-]*\d{1,2}$"#, options: .regularExpression) != nil
    }

    /// Returns the remote-relative prefix that corresponds to a user-selected local show folder.
    private static func relativePath(of child: URL, under root: URL) -> String? {
        let base = root.standardizedFileURL.path
        let path = child.standardizedFileURL.path
        guard path == base || path.hasPrefix(base == "/" ? "/" : base + "/") else { return nil }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func writeAtomically(
        _ data: Data,
        to destination: URL,
        showRoot: URL,
        downloadRoot: URL,
        details: TorrentDetails,
        prefix: String,
        existingHash: String
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try validateExistingPaths(showRoot: showRoot, downloadRoot: downloadRoot, details: details, prefix: prefix)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try validateReplaceableIndex(at: destination, expectedHash: existingHash)
                    }
                    try data.write(to: destination, options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func validateExistingPaths(showRoot: URL, downloadRoot: URL, details: TorrentDetails, prefix: String) throws {
        let resolvedRoot = showRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDownloadRoot = downloadRoot.resolvingSymlinksInPath().standardizedFileURL
        guard isWithin(downloadRoot: resolvedDownloadRoot, candidate: resolvedRoot) else {
            throw ExportError.destinationOutsideDownloadRoot
        }
        for file in details.files where TorrentNameCleaner.isPreviewableVideo(file.name) {
            guard Self.isSafeRelativePath(file.name) else { throw ShowEpisodeIndex.ValidationError.unsafePath(file.name) }
            guard let relative = relativePath(from: file.name, removing: prefix) else {
                throw ExportError.destinationOutsideDownloadRoot
            }
            let relativeComponents = relative.split(separator: "/").map(String.init)
            var candidate = showRoot
            for component in relativeComponents {
                candidate.appendPathComponent(component)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
                    guard isWithin(downloadRoot: resolvedRoot, candidate: resolved) else {
                        throw ExportError.unsafeExistingPath
                    }
                }
            }
        }
    }

    private static func isWithin(downloadRoot: URL, candidate: URL) -> Bool {
        let rootPath = downloadRoot.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    static func validateReplaceableIndex(at url: URL, expectedHash: String) throws {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
              values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumManifestBytes else {
            throw ExportError.incompatibleExistingIndex
        }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "hashString", "capturedAt", "episodes"]),
              object["schemaVersion"] as? Int == ShowEpisodeIndex.currentSchemaVersion,
              object["hashString"] as? String == expectedHash,
              let episodes = object["episodes"] as? [[String: Any]],
              episodes.allSatisfy(validEpisodeObject),
              (try? JSONDecoder().decode(ShowEpisodeIndex.self, from: data)) != nil else {
            throw ExportError.incompatibleExistingIndex
        }
    }

    private static func validEpisodeObject(_ value: [String: Any]) -> Bool {
        let required: Set<String> = ["id", "relativePath", "bytesCompleted", "totalBytes"]
        let optional: Set<String> = ["season", "episode", "wanted"]
        guard required.isSubset(of: Set(value.keys)),
              Set(value.keys).subtracting(required).isSubset(of: optional),
              let id = value["id"] as? [String: Any],
              Set(id.keys) == Set(["hashString", "fileIndex"]) else { return false }
        return true
    }

    private static func resolveMountedDownloadRoot(
        link: TorrentThumbnailFolderLink,
        directory: String
    ) async throws -> (downloadRoot: URL, scopedRoot: URL?) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var stale = false
                guard let root = try? URL(resolvingBookmarkData: link.bookmark,
                                          options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                          relativeTo: nil, bookmarkDataIsStale: &stale) else {
                    continuation.resume(throwing: ExportError.invalidFolderBookmark)
                    return
                }
                let didStartScope = root.startAccessingSecurityScopedResource()
                guard let mapped = TorrentThumbnailFolderLink.directoryURL(
                    remoteRoot: link.remoteRoot,
                    localRoot: root,
                    directory: directory
                ) else {
                    if didStartScope { root.stopAccessingSecurityScopedResource() }
                    continuation.resume(throwing: ExportError.invalidFolderBookmark)
                    return
                }
                continuation.resume(returning: (mapped.standardizedFileURL, didStartScope ? root : nil))
            }
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") && !path.contains("~") &&
            !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func relativePath(from path: String, removing prefix: String) -> String? {
        guard isSafeRelativePath(path) else { return nil }
        guard !prefix.isEmpty else { return path }
        guard path.hasPrefix(prefix + "/") else { return nil }
        return String(path.dropFirst(prefix.count + 1))
    }
}
