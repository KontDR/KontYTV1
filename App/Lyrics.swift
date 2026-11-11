import Foundation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let seconds: Double
    let text: String
}
enum LRCParser {
    static func parse(_ source: String) -> [LyricLine] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]"#),
              let offsetRegex = try? NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        var offset = 0.0
        if let match = offsetRegex.firstMatch(in: source, range: range), let value = Range(match.range(at: 1), in: source) {
            offset = (Double(source[value]) ?? 0) / 1000
        }
        var lines: [(Double, String)] = []
        for raw in source.components(separatedBy: .newlines) {
            let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            guard let last = matches.last, let textRange = Range(NSRange(location: NSMaxRange(last.range), length: (raw as NSString).length - NSMaxRange(last.range)), in: raw) else { continue }
            let text = String(raw[textRange]).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: raw), let secondRange = Range(match.range(at: 2), in: raw),
                      let minutes = Double(raw[minuteRange]), let seconds = Double(raw[secondRange]), seconds < 60 else { continue }
                lines.append((max(0, minutes * 60 + seconds - offset), text))
            }
        }
        let sorted = lines.enumerated().sorted {
            $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0
        }.map { $0.element }
        return sorted.enumerated().map { LyricLine(id: $0.offset, seconds: $0.element.0, text: $0.element.1) }
    }
}
struct LyricsRecord: Codable, Identifiable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
}
enum SongIdentity {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func guess(_ title: String) -> (artist: String, title: String) {
        let clean = title.replacingOccurrences(of: #"(?i)(\([^)]*(?:official|video|audio|lyrics|lyric|klip)[^)]*\)|\[[^\]]*(?:official|video|audio|lyrics|lyric|klip)[^\]]*\])"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = clean.components(separatedBy: " - ")
        if pieces.count >= 2 { return (pieces[0].trimmingCharacters(in: .whitespaces), pieces.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)) }
        return ("", clean)
    }
    static func confident(_ record: LyricsRecord, artist: String, title: String, duration: Double?) -> Bool {
        guard !artist.isEmpty, normalized(record.artistName) == normalized(artist), normalized(record.trackName) == normalized(title),
              let duration, duration > 0, abs(record.duration - duration) <= 4 else { return false }
        return true
    }
}
actor LyricsClient {
    static let shared = LyricsClient()
    private var nextAllowed = Date.distantPast
    private var busy = false
    func search(title: String, artist: String) async throws -> [LyricsRecord] {
        guard !busy else { throw YouTubeMediaError.unavailable("Bir söz araması sürüyor; bitince tekrar dene.") }
        let remaining = nextAllowed.timeIntervalSinceNow
        guard remaining <= 0 else { throw YouTubeMediaError.unavailable("Söz servisi için \(Int(ceil(min(remaining, Double(Int.max / 2))))) saniye bekle.") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        busy = true
        defer { busy = false }
        nextAllowed = Date().addingTimeInterval(0.5)
        var url = URLComponents(string: "https://lrclib.net/api/search")!
        url.queryItems = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { url.queryItems?.append(URLQueryItem(name: "artist_name", value: artist)) }
        var request = URLRequest(url: url.url!, timeoutInterval: 20)
        // Anonymous API, no API key. Identify this sideload client; never send a video URL or cookies.
        request.setValue("KontYT/0.13.39 (https://github.com/KontDR/KontYT)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 429 {
            let delay = YouTubeHTTP.retrySeconds(http)
            nextAllowed = Date().addingTimeInterval(delay + Double.random(in: 0...max(1, delay * 0.2)))
            throw YouTubeMediaError.unavailable("LRCLIB istek sınırı: \(Int(ceil(min(delay, Double(Int.max / 2))))) saniye sonra yeniden dene.")
        }
        guard http.statusCode == 200, data.count <= 3 * 1024 * 1024 else { throw YouTubeMediaError.unavailable("Söz servisi HTTP \(http.statusCode) yanıtı verdi.") }
        return Array(try JSONDecoder().decode([LyricsRecord].self, from: data).prefix(25))
    }
}
enum LyricsCache {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Lyrics", isDirectory: true)
    }
    static func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }
    static func load(_ id: UUID) -> LyricsRecord? { try? JSONDecoder().decode(LyricsRecord.self, from: Data(contentsOf: url(id))) }
    static func save(_ record: LyricsRecord, id: UUID) throws {
        let path = url(id)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: path, options: .atomic)
        NotificationCenter.default.post(name: .kontytLyricsChanged, object: id)
    }
}

extension Notification.Name { static let kontytLyricsChanged = Notification.Name("KontYT.LyricsChanged") }
