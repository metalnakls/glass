import AppKit
import Observation
import UniformTypeIdentifiers

/// Finder obtains network-computer icons from Bonjour device-info model tags.
/// Cache those same system images, independent of RPC health and mounted-folder icons.
@MainActor @Observable
final class NativeLocationIconCache: NSObject {
    static let shared = NativeLocationIconCache()
    private(set) var images: [UUID: NSImage] = [:]
    @ObservationIgnored private var names: [UUID: String] = [:]
    @ObservationIgnored private var aliases: [UUID: [String]] = [:]
    @ObservationIgnored private var paths: [UUID: String] = [:]
    @ObservationIgnored private let metadataQueue = DispatchQueue(label: "Glass.location-metadata", qos: .utility)
    @ObservationIgnored private var services: [NetService] = []
    @ObservationIgnored private let browser = NetServiceBrowser()
    @ObservationIgnored private var mountObserver: NSObjectProtocol?
    @ObservationIgnored private let diskQueue = DispatchQueue(label: "Glass.location-icons", qos: .utility)
    @ObservationIgnored private let directory: URL

    private struct Record: Codable { let name: String; let aliases: [String]?; let path: String?; let image: Data }

    init(directory: URL? = nil, discover: Bool = true) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glass/LocationIcons", isDirectory: true)
        super.init()
        // Small, local records only: never inspect an SMB folder on the UI thread.
        for url in (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(Record.self, from: data),
                  let image = NSImage(data: record.image) else { continue }
            names[id] = record.name
            aliases[id] = record.aliases ?? []
            paths[id] = record.path
            images[id] = image
        }
        browser.delegate = self
        guard discover else { return }
        refresh()
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refresh()
                    for (id, path) in self.paths { await self.resolveHost(sourceID: id, path: path) }
                }
            }
    }

    isolated deinit {
        if let mountObserver { NSWorkspace.shared.notificationCenter.removeObserver(mountObserver) }
        browser.stop()
        for service in services { service.stop() }
    }

    func register(sourceID: UUID, serverName: String, path: String?) async {
        let changed = names[sourceID] != serverName || paths[sourceID] != path
        names[sourceID] = serverName
        paths[sourceID] = path
        if changed, let path { await resolveHost(sourceID: sourceID, path: path) }
        for service in services where service.txtRecordData() != nil { accept(service) }
    }

    private func resolveHost(sourceID: UUID, path: String) async {
        let host: String? = await withCheckedContinuation { continuation in
            metadataQueue.async {
                let url = URL(fileURLWithPath: path)
                let values = try? url.resourceValues(forKeys: [.volumeURLForRemountingKey])
                continuation.resume(returning: values?.volumeURLForRemounting?.host)
            }
        }
        guard paths[sourceID] == path, let host else { return }
        aliases[sourceID] = [host]
        for service in services where service.txtRecordData() != nil { accept(service) }
    }

    private func refresh() {
        browser.stop()
        for service in services { service.stop() }
        services.removeAll()
        browser.searchForServices(ofType: "_device-info._tcp.", inDomain: "local.")
    }

    static func deviceType(model: String) -> UTType? {
        let type = UTType(tag: model, tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil)
        return type?.isDeclared == true ? type : nil
    }

    private func accept(_ service: NetService) {
        guard let txt = service.txtRecordData(), let modelData = NetService.dictionary(fromTXTRecord: txt)["model"],
              let model = String(data: modelData, encoding: .utf8) else { return }
        noteResolvedDevice(name: service.name, host: service.hostName, model: model)
    }

    func noteResolvedDevice(name: String, host: String?, model: String) {
        guard let type = Self.deviceType(model: model) else { return }
        let image = NSWorkspace.shared.icon(for: type)
        let serviceNames = [name, host ?? ""].map(Self.normalizedName)
        for (id, name) in names where ([name] + (aliases[id] ?? [])).contains(where: { serviceNames.contains(Self.normalizedName($0)) }) {
            images[id] = image
            guard let imageData = image.tiffRepresentation,
                  let data = try? JSONEncoder().encode(Record(name: name, aliases: aliases[id], path: paths[id], image: imageData)) else { continue }
            let directory = directory
            diskQueue.async {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: directory.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
            }
        }
    }

    private static func normalizedName(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .replacingOccurrences(of: ".local", with: "")
    }
}

extension NativeLocationIconCache: @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }
    func netServiceDidResolveAddress(_ sender: NetService) { accept(sender) }
}
