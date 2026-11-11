import Foundation

/// Keyless oEmbed lookup. YouTube answers `oembed?url=…&format=json` with the real title and channel,
/// no login needed. It is used only to fill names the page did not give us - a bare shared link, or a
/// playlist row that arrived without a label - and it is always bounded, so importing a big list never
/// turns into a flood of requests.
actor TitleResolver {
    static let shared = TitleResolver()
    struct Info { let title: String; let channel: String }
    private var cache: [String: Info] = [:]
    private var misses: Set<String> = []
    private let batchLimit = 40
    private let parallel = 4

    private func isID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// True when a name is really missing: empty, or nothing but the id wearing a prefix.
    static func needsName(_ video: SavedVideo) -> Bool {
        let title = video.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || title.hasSuffix(video.id) || title == video.id
    }

    func info(for id: String) async -> Info? {
        if let cached = cache[id] { return cached }
        guard isID(id), !misses.contains(id) else { return nil }
        guard var parts = URLComponents(string: "https://www.youtube.com/oembed") else { return nil }
        parts.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=" + id),
                            URLQueryItem(name: "format", value: "json")]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("KontYT/0.13.39 (+https://github.com/KontDR/KontYT)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                misses.insert(id); return nil
            }
            let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { misses.insert(id); return nil }
            let info = Info(title: title, channel: (object["author_name"] as? String) ?? "")
            cache[id] = info
            return info
        } catch {
            misses.insert(id)
            return nil
        }
    }

    /// Fills missing names in order, four at a time, at most `batchLimit` rows. Everything else is
    /// left untouched, so a 500-row list still imports instantly with the names the page carried.
    func filling(_ videos: [SavedVideo]) async -> [SavedVideo] {
        var result = videos
        let targets = result.indices.filter { TitleResolver.needsName(result[$0]) }.prefix(batchLimit)
        var cursor = targets.startIndex
        while cursor < targets.endIndex {
            let slice = targets[cursor..<min(cursor + parallel, targets.endIndex)]
            cursor = slice.endIndex
            await withTaskGroup(of: (Int, Info?).self) { group in
                for index in slice {
                    let id = result[index].id
                    group.addTask { (index, await self.info(for: id)) }
                }
                for await (index, info) in group {
                    guard let info, index < result.count else { continue }
                    result[index].title = info.title
                    if result[index].channel.isEmpty { result[index].channel = info.channel }
                }
            }
        }
        return result
    }
}
