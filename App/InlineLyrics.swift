import SwiftUI

@MainActor final class InlineLyricsModel: ObservableObject {
    @Published var lines: [LyricLine] = []
    @Published var note = "Sözleri aç"
    @Published var offset: Double = 0
    private var generation = UUID()
    func cached(_ item: MediaItem) -> Bool {
        offset = UserDefaults.standard.double(forKey: "lyricsOffset." + item.id.uuidString)
        guard let record = LyricsCache.load(item.id) else { return false }
        lines = LRCParser.parse(record.syncedLyrics ?? "")
        note = record.instrumental ? "Enstrümantal" : (lines.isEmpty ? "Senkron kayıt yok · düz sözleri aç" : "")
        return true
    }
    func load(_ item: MediaItem) async {
        let token = UUID(); generation = token; lines = []
        if cached(item) { return }
        guard UserDefaults.standard.object(forKey: "autoLyrics") as? Bool ?? true else { note = "Söz aramak için dokun"; return }
        note = "Sözler aranıyor…"
        let guess = SongIdentity.guess(item.name)
        do {
            let records = try await LyricsClient.shared.search(title: guess.title, artist: guess.artist)
            try Task.checkCancellation()
            guard generation == token else { return }
            let matches = records.filter { SongIdentity.confident($0, artist: guess.artist, title: guess.title, duration: item.duration) }
            guard matches.count == 1, let record = matches.first else {
                note = "Doğru söz kaydını seçmek için dokun"; return
            }
            try LyricsCache.save(record, id: item.id)
            _ = cached(item)
        } catch is CancellationError { }
        catch { if generation == token { note = "Sözler hazır değil · seçmek/yeniden denemek için dokun" } }
    }
}
struct InlineLyrics: View {
    let item: MediaItem
    let onOpen: () -> Void
    @EnvironmentObject var library: Library
    @StateObject private var model = InlineLyricsModel()
    private var activeID: Int? {
        model.lines.last(where: { $0.seconds <= library.elapsed + model.offset })?.id
    }
    private var window: [LyricLine] {
        guard !model.lines.isEmpty else { return [] }
        let index = model.lines.lastIndex(where: { $0.seconds <= library.elapsed + model.offset }) ?? 0
        let start = max(0, min(index - 1, model.lines.count - 3))
        return Array(model.lines.dropFirst(start).prefix(3))
    }
    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 5) {
                if model.lines.isEmpty {
                    Image(systemName: "text.quote").font(.caption)
                    Text(model.note).font(.caption).lineLimit(2)
                } else {
                    ForEach(window) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(line.id == activeID ? .subheadline.bold() : .caption)
                            .foregroundStyle(line.id == activeID ? Color.mint : Color.secondary)
                            .lineLimit(2).multilineTextAlignment(.center)
                    }
                }
            }.frame(maxWidth: .infinity)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel("Şarkı sözlerini aç")
            .task(id: item.id) { await model.load(item) }
            .onReceive(NotificationCenter.default.publisher(for: .kontytLyricsChanged).receive(on: DispatchQueue.main)) { note in
                if let id = note.object as? UUID, id == item.id { _ = model.cached(item) }
            }
    }
}
