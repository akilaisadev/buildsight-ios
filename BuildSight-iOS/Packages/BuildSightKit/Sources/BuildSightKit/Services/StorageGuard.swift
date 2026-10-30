import Foundation

/// Stops a photo being saved when the device is nearly out of space, with a message that says what to do.
/// A full disk would otherwise fail halfway through saving and lose the photo.
public enum StorageGuard {
    /// Room needed to save one photo and its analysis comfortably.
    public static let minimumFreeBytes: Int64 = 50 * 1024 * 1024

    /// True when there is enough room. An unknown amount (nil) never blocks saving.
    public static func hasRoom(available: Int64?, needed: Int64 = minimumFreeBytes) -> Bool {
        guard let available else { return true }
        return available >= needed
    }

    public static func message(available: Int64) -> String {
        let free = ByteCountFormatter.string(fromByteCount: max(available, 0), countStyle: .file)
        return "Your device has only \(free) of free space, not enough to save this photo safely. Free up some space, then take or upload it again."
    }

    /// Free space the system will let this app use, or nil if it can't be read.
    public static func deviceAvailableBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
