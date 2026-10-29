import Foundation

/// One JSON convention for local payloads, queued operations and server
/// bodies: ISO-8601 timestamps with fractional seconds. Plain `.iso8601` would
/// silently drop milliseconds, so a record would not round-trip equal and
/// conflict detection would see phantom changes.
public enum RecordCodec {
    // ISO8601DateFormatter is documented thread-safe for formatting and parsing.
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatter.string(from: date))
        }
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = formatter.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
            }
            return date
        }
        return d
    }
}
