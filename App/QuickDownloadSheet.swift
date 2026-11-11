import SwiftUI

struct QuickDownloadSheet: View {
    let video: SavedVideo
    var onQueued: () -> Void
    @EnvironmentObject var flow: ImportFlow
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 56)).foregroundStyle(.mint)
                Text(video.title).font(.headline).multilineTextAlignment(.center)
                Text("Bu bağlantı nasıl indirilsin?").font(.title3.bold())
                Button { queue(audio: true) } label: { Label("Müzik · M4A ses", systemImage: "music.note").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                Button { queue(audio: false) } label: { Label("Video · MP4", systemImage: "film").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                Text("Kalite sınırı Ayarlar'dan uygulanır. Dönüştürme gerektiren biçimler cihazda işlenir.").font(.caption).foregroundStyle(.secondary)
                if let message = flow.message { Text(message).font(.caption).foregroundStyle(.orange) }
            }.padding(28).navigationTitle("İndirme türü")
                .toolbar { Button("Vazgeç") { dismiss() } }
        }.presentationDetents([.medium, .large])
    }
    private func queue(audio: Bool) {
        if flow.enqueue([video], audioOnly: audio) { onQueued(); dismiss() }
    }
}
