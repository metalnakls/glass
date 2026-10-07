import Foundation
import GlassRemoteCore
import Observation

/// One reversible app-level formatting policy; view reads observe changes immediately.
@MainActor @Observable
final class GlassFormatting {
    static let shared = GlassFormatting()
    @ObservationIgnored private let defaults: UserDefaults
    var usesSystemLocale: Bool { didSet { defaults.set(usesSystemLocale, forKey: "Glass.Formatting.useSystemLocale") } }
    var overrideIdentifier: String { didSet { defaults.set(overrideIdentifier, forKey: "Glass.Formatting.localeIdentifier") } }
    var usesRoundedSizes: Bool { didSet { defaults.set(usesRoundedSizes, forKey: "GlassList.roundedSizes") } }
    var locale: Locale { usesSystemLocale ? .autoupdatingCurrent : Locale(identifier: overrideIdentifier) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        usesSystemLocale = defaults.bool(forKey: "Glass.Formatting.useSystemLocale")
        overrideIdentifier = defaults.string(forKey: "Glass.Formatting.localeIdentifier") ?? "en_US"
        usesRoundedSizes = defaults.object(forKey: "GlassList.roundedSizes") as? Bool ?? true
    }
}

@MainActor public var glassRoundedSizes: Bool {
    get { GlassFormatting.shared.usesRoundedSizes }
    set { GlassFormatting.shared.usesRoundedSizes = newValue }
}

@MainActor
private enum SharedGlassFormatters {
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
    if GlassFormatting.shared.usesRoundedSizes {
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB", "EB"]
        var value = Double(bytes), index = 0
        while value >= 1000 && index < units.count - 1 { value /= 1000; index += 1 }
        return value.formatted(.number.precision(.fractionLength(0)).locale(GlassFormatting.shared.locale)) + " " + units[index]
    }
    return Int64(clamping: bytes).formatted(.byteCount(style: .file).locale(GlassFormatting.shared.locale))
}

@MainActor
func formatBytes(_ bytes: UInt64?) -> String {
    guard let bytes else { return "Unavailable" }
    return formatBytes(bytes)
}

@MainActor
func formatRate(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond > 0 else { return "0 KB/s" }
    return "\(Int64(bytesPerSecond).formatted(.byteCount(style: .file).locale(GlassFormatting.shared.locale)))/s"
}

@MainActor
func formatPercent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(0)).locale(GlassFormatting.shared.locale))
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

@MainActor
func formatNumber(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(2)).locale(GlassFormatting.shared.locale))
}

@MainActor
func formatRatio(_ value: Double?) -> String {
    guard let value, value >= 0 else { return "Unavailable" }
    return value.formatted(.number.precision(.fractionLength(2)).locale(GlassFormatting.shared.locale))
}

@MainActor
func formatTimestamp(_ timestamp: Int?) -> String {
    guard let timestamp, timestamp > 0 else { return "Unavailable" }
    return Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(GlassFormatting.shared.locale))
}

@MainActor
func formatDuration(_ seconds: Int?) -> String {
    guard let seconds, seconds > 0 else { return "Unavailable" }
    let formatter = seconds >= 3_600
        ? SharedGlassFormatters.longDuration
        : SharedGlassFormatters.shortDuration
    var calendar = Calendar.autoupdatingCurrent
    calendar.locale = GlassFormatting.shared.locale
    formatter.calendar = calendar
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

func prioritySystemImage(_ priority: Int?) -> String {
    switch priority {
    case let value? where value > 0:
        return "arrow.up.circle.fill"
    case let value? where value < 0:
        return "arrow.down.circle.fill"
    case .some:
        return "equal.circle"
    case nil:
        return "questionmark.circle"
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
