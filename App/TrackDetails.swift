import Foundation
import UIKit

struct TrackDetails: Codable {
    let videoID: String
    let title: String
    let channel: String
}
enum ArtworkStore {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Artwork", isDirectory: true)
    }
    static func url(_ filename: String) -> URL { folder.appendingPathComponent(filename) }
    @MainActor static func download(videoID: String, identifier: UUID) async throws -> String {
        guard MediaRules.youTubeID("https://youtu.be/\(videoID)") == videoID else { throw YouTubeWebError.changed }
        let request = URLRequest(url: URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")!, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2 * 1024 * 1024,
              let image = UIImage(data: data), image.size.width > 0, image.size.height > 0,
              image.size.width <= 4096, image.size.height <= 4096 else { throw URLError(.cannotDecodeContentData) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = identifier.uuidString + ".jpg"
        guard let jpeg = image.jpegData(compressionQuality: 0.88) else { throw URLError(.cannotDecodeContentData) }
        try jpeg.write(to: url(name), options: .atomic)
        return name
    }
}
