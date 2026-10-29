import Foundation
import GlassRemoteCore

/// The same naming and season storage rules used by the resolved Add editor.
enum MagnetAddPreparation {
    struct Result: Sendable {
        let preview: TorrentMetainfoPreview
        let plan: TorrentAddNamingPlan?
        let directory: String?
    }

    @concurrent static func validate(data: Data, magnet: String) async throws {
        try Task.checkCancellation()
        guard !TorrentMetainfoIdentity.hashes(in: data).isDisjoint(with: TorrentMetainfoIdentity.hashes(inMagnet: magnet)),
              let preview = TorrentMetainfoPreview(data: data), !preview.files.isEmpty else {
            throw NSError(domain: "Glass.MagnetMetadata", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The received metadata doesn’t match this magnet link."])
        }
    }

    @concurrent static func prepare(data: Data, directory: String?) async throws -> Result {
        try Task.checkCancellation()
        guard let preview = TorrentMetainfoPreview(data: data), !preview.files.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let suggestion = TorrentNameCleaner.plan(rootName: preview.name, files: preview.files,
            selectedFileIndices: Set(preview.files.indices))
        let season = TorrentNameCleaner.seasonDescriptor(for: TorrentBatchNamingInput(rootName: preview.name, files: preview.files))
        let plan = season.map {
            TorrentAddNamingPlan(rootName: $0.title, pathRenames: suggestion?.pathRenames ?? [], displayName: $0.title, season: $0)
        } ?? suggestion
        if let plan, plan.season != nil, let directory {
            let storage = TorrentSeasonStoragePlan(baseDirectory: directory, namingPlan: plan)
            return Result(preview: preview, plan: storage.namingPlan, directory: storage.downloadDirectory)
        }
        return Result(preview: preview, plan: plan, directory: directory)
    }
}
