import Foundation
import CryptoKit

/// Stable UUIDs derived from another id. Used where "the same input must map to
/// the same row" is the whole point: the safety issue and analysis for a photo
/// are keyed by the photo, so re-analysing or syncing from two devices upserts
/// the same rows instead of creating duplicates.
public enum DeterministicID {
    public static func make(namespace: String, from source: UUID) -> UUID {
        let digest = SHA256.hash(data: Data("buildsight.\(namespace).\(source.uuidString)".utf8))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50   // version-5-style layout
        b[8] = (b[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
