import SwiftUI
import AVFoundation
import UIKit

/// Thumbnails for the archive.
///
/// Videos get a real frame grabbed from the local file (once, then cached on disk), audio files
/// fall back to their artwork. Nothing here touches the network: the archive is offline first.
enum ThumbnailStore {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbs", isDirectory: true)
    }
    static func cacheURL(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".jpg") }
    static func cached(_ id: UUID) -> UIImage? { UIImage(contentsOfFile: cacheURL(id).path) }

    @MainActor
    static func load(item: MediaItem, file: URL) async -> UIImage? {
        if let cached = cached(item.id) { return cached }
        guard item.isVideo, FileManager.default.fileExists(atPath: file.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let seconds = max(0.1, min(3, (item.duration ?? 2) * 0.1))
        guard let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)),
              let data = UIImage(cgImage: frame.image).jpegData(compressionQuality: 0.82) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: cacheURL(item.id), options: .atomic)
        return UIImage(data: data)
    }

    static func clear() { try? FileManager.default.removeItem(at: folder) }
}

struct MediaThumbnail: View {
    let item: MediaItem
    @EnvironmentObject var library: Library
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.mint.opacity(0.10))
            content
        }
        .frame(width: 58, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: item.id) {
            guard item.isVideo else { return }
            image = await ThumbnailStore.load(item: item, file: library.file(item))
        }
    }
    @ViewBuilder private var content: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else if !item.isVideo, let artwork = library.artwork(for: item) {
            Image(uiImage: artwork).resizable().scaledToFill()
        } else {
            Image(systemName: item.isVideo ? "film.fill" : "music.note").foregroundStyle(.mint)
        }
    }
}

/// Remote thumbnail for YouTube results (search, playlist rows, browser import).
struct RemoteThumbnail: View {
    let videoID: String?
    var width: CGFloat = 64
    var height: CGFloat = 48
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.mint.opacity(0.10))
            if let url = url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "play.rectangle").foregroundStyle(.mint)
                    }
                }
            } else {
                Image(systemName: "play.rectangle").foregroundStyle(.mint)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private var url: URL? {
        guard let videoID, videoID.count == 11 else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")
    }
}
