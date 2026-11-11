import AVFoundation

// AVFoundation processes only local files; no account, token or DRM bypass.
enum MediaProcessor {
    private static func reserve(for inputs: [URL], output: URL) throws {
        let bytes = try inputs.reduce(Int64(0)) { partial, url in partial + (try DiskFile.size(url)) }
        let available = try output.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let available, available < bytes + 100 * 1024 * 1024 { throw YouTubeMediaError.unavailable("İşleme çıktısı için yeterli boş alan yok.") }
    }
    private static func export(_ asset: AVAsset, preset: String, type: AVFileType, to output: URL) async throws {
        try Task.checkCancellation()
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw YouTubeMediaError.unavailable("Bu medya için dışa aktarıcı oluşturulamadı.")
        }
        guard exporter.supportedFileTypes.contains(type) else {
            throw YouTubeMediaError.unavailable("Bu kaynak seçilen çıktı kapsayıcısına aktarılamıyor; uyumlu MP4/M4A kaynak gerekiyor.")
        }
        exporter.outputURL = output; exporter.outputFileType = type; exporter.shouldOptimizeForNetworkUse = false
        do {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    exporter.exportAsynchronously {
                        if exporter.status == .completed { continuation.resume() }
                        else { continuation.resume(throwing: exporter.error ?? CancellationError()) }
                    }
                }
            }, onCancel: { exporter.cancelExport() })
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
    static func merge(video: URL, audio: URL, output: URL) async throws {
        try reserve(for: [video, audio], output: output)
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw YouTubeMediaError.unavailable("Birleştirme için gerekli ses/video izi yok.")
        }
        let vd = try await videoAsset.load(.duration), ad = try await audioAsset.load(.duration)
        let duration = CMTimeMinimum(vd, ad)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw YouTubeMediaError.unavailable("Geçersiz medya süresi.") }
        let composition = AVMutableComposition()
        guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw YouTubeWebError.changed }
        let range = CMTimeRange(start: .zero, duration: duration)
        try v.insertTimeRange(range, of: videoTrack, at: .zero)
        try a.insertTimeRange(range, of: audioTrack, at: .zero)
        v.preferredTransform = try await videoTrack.load(.preferredTransform)
        try await export(composition, preset: AVAssetExportPresetPassthrough, type: .mp4, to: output)
        let result = AVURLAsset(url: output)
        let videoResult = try await result.loadTracks(withMediaType: .video)
        let audioResult = try await result.loadTracks(withMediaType: .audio)
        guard !videoResult.isEmpty, !audioResult.isEmpty else { throw YouTubeMediaError.unavailable("Çıktıda ses veya video izi eksik; arşive alınmadı.") }
    }
    static func extractAudio(from source: URL, to output: URL) async throws {
        try reserve(for: [source], output: output)
        let asset = AVURLAsset(url: source)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw YouTubeMediaError.unavailable("Dosyada ses izi bulunamadı.")
        }
        try await export(asset, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: output)
        let result = AVURLAsset(url: output)
        guard !(try await result.loadTracks(withMediaType: .audio)).isEmpty else { throw YouTubeMediaError.unavailable("Ses çıktısı doğrulanamadı.") }
    }
}

extension MediaProcessor {
    static func remuxVideo(from source: URL, to output: URL) async throws {
        try reserve(for: [source], output: output)
        let asset = AVURLAsset(url: source)
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw YouTubeMediaError.unavailable("Okunabilir video izi yok; eksik/bozuk dosya yeniden indirilmeli.") }
        do { try await export(asset, preset: AVAssetExportPresetPassthrough, type: .mp4, to: output) }
        catch {
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: output)
            try await export(asset, preset: AVAssetExportPresetHighestQuality, type: .mp4, to: output)
        }
        _ = try await MediaInspector.inspect(output)
    }
}
