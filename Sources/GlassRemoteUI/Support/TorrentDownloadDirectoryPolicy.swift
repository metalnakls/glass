import Foundation
import GlassRemoteCore

/// Installers and disk images are not media-library content. On the Mac they
/// belong in Downloads, which is also where Safari and Finder put them.
enum TorrentDownloadDirectoryPolicy {
    /// Apps, packages, disk images and other bootable or installable containers.
    /// Ordinary archives and media intentionally stay on the server's default.
    static let macInstallerExtensions: Set<String> = [
        "app", "appx", "cdr", "deb", "dmg", "dmgpart", "exe", "img", "iso",
        "mpkg", "msi", "msix", "pkg", "rpm", "sparsebundle", "sparseimage",
        "toast", "xip",
    ]

    static func prefersMacDownloads(fileNames: [String]) -> Bool {
        let extensions = Set(fileNames.map { ($0 as NSString).pathExtension.lowercased() })
        if !extensions.isDisjoint(with: macInstallerExtensions) { return true }
        return extensions.contains("flac") && extensions.isDisjoint(with: TorrentNameCleaner.videoExtensions)
    }

    static func source(for names: [String], selected: UUID, local: UUID, remotes: [UUID]) -> UUID {
        if prefersMacDownloads(fileNames: names) { return local }
        if names.contains(where: TorrentNameCleaner.isVideoFile), !remotes.contains(selected) {
            return remotes.first ?? local
        }
        return selected
    }

    static var downloadsDirectory: String? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
    }
}
