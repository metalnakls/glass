import Foundation
import GlassRemoteCore

@MainActor
private enum SharedGlassFormatters {
    static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static let shortDuration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static let longDuration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

@MainActor
func formatBytes(_ bytes: UInt64) -> String {
    SharedGlassFormatters.byteCount.string(fromByteCount: Int64(bytes))
}

@MainActor
func formatBytes(_ bytes: UInt64?) -> String {
    guard let bytes else { return "Unavailable" }
    return formatBytes(bytes)
}

@MainActor
func formatRate(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond > 0 else { return "0 KB/s" }
    return "\(SharedGlassFormatters.byteCount.string(fromByteCount: Int64(bytesPerSecond)))/s"
}

func formatPercent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(0)))
}

func formatStatus(_ status: Int) -> String {
    switch TransmissionTorrentStatus(rawValue: status) {
    case .stopped:
        return "Stopped"
    case .checkQueued:
        return "Queued check"
    case .checking:
        return "Checking"
    case .downloadQueued:
        return "Queued"
    case .downloading:
        return "Downloading"
    case .seedQueued:
        return "Queued seed"
    case .seeding:
        return "Seeding"
    case nil:
        return "Status \(status)"
    }
}

func formatRatio(_ value: Double?) -> String {
    guard let value, value >= 0 else { return "Unavailable" }
    return value.formatted(.number.precision(.fractionLength(2)))
}

func formatTimestamp(_ timestamp: Int?) -> String {
    guard let timestamp, timestamp > 0 else { return "Unavailable" }
    return Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(date: .abbreviated, time: .shortened)
}

@MainActor
func formatDuration(_ seconds: Int?) -> String {
    guard let seconds, seconds > 0 else { return "Unavailable" }
    let formatter = seconds >= 3_600
        ? SharedGlassFormatters.longDuration
        : SharedGlassFormatters.shortDuration
    return formatter.string(from: TimeInterval(seconds)) ?? "Unavailable"
}

func formatPriority(_ priority: Int?) -> String {
    switch priority {
    case let value? where value > 0:
        return "High"
    case let value? where value < 0:
        return "Low"
    case .some:
        return "Normal"
    case nil:
        return "Unavailable"
    }
}

func formatBool(_ value: Bool?) -> String {
    guard let value else { return "Unavailable" }
    return value ? "On" : "Off"
}

func completedPieceCount(from base64Pieces: String, total: Int) -> Int {
    guard let data = Data(base64Encoded: base64Pieces), total > 0 else {
        return 0
    }

    var completed = 0
    for byte in data {
        for bit in 0..<8 {
            guard completed < total else { return completed }
            if byte & (0x80 >> UInt8(bit)) != 0 {
                completed += 1
            }
        }
    }
    return completed
}
