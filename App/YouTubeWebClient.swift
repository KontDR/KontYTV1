import Foundation

enum YouTubeWebError: LocalizedError {
    case unavailable, challenge, changed, tooLarge, forbidden, consent
    case rateLimited(Double), http(Int)
    case loginRequired(String)
    case needsBrowser(String)
    var errorDescription: String? {
        switch self {
        case .rateLimited(let seconds): return "YouTube istek sınırı (HTTP 429). En az \(Int(ceil(min(seconds, Double(Int.max / 2))))) saniye bekle; tekrar tekrar deneme. Bu, hesabın olmadığı anlamına gelmez."
        case .http(let status): return "YouTube HTTP \(status) yanıtı verdi."
        case .forbidden: return "YouTube isteği reddetti (HTTP 403). Hesap gereksinimi, ağ veya otomatik istek kontrolü olabilir; nedeni bu yanıttan kesinleşmiyor."
        case .consent: return "YouTube onay sayfasına yönlendirdi. Aşağıdaki listede “Listeyi tarayıcıda aç / onayı kontrol et” düğmesini kullan; onayı kendin verip “Yüklenenleri oku” de. Safari oturumu uygulamaya otomatik aktarılmaz."
        case .unavailable: return "YouTube sayfasına erişilemedi. Bağlantını kontrol et."
        case .challenge: return "YouTube onay, oturum veya otomatik istek kontrolü istedi. Uygulama bu engeli aşmaz; bağlantıyı uygulama içi tarayıcıda açabilirsin."
        case .changed: return "Sayfadan video verisi okunamadı. Sayfa yapısı değişmiş, liste boş/gizli veya desteklenmeyen içerik olabilir."
        case .tooLarge: return "Sayfa güvenli işlem boyutu sınırını aştı."
        case .loginRequired(let detail): return detail
        case .needsBrowser(let detail): return detail
        }
    }
}

/// Anonymous page fetches cannot know what a logged-in browser sees. These signals only
/// classify *why* a page had no playable list so the message can point at a real next step.
enum YouTubePageSignal: String {
    case consent, botCheck, privateList, removed, membersOnly, unknown
    static func detect(_ html: String) -> YouTubePageSignal {
        let lower = html.lowercased()
        if lower.contains("consent.youtube.com") || lower.contains("before you continue to youtube")
            || lower.contains("onay vermeden önce youtube") || lower.contains("consent.youtube") { return .consent }
        if lower.contains("unusual traffic") || lower.contains("captcha") || lower.contains("not a bot")
            || lower.contains("otomatik olmayan istekler") { return .botCheck }
        if lower.contains("this playlist is private") || lower.contains("bu oynatma listesi gizli")
            || lower.contains("özel bir oynatma listesi") || lower.contains("private playlist") { return .privateList }
        if lower.contains("this playlist does not exist") || lower.contains("oynatma listesi mevcut değil")
            || lower.contains("playlist does not exist") { return .removed }
        if lower.contains("members-only") || lower.contains("üyelere özel") || lower.contains("members only") { return .membersOnly }
        return .unknown
    }
}

struct YouTubeFetchDiagnostics: Codable {
    var date = Date()
    var target: String
    var attempt: String
    var httpStatus: Int
    var bytes: Int
    var hadInitialData: Bool
    var hadPlayerResponse: Bool
    var cards: Int
    var signal: String
    var summary: String {
        "\(attempt) · HTTP \(httpStatus) · \(max(1, bytes / 1024)) KB · veri \(hadInitialData ? "var" : "yok") · kart \(cards) · \(signal)"
    }
}

enum YouTubeDiagnosticsLog {
    private static let key = "youtubeFetchDiagnostics"
    static func record(_ value: YouTubeFetchDiagnostics) {
        var entries = (UserDefaults.standard.array(forKey: key) as? [Data] ?? [])
        if let data = try? JSONEncoder().encode(value) { entries.append(data) }
        if entries.count > 6 { entries.removeFirst(entries.count - 6) }
        UserDefaults.standard.set(entries, forKey: key)
    }
    static func latest(_ count: Int = 2) -> String {
        let entries = (UserDefaults.standard.array(forKey: key) as? [Data] ?? []).suffix(max(0, count))
        let decoded = entries.compactMap { try? JSONDecoder().decode(YouTubeFetchDiagnostics.self, from: $0) }
        return decoded.map(\.summary).joined(separator: " | ")
    }
}

struct YouTubeContinuation {
    var token: String
    var endpoint: String
    var contextJSON: Data
}
struct WebVideoBatch {
    var videos: [SavedVideo]
    var hasMore: Bool
    var continuation: YouTubeContinuation? = nil
}
enum YouTubeHTML {
    // Match a script assignment, then balance braces while respecting JSON strings.
    static func object(in html: String, variable: String) -> [String: Any]? {
        let markers = ["var \(variable) =", "var \(variable)=", "window[\"\(variable)\"] =", "window[\"\(variable)\"]=", "\(variable) =", "\(variable)="]
        return assignedObject(in: html, markers: markers)
    }
    static func assignedObject(in html: String, markers: [String], requiredKey: String? = nil) -> [String: Any]? {
        for marker in markers {
            var cursor = html.startIndex
            while cursor < html.endIndex, let range = html.range(of: marker, range: cursor..<html.endIndex) {
                cursor = range.upperBound
                let tail = html[range.upperBound...].drop(while: { $0.isWhitespace })
                guard tail.first == "{" else { continue }
                var depth = 0, quoted = false, escape = false
                for i in tail.indices {
                    let c = tail[i]
                    if quoted {
                        if escape { escape = false }
                        else if c == "\\" { escape = true }
                        else if c == "\"" { quoted = false }
                    } else if c == "\"" { quoted = true }
                    else if c == "{" { depth += 1 }
                    else if c == "}" {
                        depth -= 1
                        if depth == 0 {
                            if let data = String(tail[...i]).data(using: .utf8),
                               let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                               requiredKey.map({ value[$0] != nil }) ?? true { return value }
                            break
                        }
                    }
                }
            }
        }
        return nil
    }
    static func continuationToken(in value: Any) -> String? {
        if let array = value as? [Any] { return array.compactMap { continuationToken(in: $0) }.first }
        guard let dict = value as? [String: Any] else { return nil }
        if let model = dict["continuationItemViewModel"] as? [String: Any],
           let outer = model["continuationCommand"] as? [String: Any],
           let inner = outer["innertubeCommand"] as? [String: Any],
           let command = inner["continuationCommand"] as? [String: Any], let token = command["token"] as? String { return token }
        if let renderer = dict["continuationItemRenderer"] as? [String: Any],
           let endpoint = renderer["continuationEndpoint"] as? [String: Any],
           let command = endpoint["continuationCommand"] as? [String: Any], let token = command["token"] as? String { return token }
        if dict["lockupViewModel"] != nil || dict["playlistVideoRenderer"] != nil || dict["videoRenderer"] != nil { return nil }
        for child in dict.values { if let token = continuationToken(in: child) { return token } }
        return nil
    }
    static func text(_ value: Any?) -> String {
        guard let data = value as? [String: Any] else { return "" }
        if let simple = data["simpleText"] as? String { return simple }
        if let content = data["content"] as? String { return content }
        return (data["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }
    static func videos(in root: [String: Any], playlistOnly: Bool = false) -> WebVideoBatch {
        var videos: [SavedVideo] = [], seen = Set<String>(), more = false
        let kinds = playlistOnly ? ["playlistVideoRenderer"] : ["videoRenderer", "compactVideoRenderer", "playlistVideoRenderer", "gridVideoRenderer"]
        func walk(_ value: Any) {
            if let array = value as? [Any] { array.forEach(walk); return }
            guard let dict = value as? [String: Any] else { return }
            if dict["continuationItemRenderer"] != nil || dict["continuationItemViewModel"] != nil { more = true }
            if let item = dict["lockupViewModel"] as? [String: Any],
               item["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO",
               let id = item["contentId"] as? String, MediaRules.youTubeID("https://youtu.be/\(id)") != nil {
                if seen.insert(id).inserted {
                    let metadata = (item["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any] ?? [:]
                    let title = text(metadata["title"])
                    let rows = ((metadata["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any])?["metadataRows"] as? [[String: Any]] ?? []
                    let parts = rows.first?["metadataParts"] as? [[String: Any]] ?? []
                    let channel = parts.map { text($0["text"]) }.joined(separator: " ")
                    videos.append(SavedVideo(id: id, title: title.isEmpty ? id : title, channel: channel))
                }
                return // Never parse action menus/recommendations inside this video card.
            }
            for kind in kinds {
                if let item = dict[kind] as? [String: Any], let id = item["videoId"] as? String,
                   MediaRules.youTubeID("https://youtu.be/\(id)") != nil, seen.insert(id).inserted {
                    let title = text(item["title"])
                    let channel = text(item["ownerText"] ?? item["shortBylineText"] ?? item["longBylineText"])
                    videos.append(SavedVideo(id: id, title: title.isEmpty ? "YouTube · \(id)" : title, channel: channel))
                    return
                }
            }
            // Dictionary branch ordering is unspecified; result arrays keep source order.
            for value in dict.values { walk(value) }
        }
        if playlistOnly {
            // Continuation responses can contain an empty contents AND the real cards in actions.
            walk(root["onResponseReceivedActions"] ?? root["onResponseReceivedEndpoints"] ?? root["contents"] ?? root)
        } else { walk(root) }
        return WebVideoBatch(videos: videos, hasMore: more)
    }
}
actor YouTubeWebClient {
    static let shared = YouTubeWebClient()
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    /// Consent cookies are what make an anonymous page fetch from the EU/TR land on the real
    /// page instead of the "Before you continue" interstitial that carries no list data.
    static func pageRequest(url: URL, mobile: Bool = false) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(mobile ? mobileUserAgent : desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("tr-TR,tr;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("SOCS=CAI; CONSENT=YES+cb.20210328-17-p0.en+FX+000; PREF=hl=tr&gl=TR", forHTTPHeaderField: "Cookie")
        return request
    }
    private struct FetchedPage {
        var html: String
        var status: Int
        var bytes: Int
    }
    private var cache: [String: (Date, WebVideoBatch)] = [:]
    private var cooldownUntil = UserDefaults.standard.object(forKey: "youtubeCooldownUntil") as? Date ?? Date.distantPast
    func checkCooldown() throws {
        let remaining = cooldownUntil.timeIntervalSinceNow
        if remaining > 0 { throw YouTubeWebError.rateLimited(remaining) }
    }
    func validate(_ response: HTTPURLResponse) throws {
        do { try YouTubeHTTP.validate(response) }
        catch YouTubeWebError.rateLimited(let delay) {
            cooldownUntil = Date().addingTimeInterval(delay + 1)
            UserDefaults.standard.set(cooldownUntil, forKey: "youtubeCooldownUntil")
            throw YouTubeWebError.rateLimited(delay)
        }
    }
    private func fetch(_ url: URL, mobile: Bool) async throws -> FetchedPage {
        try checkCooldown()
        let (data, response) = try await URLSession.shared.data(for: Self.pageRequest(url: url, mobile: mobile))
        guard let http = response as? HTTPURLResponse else { throw YouTubeWebError.unavailable }
        try validate(http)
        guard data.count < 12 * 1024 * 1024 else { throw YouTubeWebError.tooLarge }
        guard let html = String(data: data, encoding: .utf8) else { throw YouTubeWebError.changed }
        return FetchedPage(html: html, status: http.statusCode, bytes: data.count)
    }
    private func store(_ result: WebVideoBatch, for key: String) {
        if cache.count > 30 { cache.removeAll() }
        cache[key] = (Date(), result)
    }
    /// A playlist is tried as a desktop page and then as a mobile page: the two surfaces carry
    /// different renderers, and one can return cards while the other returns none.
    private func playlist(list: String) async throws -> WebVideoBatch {
        var lastSignal = YouTubePageSignal.unknown
        var lastStatus = 0, lastBytes = 0
        let attempts: [(String, String, Bool)] = [
            ("masaüstü", "https://www.youtube.com/playlist?list=\(list)&hl=tr", false),
            ("mobil", "https://m.youtube.com/playlist?list=\(list)&hl=tr", true)
        ]
        for (name, address, mobile) in attempts {
            guard let url = URL(string: address) else { continue }
            do {
                let page = try await fetch(url, mobile: mobile)
                lastStatus = page.status; lastBytes = page.bytes
                let signal = YouTubePageSignal.detect(page.html)
                guard let root = YouTubeHTML.object(in: page.html, variable: "ytInitialData") else {
                    lastSignal = signal
                    YouTubeDiagnosticsLog.record(YouTubeFetchDiagnostics(target: list, attempt: name, httpStatus: page.status, bytes: page.bytes, hadInitialData: false, hadPlayerResponse: false, cards: 0, signal: signal.rawValue))
                    continue
                }
                var result = YouTubeHTML.videos(in: root, playlistOnly: true)
                if result.videos.isEmpty { result = YouTubeHTML.videos(in: root) }
                attachContinuation(to: &result, root: root, html: page.html, endpoint: "browse")
                YouTubeDiagnosticsLog.record(YouTubeFetchDiagnostics(target: list, attempt: name, httpStatus: page.status, bytes: page.bytes, hadInitialData: true, hadPlayerResponse: false, cards: result.videos.count, signal: signal.rawValue))
                if result.videos.isEmpty { lastSignal = signal; continue }
                store(result, for: "playlist:\(list)")
                return result
            } catch let error as YouTubeWebError {
                switch error {
                case .rateLimited, .http, .forbidden, .unavailable, .tooLarge: throw error
                default:
                    lastSignal = .unknown
                    YouTubeDiagnosticsLog.record(YouTubeFetchDiagnostics(target: list, attempt: name, httpStatus: lastStatus, bytes: lastBytes, hadInitialData: false, hadPlayerResponse: false, cards: 0, signal: "istek hatası"))
                    continue
                }
            }
        }
        throw playlistFailure(lastSignal)
    }
    private func playlistFailure(_ signal: YouTubePageSignal) -> YouTubeWebError {
        let note = YouTubeDiagnosticsLog.latest(2)
        let tail = note.isEmpty ? "" : "\nTeşhis: " + note
        let browser = " Uygulama içi tarayıcıda açıp giriş/onay yaptıktan sonra “Yüklenenleri oku” de."
        switch signal {
        case .consent: return .consent
        case .botCheck: return .challenge
        case .privateList: return .loginRequired("Liste gizli veya özel görünüyor; anonim istekle okunamıyor." + browser + tail)
        case .removed: return .loginRequired("Liste kaldırılmış ya da bu bölgede erişilemiyor." + browser + tail)
        case .membersOnly: return .loginRequired("Liste yalnızca üyelere açık görünüyor; anonim istekle okunamıyor." + browser + tail)
        case .unknown: return .needsBrowser("Liste sayfası açıldı ama kayıtlar okunamadı (giriş, bölge veya sayfa düzeni olabilir)." + browser + tail)
        }
    }
    private func attachContinuation(to result: inout WebVideoBatch, root: [String: Any], html: String, endpoint: String) {
        guard let token = YouTubeHTML.continuationToken(in: root["contents"] ?? root),
              let config = YouTubeHTML.assignedObject(in: html, markers: ["ytcfg.set("], requiredKey: "INNERTUBE_CONTEXT"),
              let context = config["INNERTUBE_CONTEXT"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: context) else { return }
        result.continuation = YouTubeContinuation(token: token, endpoint: endpoint, contextJSON: data)
    }
    func load(_ raw: String) async throws -> WebVideoBatch {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var components: URLComponents
        var playlistID: String?
        var directVideoID: String?
        if let url = URL(string: input), let host = url.host?.lowercased(), host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") {
            let list = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "list" }?.value
            if let list, !list.isEmpty, list.count < 256, list.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
                playlistID = list
                components = URLComponents(string: "https://www.youtube.com/playlist")!
                components.queryItems = [URLQueryItem(name: "list", value: list)]
            } else if let id = MediaRules.youTubeID(input) {
                directVideoID = id
                components = URLComponents(string: "https://www.youtube.com/watch")!
                components.queryItems = [URLQueryItem(name: "v", value: id)]
            } else { throw YouTubeWebError.changed }
        } else {
            components = URLComponents(string: "https://www.youtube.com/results")!
            components.queryItems = [URLQueryItem(name: "search_query", value: input)]
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "hl", value: "tr")]
        guard let url = components.url else { throw YouTubeWebError.changed }
        if let (date, result) = cache[url.absoluteString], Date().timeIntervalSince(date) < 300 { return result }
        if let playlistID {
            if let (date, result) = cache["playlist:\(playlistID)"], Date().timeIntervalSince(date) < 300 { return result }
            return try await playlist(list: playlistID)
        }
        let page = try await fetch(url, mobile: false)
        if let id = directVideoID {
            guard let player = YouTubeHTML.object(in: page.html, variable: "ytInitialPlayerResponse"),
                  let detail = player["videoDetails"] as? [String: Any], detail["videoId"] as? String == id else {
                let signal = YouTubePageSignal.detect(page.html)
                throw (signal == .consent ? YouTubeWebError.consent : YouTubeWebError.changed)
            }
            let result = WebVideoBatch(videos: [SavedVideo(id: id, title: detail["title"] as? String ?? id, channel: detail["author"] as? String ?? "")], hasMore: false)
            store(result, for: url.absoluteString)
            return result
        }
        guard let root = YouTubeHTML.object(in: page.html, variable: "ytInitialData") else {
            let signal = YouTubePageSignal.detect(page.html)
            YouTubeDiagnosticsLog.record(YouTubeFetchDiagnostics(target: input, attempt: "arama", httpStatus: page.status, bytes: page.bytes, hadInitialData: false, hadPlayerResponse: false, cards: 0, signal: signal.rawValue))
            switch signal {
            case .consent: throw YouTubeWebError.consent
            case .botCheck: throw YouTubeWebError.challenge
            default: throw YouTubeWebError.changed
            }
        }
        var result = YouTubeHTML.videos(in: root, playlistOnly: false)
        attachContinuation(to: &result, root: root, html: page.html, endpoint: "search")
        YouTubeDiagnosticsLog.record(YouTubeFetchDiagnostics(target: input, attempt: "arama", httpStatus: page.status, bytes: page.bytes, hadInitialData: true, hadPlayerResponse: false, cards: result.videos.count, signal: YouTubePageSignal.detect(page.html).rawValue))
        guard !result.videos.isEmpty else { throw YouTubeWebError.changed }
        store(result, for: url.absoluteString)
        return result
    }
    func nextPage(_ continuation: YouTubeContinuation) async throws -> WebVideoBatch {
        guard ["browse", "search"].contains(continuation.endpoint), continuation.token.count < 100_000 else { throw YouTubeWebError.changed }
        try checkCooldown()
        let context = try JSONSerialization.jsonObject(with: continuation.contextJSON)
        guard let address = URL(string: "https://www.youtube.com/youtubei/v1/\(continuation.endpoint)") else { throw YouTubeWebError.changed }
        var request = URLRequest(url: address, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("SOCS=CAI; CONSENT=YES+cb", forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["context": context, "continuation": continuation.token])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw YouTubeWebError.unavailable }
        try validate(http)
        guard data.count < 12 * 1024 * 1024 else { throw YouTubeWebError.tooLarge }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw YouTubeWebError.changed }
        var result = YouTubeHTML.videos(in: root, playlistOnly: continuation.endpoint == "browse")
        let scope = root["onResponseReceivedActions"] ?? root["onResponseReceivedEndpoints"] ?? root["contents"] ?? root
        if let token = YouTubeHTML.continuationToken(in: scope) {
            result.continuation = YouTubeContinuation(token: token, endpoint: continuation.endpoint, contextJSON: continuation.contextJSON)
        }
        if result.videos.isEmpty, result.continuation != nil { throw YouTubeWebError.changed }
        return result
    }
}
