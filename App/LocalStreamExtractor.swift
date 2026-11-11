import Foundation
import YouTubeKit

enum LocalStreamExtractor {
    static func options(videoID: String) async throws -> YouTubeMediaOptions {
        let video = YouTube(videoID: videoID, useOAuth: false, allowOAuthCache: false, methods: [.local])
        let ageRestricted = try await video.ageRestricted
        if ageRestricted {
            throw YouTubeMediaError.unavailable("Yaş veya oturum kısıtlı içerik bu uygulamada işlenmez.")
        }
        let streams = try await video.streams
        let compatibility = UserDefaults.standard.object(forKey: "compatibilityMode") as? Bool ?? true
        let playable = streams.filter { stream in
            guard stream.isNativelyPlayable, stream.fileExtension == .mp4 || stream.fileExtension == .m4a else { return false }
            if !compatibility { return true }
            return (!stream.includesVideoTrack || stream.videoCodec == VideoCodec.BaseCodec.avc1 || stream.videoCodec == VideoCodec.BaseCodec.mp4v) && (!stream.includesAudioTrack || stream.audioCodec == AudioCodec.BaseCodec.mp4a)
        }
        let audio = playable.filter { $0.includesAudioTrack && !$0.includesVideoTrack }.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first
        var result: [YouTubeMediaFormat] = []
        for (index, stream) in playable.enumerated() {
            let audioOnly = stream.includesAudioTrack && !stream.includesVideoTrack
            let needsMerge = stream.includesVideoTrack && !stream.includesAudioTrack
            if needsMerge && audio == nil { continue }
            guard stream.includesAudioTrack || stream.includesVideoTrack else { continue }
            let rawTag = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "itag" })?.value
            let tag = rawTag.flatMap { Int($0) } ?? (100000 + index)
            let bitrate = stream.bitrate ?? 0
            let height = stream.videoResolution ?? 0
            let label = audioOnly ? "Ses · M4A · \(bitrate / 1000) kbps" : "Video · \(height)p · MP4" + (needsMerge ? " · sesle birleştir" : "")
            var format = YouTubeMediaFormat(id: tag, url: stream.url, label: label, ext: audioOnly ? "m4a" : "mp4", audioOnly: audioOnly, companionAudioURL: needsMerge ? audio?.url : nil)
            let rawLength = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "clen" })?.value
            format.contentLength = rawLength.flatMap { Int64($0) }
            if needsMerge, let audio {
                let audioLength = URLComponents(url: audio.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "clen" })?.value
                format.audioContentLength = audioLength.flatMap { Int64($0) }
            }
            format.height = height; format.bitrate = bitrate; format.sourceVideoID = videoID
            format.availableAt = needsMerge ? max(stream.availableAt, audio?.availableAt ?? stream.availableAt) : stream.availableAt
            result.append(format)
        }
        guard !result.isEmpty else { throw YouTubeMediaError.unavailable("Yerel motor cihazla uyumlu MP4/M4A biçimi çıkaramadı. Canlı/HLS ve erişim kısıtlı içerik desteklenmiyor.") }
        result.sort { lhs, rhs in lhs.audioOnly == rhs.audioOnly ? (lhs.audioOnly ? lhs.bitrate > rhs.bitrate : lhs.height > rhs.height) : !lhs.audioOnly }
        return YouTubeMediaOptions(formats: result, unsupported: max(0, streams.count - result.count))
    }
}
