import Foundation

// URL.resourceValues can retain cached size values across writes/moves.
// Read current filesystem attributes whenever byte counts affect correctness.
enum DiskFile {
    static func size(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber, number.int64Value >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return number.int64Value
    }
}
