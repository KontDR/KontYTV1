import Foundation

struct HTTPContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64
    init?(_ header: String) {
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("bytes ") else { return nil }
        let halves = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard halves.count == 2, let total = Int64(halves[1]), total > 0 else { return nil }
        let range = halves[0].split(separator: "-", omittingEmptySubsequences: false)
        guard range.count == 2, let start = Int64(range[0]), let end = Int64(range[1]), start >= 0, end >= start, end < total else { return nil }
        self.start = start; self.end = end; self.total = total
    }
}
enum TransferRange {
    static let chunkBytes: Int64 = 8 * 1024 * 1024
    static func header(offset: Int64, total: Int64?, openEnded: Bool = false) -> String? {
        guard offset >= 0, offset < Int64.max - chunkBytes else { return nil }
        if let total, total <= offset { return nil }
        if openEnded { return "bytes=\(offset)-" }
        let end = min(offset + chunkBytes - 1, (total ?? Int64.max) - 1)
        return "bytes=\(offset)-\(end)"
    }
    static func appendOffMain(_ input: URL, to output: URL, expectedOffset: Int64) async throws {
        let task = Task.detached(priority: .utility) { try append(input, to: output, expectedOffset: expectedOffset) }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    static func append(_ input: URL, to output: URL, expectedOffset: Int64) throws {
        guard expectedOffset >= 0, input.standardizedFileURL.resolvingSymlinksInPath() != output.standardizedFileURL.resolvingSymlinksInPath() else {
            throw YouTubeMediaError.unavailable("Kaynak ve hedef farklı dosyalar olmalı; geçersiz parça isteği.")
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: output.path) { guard fm.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }; }
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        // Query the open descriptor, not a URL resource cache populated before writing.
        let actualOffset = try writer.seekToEnd()
        guard actualOffset == UInt64(expectedOffset) else { throw YouTubeMediaError.unavailable("Parça sırası/dosya boyutu uyuşmuyor; güvenli yeniden indirme gerekiyor.") }
        do {
            while let bytes = try reader.read(upToCount: 1024 * 1024), !bytes.isEmpty { try Task.checkCancellation(); try writer.write(contentsOf: bytes) }
            try writer.synchronize()
        } catch { try? writer.truncate(atOffset: UInt64(expectedOffset)); throw error }
    }
}
