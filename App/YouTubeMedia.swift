import SwiftUI

struct YouTubeMediaFormat: Identifiable {
    let id: Int
    let url: URL
    let label: String
    let ext: String
    let audioOnly: Bool
    var companionAudioURL: URL? = nil
    var height: Int = 0
    var bitrate: Int = 0
    var availableAt: Date? = nil
    var sourceVideoID: String? = nil
    var contentLength: Int64? = nil
    var audioContentLength: Int64? = nil
    var details: TrackDetails? = nil
}
struct YouTubeMediaOptions {
    var formats: [YouTubeMediaFormat]
    var unsupported: Int
    var title: String? = nil
}
enum YouTubeMediaError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let reason) = self { return reason }; return nil }
}
enum YouTubeMediaParser {
    static func parse(_ root: [String: Any]) throws -> YouTubeMediaOptions {
        if let status = root["playabilityStatus"] as? [String: Any], let value = status["status"] as? String, value != "OK" {
            throw YouTubeMediaError.unavailable(status["reason"] as? String ?? "Bu içerik oturum veya farklı erişim gerektiriyor.")
        }
        guard let streams = root["streamingData"] as? [String: Any] else {
            throw YouTubeMediaError.unavailable("Video bilgisi bulundu ama medya akışları verilmedi. Bu sürüm oturum, oynatıcı doğrulaması veya kısıt aşma yapmaz.")
        }
        let compatibility = UserDefaults.standard.object(forKey: "compatibilityMode") as? Bool ?? true
        func compatible(_ format: [String: Any]) -> Bool {
            guard compatibility else { return true }
            let mime = (format["mimeType"] as? String ?? "").lowercased()
            if mime.hasPrefix("audio/mp4") { return mime.contains("mp4a") }
            if mime.hasPrefix("video/mp4") { return (mime.contains("avc1") || mime.contains("mp4v")) && (!mime.contains(",") || mime.contains("mp4a")) }
            return false
        }
        let muxed = (streams["formats"] as? [[String: Any]] ?? []).filter(compatible)
        let adaptive = (streams["adaptiveFormats"] as? [[String: Any]] ?? []).filter(compatible)
        func direct(_ format: [String: Any]) -> URL? {
            guard format["drmFamilies"] == nil, format["signatureCipher"] == nil, format["cipher"] == nil,
                  let raw = format["url"] as? String, let url = URL(string: raw), url.scheme == "https",
                  let host = url.host?.lowercased(), host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") else { return nil }
            return url
        }
        let audio = adaptive.filter { ($0["mimeType"] as? String ?? "").hasPrefix("audio/mp4") && direct($0) != nil }.sorted { ($0["bitrate"] as? Int ?? 0) > ($1["bitrate"] as? Int ?? 0) }.first
        let companion = audio.flatMap(direct)
        var result: [YouTubeMediaFormat] = [], unsupported = 0, ids = Set<Int>()
        let muxedIDs = Set(muxed.compactMap { $0["itag"] as? Int })
        for format in muxed + adaptive {
            let mime = format["mimeType"] as? String ?? ""
            let audioOnly = mime.hasPrefix("audio/")
            guard mime.hasPrefix("video/mp4") || mime.hasPrefix("audio/mp4"),
                  let url = direct(format), let id = format["itag"] as? Int else { unsupported += 1; continue }
            let needsMerge = !audioOnly && !muxedIDs.contains(id)
            if needsMerge && companion == nil { unsupported += 1; continue }
            guard ids.insert(id).inserted else { continue }
            let bitrate = (format["bitrate"] as? Int ?? 0) / 1000
            let quality = format["qualityLabel"] as? String ?? "MP4"
            let suffix = needsMerge ? " · sesle birleştir" : ""
            var parsed = YouTubeMediaFormat(id: id, url: url, label: audioOnly ? "Ses · M4A · \(bitrate) kbps" : "Video · \(quality) · MP4" + suffix, ext: audioOnly ? "m4a" : "mp4", audioOnly: audioOnly, companionAudioURL: needsMerge ? companion : nil)
            parsed.height = format["height"] as? Int ?? 0
            parsed.bitrate = format["bitrate"] as? Int ?? 0
            parsed.contentLength = (format["contentLength"] as? String).flatMap { Int64($0) }
            if needsMerge { parsed.audioContentLength = (audio?["contentLength"] as? String).flatMap { Int64($0) } }
            result.append(parsed)
        }
        guard !result.isEmpty else {
            throw YouTubeMediaError.unavailable("Doğrudan indirilebilir MP4/M4A akışı bulunamadı. Şifreli imza çözümü ve oynatıcı doğrulaması bu sürümde yok. Videonun aramada bulunması indirilebileceği anlamına gelmez.")
        }
        return YouTubeMediaOptions(formats: result, unsupported: unsupported)
    }
}
extension YouTubeWebClient {
    func mediaOptions(for videoID: String) async throws -> YouTubeMediaOptions {
        guard MediaRules.youTubeID("https://youtu.be/\(videoID)") != nil else { throw YouTubeWebError.changed }
        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: videoID), URLQueryItem(name: "hl", value: "tr")]
        guard let watchURL = components.url else { throw YouTubeWebError.changed }
        let request = YouTubeWebClient.pageRequest(url: watchURL)
        try checkCooldown()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw YouTubeWebError.unavailable }
        try validate(http)
        guard data.count < 12 * 1024 * 1024 else { throw YouTubeWebError.tooLarge }
        guard let html = String(data: data, encoding: .utf8) else { throw YouTubeWebError.changed }
        guard let root = YouTubeHTML.object(in: html, variable: "ytInitialPlayerResponse") else {
            switch YouTubePageSignal.detect(html) {
            case .consent: throw YouTubeWebError.consent
            case .botCheck: throw YouTubeWebError.challenge
            case .privateList, .removed, .membersOnly: throw YouTubeWebError.loginRequired("Bu video anonim istekle açılamıyor (gizli, kaldırılmış veya üyelere özel olabilir). Uygulama içi tarayıcıdan kontrol edebilirsin.")
            case .unknown: throw YouTubeWebError.changed
            }
        }
        // Check public page status before invoking the local player engine.
        if let status = root["playabilityStatus"] as? [String: Any], let value = status["status"] as? String, value != "OK" {
            throw YouTubeMediaError.unavailable(status["reason"] as? String ?? "İçerik erişim kısıtlı; işlem yapılmadı.")
        }
        let info = root["videoDetails"] as? [String: Any] ?? [:]
        let details = TrackDetails(videoID: videoID, title: info["title"] as? String ?? videoID, channel: info["author"] as? String ?? "")
        func enrich(_ value: YouTubeMediaOptions) -> YouTubeMediaOptions {
            var result = value; result.title = details.title
            for index in result.formats.indices {
                result.formats[index].sourceVideoID = videoID
                result.formats[index].details = details
            }
            return result
        }
        do {
            return enrich(try await LocalStreamExtractor.options(videoID: videoID))
        }
        catch {
            try Task.checkCancellation()
            let engineError = error.localizedDescription
            do {
                return enrich(try YouTubeMediaParser.parse(root))
            } catch { throw YouTubeMediaError.unavailable("Yerel çıkarma başarısız: " + engineError + "\nDoğrudan akış da bulunamadı. Motor güncellemesi gerekebilir; bu hatayı paylaşabilirsin.") }
        }
    }
}
struct MediaDownloadSheet: View {
    let video: SavedVideo
    var onQueued: () -> Void = {}
    @Environment(\.dismiss) var dismiss
    @State private var options: YouTubeMediaOptions?
    @State private var loading = true
    @State private var message: String?
    @State private var failure: String?
    @State private var added = false
    var body: some View {
        NavigationStack {
            List {
                Section { Text(video.title).font(.headline); Text(video.channel).foregroundStyle(.secondary) }
                Section {
                    Text("Yalnızca cihazla uyumlu MP4/M4A sunulur. Yerel motor telefonda çalışır; uzak çözümleme servisi yoktur. Kaliteler YouTube'un verdiği akışlara bağlıdır. İndirme adresi süreli olabilir; hata olursa yeniden sorgula.").font(.caption).foregroundStyle(.secondary)
                }
                if loading { ProgressView("Medya biçimleri sorgulanıyor…") }
                if let failure { Section("İndirilemiyor") { Text(failure).foregroundStyle(.orange) } }
                if let options {
                    Section("Kullanılabilir biçimler") {
                        ForEach(options.formats) { format in
                            Button {
                                added = DownloadCenter.shared.enqueueResolved(format, title: video.title)
                                if added { onQueued(); dismiss() }
                                message = added ? "İndirme kuyruğuna eklendi. İndirmeler sekmesinden izle. Tamamlandıktan sonra Arşiv’de görünür." : "Bu biçim kuyruğa eklenemedi."
                            } label: { Label(format.label, systemImage: format.audioOnly ? "music.note" : "film") }
                            .disabled(added)
                        }
                    }
                    if options.unsupported > 0 { Text("\(options.unsupported) biçim desteklenmediği için gösterilmedi.").font(.caption) }
                }
                if let message { Text(message).foregroundStyle(.mint) }
                Link("YouTube’da aç", destination: video.url)
            }.navigationTitle("İndir")
            .toolbar { Button("Kapat") { dismiss() } }
            .task {
                do { options = try await YouTubeWebClient.shared.mediaOptions(for: video.id) }
                catch { failure = error.localizedDescription }
                loading = false
            }
        }
    }
}

struct BulkMediaSheet: View {
    let videos: [SavedVideo]
    var warning: String? = nil
    @EnvironmentObject var flow: ImportFlow
    @Environment(\.dismiss) var dismiss
    @State private var selection = Set<String>()
    @State private var pending: [SavedVideo] = []
    @State private var askType = false
    var onQueued: () -> Void = {}
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Yüklenen \(videos.count) kayıt. Henüz yüklenmemiş liste sayfaları dahil değildir.").font(.caption)
                    if let warning { Text(warning).font(.caption).foregroundStyle(.orange) }
                    if let error = flow.message { Text(error).font(.caption).foregroundStyle(.orange) }
                    Text("İndir düğmesine basınca Müzik veya Video seçimi sorulur.").font(.caption)
                    HStack { Button("Tümünü seç") { selection = Set(videos.map(\.id)) }; Spacer(); Button("Seçimi temizle") { selection.removeAll() } }.buttonStyle(.borderless)
                    Button("Tümünü indir (\(videos.count))") { request(videos) }.disabled(videos.isEmpty)
                    Button("Seçileni indir (\(selection.count))") { request(videos.filter { selection.contains($0.id) }) }.disabled(selection.isEmpty)
                }
                Section("Seçilebilir kayıtlar") {
                    ForEach(videos) { video in
                        Button {
                            if !selection.insert(video.id).inserted { selection.remove(video.id) }
                        } label: {
                            HStack { Image(systemName: selection.contains(video.id) ? "checkmark.circle.fill" : "circle"); Text(video.title).foregroundStyle(.primary) }
                        }
                    }
                }
            }.navigationTitle("Oynatma listesi")
            .toolbar { Button("Kapat") { dismiss() } }
            .confirmationDialog("Seçilen \(pending.count) kayıt nasıl indirilsin?", isPresented: $askType, titleVisibility: .visible) {
                Button("Müzik · M4A ses") { queue(pending, audioOnly: true) }
                Button("Video · MP4") { queue(pending, audioOnly: false) }
                Button("Vazgeç", role: .cancel) { pending = [] }
            }
        }
    }
    private func request(_ selected: [SavedVideo]) { pending = selected; askType = !selected.isEmpty }
    private func queue(_ selected: [SavedVideo], audioOnly: Bool) {
        if flow.enqueue(selected, audioOnly: audioOnly) { onQueued(); dismiss() }
    }
}
