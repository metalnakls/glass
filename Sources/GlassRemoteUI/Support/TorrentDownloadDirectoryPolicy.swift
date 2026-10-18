import Foundation

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
        fileNames.contains { name in
            macInstallerExtensions.contains((name as NSString).pathExtension.lowercased())
        }
    }

    static var downloadsDirectory: String? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
    }
}
