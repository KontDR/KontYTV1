import Foundation
import AVFoundation

struct InspectedMedia {
    let hasVideo: Bool
    let hasAudio: Bool
    let duration: Double
}
enum MediaInspector {
    static func inspect(_ url: URL) async throws -> InspectedMedia {
        let bytes = try DiskFile.size(url)
        guard bytes > 0 else { throw YouTubeMediaError.unavailable("İndirilen dosya boş. Yeniden indirmeyi dene.") }
        let handle = try FileHandle(forReadingFrom: url)
        let head = try handle.read(upToCount: 512) ?? Data(); try handle.close()
        if let text = String(data: head, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), text.hasPrefix("<!doctype html") || text.hasPrefix("<html") || text.hasPrefix("{\"error\"") {
            throw YouTubeMediaError.unavailable("Sunucu medya yerine hata/HTML sayfası gönderdi. Adresi yenileyip yeniden indir.")
        }
        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isPlayable)
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            guard playable, !video.isEmpty || !audio.isEmpty, duration.seconds.isFinite, duration.seconds > 0 else {
                throw YouTubeMediaError.unavailable("Medya doğrulanamadı (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))). Dosya eksik, bozuk veya codec uyumsuz olabilir. Sağlam kaynak varsa yeniden paketleme/indirme gerekir.")
            }
            return InspectedMedia(hasVideo: !video.isEmpty, hasAudio: !audio.isEmpty, duration: duration.seconds)
        } catch let error as YouTubeMediaError { throw error }
        catch {
            let ns = error as NSError
            throw YouTubeMediaError.unavailable("Medya okunamadı: \(ns.localizedDescription) [\(ns.domain):\(ns.code)]. Dosya silinmedi; indirme geçmişinden yeniden doğrulanabilir.")
        }
    }
}
