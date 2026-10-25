import CryptoKit
import Darwin
import Foundation

/// The immutable identity record for a shared show directory.
public struct YinaShowDescriptor: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let showID: UUID
    public let createdAt: Date

    public init(showID: UUID, createdAt: Date = .now) {
        schemaVersion = Self.currentSchemaVersion
        self.showID = showID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, showID, createdAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else { throw YinaShowStore.Error.unsupportedSchema(version) }
        schemaVersion = version
        showID = try values.decode(UUID.self, forKey: .showID)
        createdAt = try values.decode(String.self, forKey: .createdAt).yinaDate
    }
}

/// A single writer's latest view of one torrent. Writers never share this file.
public struct YinaTransferFragment: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let showID: UUID
    public let writerID: UUID
    public let index: ShowEpisodeIndex

    public init(showID: UUID, writerID: UUID, index: ShowEpisodeIndex) {
        schemaVersion = Self.currentSchemaVersion
        self.showID = showID
        self.writerID = writerID
        self.index = index
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, showID, writerID, index }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else { throw YinaShowStore.Error.unsupportedSchema(version) }
        schemaVersion = version
        showID = try values.decode(UUID.self, forKey: .showID)
        writerID = try values.decode(UUID.self, forKey: .writerID)
        index = try values.decode(ShowEpisodeIndex.self, forKey: .index)
    }
}

public struct YinaCoverageInterval: Sendable, Hashable, Codable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start else {
            throw YinaShowStore.Error.invalidProgress
        }
        self.start = start
        self.end = end
    }
}

public struct YinaProgressSnapshot: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1
    public enum Activity: String, Sendable, Hashable, Codable { case playing, paused, stopped }

    public let schemaVersion: Int
    public let showID: UUID
    public let participantID: UUID
    public let writerID: UUID
    public let revision: UInt64
    public let updatedAt: Date
    public let relativePath: String
    public let position: Double
    public let duration: Double
    public let activity: Activity
    public let coverage: [YinaCoverageInterval]

    public init(
        showID: UUID,
        participantID: UUID,
        writerID: UUID,
        revision: UInt64,
        updatedAt: Date = .now,
        relativePath: String,
        position: Double,
        duration: Double,
        activity: Activity,
        coverage: [YinaCoverageInterval] = []
    ) throws {
        guard Self.isSafeRelativePath(relativePath), position.isFinite, duration.isFinite,
              position >= 0, duration > 0, position <= duration,
              coverage.count <= 20_000,
              coverage.allSatisfy({ $0.start >= 0 && $0.end > $0.start && $0.end <= duration }) else {
            throw YinaShowStore.Error.invalidProgress
        }
        schemaVersion = Self.currentSchemaVersion
        self.showID = showID
        self.participantID = participantID
        self.writerID = writerID
        self.revision = revision
        self.updatedAt = updatedAt
        self.relativePath = relativePath
        self.position = position
        self.duration = duration
        self.activity = activity
        self.coverage = coverage
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, showID, participantID, writerID, revision, updatedAt
        case relativePath, position, duration, activity, coverage
    }

    fileprivate static func isSafeRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && !value.contains("\0") &&
            value.utf8.count <= 4096 && !value.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else { throw YinaShowStore.Error.unsupportedSchema(version) }
        do {
            try self.init(
                showID: values.decode(UUID.self, forKey: .showID),
                participantID: values.decode(UUID.self, forKey: .participantID),
                writerID: values.decode(UUID.self, forKey: .writerID),
                revision: values.decode(UInt64.self, forKey: .revision),
                updatedAt: values.decode(String.self, forKey: .updatedAt).yinaDate,
                relativePath: values.decode(String.self, forKey: .relativePath),
                position: values.decode(Double.self, forKey: .position),
                duration: values.decode(Double.self, forKey: .duration),
                activity: values.decode(Activity.self, forKey: .activity),
                coverage: values.decodeIfPresent([YinaCoverageInterval].self, forKey: .coverage) ?? []
            )
        } catch let error as DecodingError {
            throw error
        }
        guard coverage.allSatisfy({ $0.start >= 0 && $0.end > $0.start && $0.end <= duration }) else {
            throw YinaShowStore.Error.invalidProgress
        }
    }
}

/// One writer's current request for an episode or asset from the shared show.
public struct YinaDownloadDemand: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let showID: UUID
    public let requestID: UUID
    public let participantID: UUID
    public let writerID: UUID
    public let revision: UInt64
    public let updatedAt: Date
    public let relativePath: String
    public let hashString: String?
    public let fileIndex: Int?
    public let cancelled: Bool

    public init(
        showID: UUID,
        requestID: UUID,
        participantID: UUID,
        writerID: UUID,
        revision: UInt64,
        updatedAt: Date = .now,
        relativePath: String,
        hashString: String? = nil,
        fileIndex: Int? = nil,
        cancelled: Bool = false
    ) throws {
        guard YinaProgressSnapshot.isSafeRelativePath(relativePath),
              (hashString == nil) == (fileIndex == nil),
              fileIndex.map({ $0 >= 0 }) ?? true,
              hashString.map({ YinaShowStore.isValidTransferHash($0) }) ?? true else {
            throw YinaShowStore.Error.invalidDemand
        }
        schemaVersion = Self.currentSchemaVersion
        self.showID = showID
        self.requestID = requestID
        self.participantID = participantID
        self.writerID = writerID
        self.revision = revision
        self.updatedAt = updatedAt
        self.relativePath = relativePath
        self.hashString = hashString?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.fileIndex = fileIndex
        self.cancelled = cancelled
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, showID, requestID, participantID, writerID, revision, updatedAt
        case relativePath, hashString, fileIndex, cancelled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else { throw YinaShowStore.Error.unsupportedSchema(version) }
        try self.init(
            showID: values.decode(UUID.self, forKey: .showID),
            requestID: values.decode(UUID.self, forKey: .requestID),
            participantID: values.decode(UUID.self, forKey: .participantID),
            writerID: values.decode(UUID.self, forKey: .writerID),
            revision: values.decode(UInt64.self, forKey: .revision),
            updatedAt: values.decode(String.self, forKey: .updatedAt).yinaDate,
            relativePath: values.decode(String.self, forKey: .relativePath),
            hashString: values.decodeIfPresent(String.self, forKey: .hashString),
            fileIndex: values.decodeIfPresent(Int.self, forKey: .fileIndex),
            cancelled: values.decode(Bool.self, forKey: .cancelled)
        )
    }
}

/// File-backed protocol store. Keep calls off the main actor; each writer ID must be unique per app run.
public actor YinaShowStore {
    public static let demandFreshnessLimit: TimeInterval = 15 * 60
    public enum Error: Swift.Error, Equatable {
        case unsafePath
        case unsafeExistingPath
        case notRegularFile
        case oversizedFile
        case tooManyEntries
        case aggregateReadLimitExceeded
        case unsupportedSchema(Int)
        case legacyIndexMustRemainReadOnly
        case invalidTransferHash
        case identityMismatch
        case invalidProgress
        case progressRevisionNotIncreasing
        case invalidDemand
        case demandRevisionNotIncreasing
        case writeFailed(String)
    }

    private var root: URL
    private let maximumTransferBytes = 10 * 1024 * 1024
    private let maximumProgressBytes = 512 * 1024
    private let maximumDirectoryEntries = 4096
    private let maximumAggregateEntries = 8192
    private let aggregateReadByteLimit: Int
    private static let maximumAggregateReadBytes = 64 * 1024 * 1024

    public init(rootURL: URL) {
        aggregateReadByteLimit = Self.maximumAggregateReadBytes
        root = rootURL.standardizedFileURL
    }

    init(rootURL: URL, aggregateReadByteLimit: Int) {
        root = rootURL.standardizedFileURL
        self.aggregateReadByteLimit = min(max(aggregateReadByteLimit, 1), Self.maximumAggregateReadBytes)
    }

    public func readDescriptor() throws -> YinaShowDescriptor? {
        try validateRoot()
        let url = root.appendingPathComponent(".yina.json")
        guard fileExists(url) else { return nil }
        // Legacy v1 indexes can be much larger than the small v2 identity descriptor.
        let data = try readRegularFile(url, limit: maximumTransferBytes)
        if let descriptor = try? Self.decoder().decode(YinaShowDescriptor.self, from: data) { return descriptor }
        if let legacy = try? Self.decoder().decode(ShowEpisodeIndex.self, from: data) {
            return YinaShowDescriptor(showID: Self.deterministicShowID(for: legacy.hashString), createdAt: legacy.capturedAt)
        }
        // Decode again to preserve a useful unsupported-schema error when possible.
        _ = try Self.decoder().decode(YinaShowDescriptor.self, from: data)
        return nil
    }

    /// Creates the descriptor with O_EXCL semantics. The random identity does not depend on a torrent.
    public func createDescriptorIfAbsent(createdAt: Date = .now) throws -> YinaShowDescriptor {
        try validateRoot()
        if let descriptor = try readDescriptor() { return descriptor }
        let descriptor = YinaShowDescriptor(showID: UUID(), createdAt: createdAt)
        let data = try Self.encoder().encode(descriptor)
        try createDirectoryIfNeeded(root)
        let url = root.appendingPathComponent(".yina.json")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else {
            let openError = errno
            if openError == EEXIST {
                // Another process may have created the name but not finished writing yet.
                for _ in 0..<5 {
                    if let existing = try? readDescriptor() { return existing }
                    usleep(20_000)
                }
            }
            throw Error.writeFailed(String(cString: strerror(openError)))
        }
        do {
            try writeAll(data, to: fd)
            guard fsync(fd) == 0 else { throw Error.writeFailed(String(cString: strerror(errno))) }
            _ = close(fd)
            return descriptor
        } catch {
            _ = close(fd)
            throw error
        }
    }

    /// Compatibility overload for callers that already have a transfer hash. New show identity is independent of it.
    public func createDescriptorIfAbsent(transferHash: String, createdAt: Date = .now) throws -> YinaShowDescriptor {
        try createDescriptorIfAbsent(createdAt: createdAt)
    }

    /// Reads a legacy v1 single-torrent index without modifying it.
    public func readLegacyIndex() throws -> ShowEpisodeIndex? {
        try validateRoot()
        let url = root.appendingPathComponent(".yina.json")
        guard fileExists(url) else { return nil }
        let data = try readRegularFile(url, limit: maximumTransferBytes)
        do { return try Self.decoder().decode(ShowEpisodeIndex.self, from: data) }
        catch { return nil }
    }

    public func publishTransferSnapshot(_ index: ShowEpisodeIndex, showID: UUID, writerID: UUID) throws {
        try validateRoot()
        let hash = try Self.validatedHash(index.hashString)
        guard let descriptor = try readDescriptor(), descriptor.showID == showID else { throw Error.identityMismatch }
        let fragment = YinaTransferFragment(showID: showID, writerID: writerID, index: index)
        let data = try Self.encoder().encode(fragment)
        guard data.count <= maximumTransferBytes else { throw Error.oversizedFile }
        let directory = root.appendingPathComponent(".yina/transfers/\(writerID.uuidString.lowercased())", isDirectory: true)
        try createDirectoryIfNeeded(directory)
        try atomicWrite(data, to: directory.appendingPathComponent("\(hash).json"))
    }

    public func readTransferSnapshots(showID: UUID, at date: Date = .now) throws -> [YinaTransferFragment] {
        try validateRoot()
        let base = root.appendingPathComponent(".yina/transfers", isDirectory: true)
        guard fileExists(base) else { return [] }
        let writers = try boundedChildren(of: base, limit: maximumDirectoryEntries)
        var entryCount = writers.count
        var bytesRead = 0
        var fragments: [YinaTransferFragment] = []
        for writerDirectory in writers {
            guard let writerID = UUID(uuidString: writerDirectory.lastPathComponent), try isSafeDirectory(writerDirectory) else { continue }
            let files = try boundedChildren(of: writerDirectory, limit: maximumDirectoryEntries)
            entryCount += files.count
            guard entryCount <= maximumAggregateEntries else { throw Error.tooManyEntries }
            for file in files where file.pathExtension == "json" {
                guard try isSafeRegularFile(file) else { continue }
                do {
                    let data = try readBudgetedFile(file, fileLimit: maximumTransferBytes, bytesRead: &bytesRead)
                    let fragment = try Self.decoder().decode(YinaTransferFragment.self, from: data)
                    guard fragment.showID == showID, fragment.writerID == writerID,
                          Self.normalizedHash(fragment.index.hashString) == file.deletingPathExtension().lastPathComponent,
                          fragment.index.isFresh(at: date) else { continue }
                    fragments.append(fragment)
                } catch Error.aggregateReadLimitExceeded { throw Error.aggregateReadLimitExceeded }
                catch { continue }
            }
        }
        return fragments
    }

    public func publishProgress(_ progress: YinaProgressSnapshot) throws {
        try validateRoot()
        guard let descriptor = try readDescriptor(), descriptor.showID == progress.showID else { throw Error.identityMismatch }
        let directory = root.appendingPathComponent(
            ".yina/progress/\(progress.participantID.uuidString.lowercased())", isDirectory: true
        )
        try createDirectoryIfNeeded(directory)
        let destination = directory.appendingPathComponent("\(progress.writerID.uuidString.lowercased()).json")
        if fileExists(destination) {
            let oldData = try readRegularFile(destination, limit: maximumProgressBytes)
            let previous = try Self.decoder().decode(YinaProgressSnapshot.self, from: oldData)
            guard previous.showID == progress.showID, previous.participantID == progress.participantID,
                  previous.writerID == progress.writerID else { throw Error.identityMismatch }
            guard progress.revision > previous.revision else { throw Error.progressRevisionNotIncreasing }
        }
        let data = try Self.encoder().encode(progress)
        guard data.count <= maximumProgressBytes else { throw Error.oversizedFile }
        try atomicWrite(data, to: destination)
    }

    public func readProgress(showID: UUID, at date: Date = .now) throws -> [YinaProgressSnapshot] {
        try validateRoot()
        let base = root.appendingPathComponent(".yina/progress", isDirectory: true)
        guard fileExists(base) else { return [] }
        var records: [YinaProgressSnapshot] = []
        let participants = try boundedChildren(of: base, limit: maximumDirectoryEntries)
        var entryCount = participants.count
        var bytesRead = 0
        for participantDirectory in participants {
            guard let participantID = UUID(uuidString: participantDirectory.lastPathComponent),
                  try isSafeDirectory(participantDirectory) else { continue }
            let files = try boundedChildren(of: participantDirectory, limit: maximumDirectoryEntries)
            entryCount += files.count
            guard entryCount <= maximumAggregateEntries else { throw Error.tooManyEntries }
            for file in files where file.pathExtension == "json" {
                guard let writerText = file.deletingPathExtension().lastPathComponent as String?,
                      let writerID = UUID(uuidString: writerText), try isSafeRegularFile(file) else { continue }
                do {
                    let data = try readBudgetedFile(file, fileLimit: maximumProgressBytes, bytesRead: &bytesRead)
                    let record = try Self.decoder().decode(YinaProgressSnapshot.self, from: data)
                    guard record.showID == showID, record.participantID == participantID, record.writerID == writerID,
                          record.updatedAt <= date else { continue }
                    records.append(record)
                } catch Error.aggregateReadLimitExceeded { throw Error.aggregateReadLimitExceeded }
                catch { continue }
            }
        }
        return records
    }

    /// Replaces only this writer's demand snapshot. Repeating the same record is idempotent.
    public func publishDemand(_ demand: YinaDownloadDemand) throws {
        try validateRoot()
        guard let descriptor = try readDescriptor(), descriptor.showID == demand.showID else { throw Error.identityMismatch }
        let directory = root.appendingPathComponent(".yina/demand", isDirectory: true)
        try createDirectoryIfNeeded(directory)
        let destination = directory.appendingPathComponent("\(demand.writerID.uuidString.lowercased()).json")
        if fileExists(destination) {
            let previous = try Self.decoder().decode(
                YinaDownloadDemand.self,
                from: readRegularFile(destination, limit: maximumProgressBytes)
            )
            guard previous.showID == demand.showID, previous.writerID == demand.writerID else { throw Error.identityMismatch }
            if previous == demand { return }
            guard demand.revision > previous.revision else { throw Error.demandRevisionNotIncreasing }
        }
        let data = try Self.encoder().encode(demand)
        guard data.count <= maximumProgressBytes else { throw Error.oversizedFile }
        try atomicWrite(data, to: destination)
    }

    public func readDemand(showID: UUID, at date: Date = .now) throws -> [YinaDownloadDemand] {
        try validateRoot()
        let directory = root.appendingPathComponent(".yina/demand", isDirectory: true)
        guard fileExists(directory) else { return [] }
        var demands: [YinaDownloadDemand] = []
        var bytesRead = 0
        for file in try boundedChildren(of: directory, limit: maximumDirectoryEntries) where file.pathExtension == "json" {
            guard let writerID = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  try isSafeRegularFile(file) else { continue }
            do {
                let data = try readBudgetedFile(file, fileLimit: maximumProgressBytes, bytesRead: &bytesRead)
                let demand = try Self.decoder().decode(YinaDownloadDemand.self, from: data)
                let age = date.timeIntervalSince(demand.updatedAt)
                guard demand.showID == showID, demand.writerID == writerID,
                      age >= 0, age <= Self.demandFreshnessLimit else { continue }
                demands.append(demand)
            } catch Error.aggregateReadLimitExceeded { throw Error.aggregateReadLimitExceeded }
            catch { continue }
        }
        return demands
    }

    /// Stable v2 ID derivation: SHA-256 of UTF-8 `glass-yina-show-v2:<lowercased-trimmed-hash>`,
    /// first 16 digest bytes, with UUID version 4 and RFC 4122 variant bits set.
    public static func deterministicShowID(for transferHash: String) -> UUID {
        let normalized = transferHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = Array(SHA256.hash(data: Data("glass-yina-show-v2:\(normalized)".utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func readRegularFile(_ url: URL, limit: Int) throws -> Data {
        guard try isSafeRegularFile(url) else { throw Error.unsafeExistingPath }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw Error.unsafeExistingPath }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw Error.notRegularFile }
        guard info.st_size <= limit else { throw Error.oversizedFile }

        var bytes = [UInt8](repeating: 0, count: limit + 1)
        var offset = 0
        let readCount = bytes.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            while offset < buffer.count {
                let count = Darwin.read(fd, base.advanced(by: offset), buffer.count - offset)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                offset += count
            }
            return offset
        }
        guard readCount >= 0 else { throw Error.notRegularFile }
        guard readCount <= limit else { throw Error.oversizedFile }
        return Data(bytes.prefix(readCount))
    }

    private func readBudgetedFile(_ url: URL, fileLimit: Int, bytesRead: inout Int) throws -> Data {
        let remaining = aggregateReadByteLimit - bytesRead
        guard remaining > 0 else { throw Error.aggregateReadLimitExceeded }
        let limit = min(fileLimit, remaining)
        let data: Data
        do { data = try readRegularFile(url, limit: limit) }
        catch Error.oversizedFile where remaining < fileLimit { throw Error.aggregateReadLimitExceeded }
        catch { throw error }
        bytesRead += data.count
        return data
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        do {
            if fileExists(url), try !isSafeRegularFile(url) { throw Error.unsafeExistingPath }
            try data.write(to: url, options: .atomic)
        } catch let error as Error { throw error }
        catch { throw Error.writeFailed(error.localizedDescription) }
    }

    private func createDirectoryIfNeeded(_ directory: URL) throws {
        let relative = relativeComponents(of: directory)
        var current = root
        for component in relative {
            current.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw Error.unsafeExistingPath }
            } else if errno == ENOENT {
                do { try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false) }
                catch { if !fileExists(current) { throw Error.writeFailed(error.localizedDescription) } }
                guard try isSafeDirectory(current) else { throw Error.unsafeExistingPath }
            } else { throw Error.unsafeExistingPath }
        }
    }

    private func isSafeDirectory(_ url: URL) throws -> Bool {
        guard isContained(url) else { return false }
        return try hasSafeAncestors(url, finalType: S_IFDIR)
    }

    private func isSafeRegularFile(_ url: URL) throws -> Bool {
        guard isContained(url) else { return false }
        return try hasSafeAncestors(url, finalType: S_IFREG)
    }

    private func hasSafeAncestors(_ url: URL, finalType: mode_t) throws -> Bool {
        var current = root
        let components = relativeComponents(of: url)
        for (offset, component) in components.enumerated() {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0 else { return false }
            let expected = offset == components.count - 1 ? finalType : S_IFDIR
            guard (info.st_mode & S_IFMT) == expected else { return false }
        }
        return !components.isEmpty
    }

    private func isContained(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.path
        return path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    private func relativeComponents(of url: URL) -> [String] {
        let suffix = String(url.standardizedFileURL.path.dropFirst(root.path.count))
        return suffix.split(separator: "/").map(String.init)
    }

    private func boundedChildren(of directory: URL, limit: Int) throws -> [URL] {
        guard try isSafeDirectory(directory) else { throw Error.unsafeExistingPath }
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard children.count <= limit else { throw Error.tooManyEntries }
        return children
    }

    private func fileExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw Error.writeFailed(String(cString: strerror(errno))) }
                if count == 0 { throw Error.writeFailed("The descriptor write returned zero bytes.") }
                offset += count
            }
        }
    }

    private func validateRoot() throws {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        guard lstat(resolved.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw Error.unsafeExistingPath
        }
        root = resolved
    }

    private static func normalizedHash(_ value: String) -> String? {
        let hash = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !hash.isEmpty, hash.utf8.count <= 128,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return hash
    }

    fileprivate static func isValidTransferHash(_ value: String) -> Bool { normalizedHash(value) != nil }

    private static func validatedHash(_ value: String) throws -> String {
        guard let hash = normalizedHash(value) else { throw Error.invalidTransferHash }
        return hash
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && !value.contains("\0") &&
            value.utf8.count <= 4096 && !value.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(YinaDateCodec.format(date))
        }
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = YinaDateCodec.parse(value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 timestamp")
            }
            return date
        }
        return decoder
    }
}

private enum YinaDateCodec {
    static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func parse(_ value: String) -> Date? {
        let formatter = formatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func format(_ date: Date) -> String { formatter().string(from: date) }
}

private extension String {
    var yinaDate: Date {
        get throws {
            guard let date = YinaDateCodec.parse(self) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid ISO-8601 timestamp"))
            }
            return date
        }
    }
}
