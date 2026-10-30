import Foundation

public struct MergeOutcome: Equatable, Sendable {
    public var merged: JSONValue
    /// Fields both sides changed to different values. The server value wins
    /// for these, and the user is told so in the Sync Center.
    public var conflictedFields: [String]
}

/// Field-level three-way merge of base (last synced), local and remote. If only one side
/// changed a field, that side wins; if both changed it differently, the server wins and the
/// field is reported as conflicted. Append-only records (events, comments) never get here.
public enum ConflictResolver {
    public static func merge(base: JSONValue?, local: JSONValue, remote: JSONValue) -> MergeOutcome? {
        guard let local = local.objectValue, let remote = remote.objectValue else { return nil }
        let base = base?.objectValue ?? [:]
        var merged = remote
        var conflicts: [String] = []

        for key in Set(local.keys).union(remote.keys) {
            let l = local[key], r = remote[key], b = base[key]
            switch (l == b, r == b) {
            case (true, _):
                continue                       // we did not touch it: server value stands
            case (false, true):
                merged[key] = l                // only we changed it
            case (false, false):
                if l != r { conflicts.append(key) }   // both changed: server wins
            }
        }
        // Housekeeping fields must always describe the server's latest state.
        for key in ["serverVersion", "updatedAt"] {
            merged[key] = remote[key]
            conflicts.removeAll { $0 == key }
        }
        return MergeOutcome(merged: .object(merged), conflictedFields: conflicts.sorted())
    }
}
