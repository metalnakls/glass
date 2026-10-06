import AppKit
import SwiftUI

/// Folder icons locally; Finder network-computer icons for remote authorities.
struct NativeLocationIcon: View {
    let path: String?
    var sourceID: UUID? = nil
    var serverName = ""
    var size: CGFloat = 24
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let sourceID {
                Image(nsImage: NativeLocationIconCache.shared.images[sourceID] ?? NSWorkspace.shared.icon(for: .init("public.computer") ?? .item))
                    .resizable().scaledToFit().frame(width: size, height: size)
                    .task(id: "\(sourceID)|\(serverName)|\(path ?? "")") { await NativeLocationIconCache.shared.register(sourceID: sourceID, serverName: serverName, path: path) }
            } else {
                NativeGlassIcon(image: image ?? TorrentFileIconCache.icon(fileName: "", isFolder: true), size: size, isFolder: true)
            .task(id: path) {
                guard let path else { image = nil; return }
                let data = await Task.detached(priority: .utility) {
                    (path.hasSuffix(".icns") ? NSImage(contentsOfFile: path) : NSWorkspace.shared.icon(forFile: Self.resolvedFolderURL(path).path))?.tiffRepresentation
                }.value
                guard !Task.isCancelled else { return }
                image = data.flatMap(NSImage.init(data:))
            }
            }
        }
    }

    nonisolated static func resolvedFolderURL(_ path: String) -> URL {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true,
           let target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) {
            return target.resolvingSymlinksInPath()
        }
        return url
    }

}
