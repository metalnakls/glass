import Observation

/// One edit session spans all seasons shown in an inspector.
@MainActor
@Observable
final class TorrentFileEditSession {
    var selections: [String: Set<Int>] = [:]
    var wanted: [String: [Int: Bool]] = [:]
    var isApplying = false
    var hasSelection: Bool { selections.values.contains { !$0.isEmpty } }
    var hasChanges: Bool { wanted.values.contains { !$0.isEmpty } }
    func stageSelection(_ value: Bool) {
        for (hash, indices) in selections {
            for index in indices { wanted[hash, default: [:]][index] = value }
        }
    }
    func confirm(_ values: [Int: Bool], for hash: String) {
        for (index, value) in values where wanted[hash]?[index] == value { wanted[hash]?[index] = nil }
    }
    func reset() { selections = [:]; wanted = [:] }
}
