import Foundation
import UIKit

struct InboxLink: Codable, Identifiable {
    var id = UUID()
    var url: URL
    var created = Date()
}
enum InboxError: LocalizedError {
    case unavailable, invalid
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Bağlantı ortak alana yazılamadı; KontYT’yi açıp YouTube sekmesindeki “Panodan yapıştır” düğmesini kullan."
        case .invalid: return "YouTube video veya liste bağlantısı bulunamadı."
        }
    }
}
enum SharedInbox {
    static func folder() throws -> URL {
        guard let resolved = AppGroupResolver.resolved() else { throw InboxError.unavailable }
        let url = resolved.url.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func accepted(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
    static func extract(_ text: String) -> URL? {
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), accepted(url) { return url }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first(where: accepted)
    }
    /// Where a shared link ended up. Free Apple IDs strip App Groups on re-signing, so the
    /// pasteboard is a first-class path, not an error.
    enum Outcome { case shared, pasteboard }
    static let handoffPasteboard = "com.example.kontyt.inbox"

    /// `allowPasteboard: false` is used by the extension when it is about to open the app directly: if
    /// that works the user's clipboard is never touched, so iOS never has a reason to ask anything.
    @discardableResult static func store(_ url: URL, allowPasteboard: Bool = true) throws -> Outcome {
        guard accepted(url) else { throw InboxError.invalid }
        if let folder = try? folder() {
            let item = InboxLink(url: url)
            if (try? JSONEncoder().encode(item).write(to: folder.appendingPathComponent(item.id.uuidString + ".json"), options: .atomic)) != nil {
                return .shared
            }
        }
        if allowPasteboard { copyToHandoff(url) }
        return .pasteboard
    }
    /// Writing to the pasteboard never asks for permission; reading is the app's explicit job.
    static func copyToHandoff(_ url: URL) {
        UIPasteboard(name: UIPasteboard.Name(handoffPasteboard), create: true)?.string = url.absoluteString
        UIPasteboard.general.string = url.absoluteString
    }
    /// Clears our handoff slots only: the general pasteboard is wiped only when it still
    /// holds exactly the link we put there, so the user's own clipboard survives.
    static func clearHandoff(_ url: URL? = nil) {
        UIPasteboard(name: UIPasteboard.Name(handoffPasteboard), create: false)?.items = []
        if let url, UIPasteboard.general.string == url.absoluteString { UIPasteboard.general.items = [] }
    }
    static func pasteboardLinks() -> [URL] {
        let named = UIPasteboard(name: UIPasteboard.Name(handoffPasteboard), create: false)?.string
        var found: [URL] = []
        for text in [named, UIPasteboard.general.string] {
            guard let text, let url = extract(text), !found.contains(url) else { continue }
            found.append(url)
        }
        return found
    }
    static func load() throws -> [InboxLink] {
        let files = try FileManager.default.contentsOfDirectory(at: folder(), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        return files.compactMap { try? JSONDecoder().decode(InboxLink.self, from: Data(contentsOf: $0)) }.filter { accepted($0.url) }.sorted { $0.created < $1.created }
    }
    static func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: folder().appendingPathComponent(id.uuidString + ".json")) }
}
