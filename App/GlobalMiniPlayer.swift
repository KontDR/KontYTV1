import SwiftUI

extension Notification.Name { static let kontytShowPlayer = Notification.Name("KontYT.ShowPlayer") }
struct GlobalMiniPlayer: ViewModifier {
    @EnvironmentObject var library: Library
    let onOpen: () -> Void
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if let current = library.current {
                HStack(spacing: 10) {
                    // Önceki parça
                    Button { library.previous() } label: {
                        Image(systemName: "backward.end.fill").frame(width: 30, height: 44)
                    }.accessibilityLabel("Önceki")

                    // Sanat ve başlık
                    Button(action: onOpen) {
                        HStack(spacing: 8) {
                            TrackArtwork(item: current).frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(current.name).font(.subheadline.bold()).lineLimit(1)
                                Text(current.channel ?? "YouTube").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.foregroundStyle(.primary)
                    }.buttonStyle(.plain)

                    Spacer(minLength: 0)

                    // Oynat / Duraklat
                    Button { library.playing ? library.pause() : library.resume() } label: {
                        Image(systemName: library.playing ? "pause.fill" : "play.fill").frame(width: 35, height: 44)
                    }.accessibilityLabel(library.playing ? "Duraklat" : "Oynat")

                    // Sonraki parça
                    Button { library.next() } label: {
                        Image(systemName: "forward.end.fill").frame(width: 30, height: 44)
                    }.accessibilityLabel("Sonraki")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
        }
    }
}

struct TrackArtwork: View {
    @EnvironmentObject var library: Library
    let item: MediaItem
    var body: some View {
        Group {
            if let image = library.artwork(for: item) { Image(uiImage: image).resizable().scaledToFit() }
            else { Image("BrandMark").resizable().scaledToFit() }
        }
    }
}
