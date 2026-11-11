import SwiftUI

struct LyricsView: View {
    let item: MediaItem
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("autoLyrics") private var autoLyrics = true
    @State private var title = ""
    @State private var artist = ""
    @State private var loading = false
    @State private var message: String?
    @State private var results: [LyricsRecord] = []
    @State private var selected: LyricsRecord?
    @State private var lines: [LyricLine] = []
    @State private var offset: Double = 0
    @State private var follow = true
    var activeLine: Int? {
        guard library.current?.id == item.id else { return nil }
        return lines.last(where: { $0.seconds <= library.elapsed + offset })?.id
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                matchPanel
                if loading { ProgressView("Sözler aranıyor…") }
                if let message { Text(message).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
                resultsPanel
                selectedPanel
                Link("Söz kaynağı: LRCLIB", destination: URL(string: "https://lrclib.net")!).font(.caption)
            }.navigationTitle("Şarkı sözleri").toolbar { Button("Kapat") { dismiss() } }
        }.task(id: item.id) {
            let guess = SongIdentity.guess(item.name); title = guess.title; artist = guess.artist
            offset = UserDefaults.standard.double(forKey: "lyricsOffset." + item.id.uuidString)
            if let cached = LyricsCache.load(item.id) { selected = cached; lines = LRCParser.parse(cached.syncedLyrics ?? "") }
            else if autoLyrics { await search() }
        }.onChange(of: offset) { value in UserDefaults.standard.set(value, forKey: "lyricsOffset." + item.id.uuidString) }
    }
    private var matchPanel: some View {
        DisclosureGroup("Şarkı / sanatçı eşleştirmesi") {
            TextField("Şarkı", text: $title).textFieldStyle(.roundedBorder)
            TextField("Sanatçı (kanal adı olmak zorunda değil)", text: $artist).textFieldStyle(.roundedBorder)
            Button("Sözleri ara") { Task { await search() } }.disabled(loading || title.isEmpty)
            Toggle("Açınca otomatik ara", isOn: $autoLyrics)
            Text("Aramada şarkı/sanatçı adı LRCLIB'e gönderilir. Anahtar gerekmez. Yanlış sürüm eşleşirse aşağıdaki sonucu elle seç; her şarkıda senkron söz bulunmayabilir.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal)
    }
    @ViewBuilder private var resultsPanel: some View {
        if !results.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(results) { record in resultRow(record) }
                }.padding(.horizontal)
            }.frame(maxHeight: 180)
        }
    }
    private func resultRow(_ record: LyricsRecord) -> some View {
        Button { choose(record) } label: {
            VStack(alignment: .leading) {
                Text(record.artistName + " — " + record.trackName)
                Text("\(Int(record.duration)) sn · " + (record.syncedLyrics == nil ? "Düz söz" : "Senkron LRC"))
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(8).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private var selectedPanel: some View {
        if let selected {
            selectedHeader(selected)
            if selected.instrumental {
                Text("Bu kayıt enstrümantal olarak işaretli.").padding()
            } else if !lines.isEmpty {
                syncedPanel
            } else {
                ScrollView {
                    Text(selected.plainLyrics ?? "Bu kayıtta söz bulunamadı.")
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
            }
        } else if results.isEmpty && !loading {
            Spacer()
            Text("Söz bulunamazsa şarkı ve sanatçı alanlarını düzenleyip yeniden ara.")
                .foregroundStyle(.secondary).padding()
            Spacer()
        }
    }
    private func selectedHeader(_ record: LyricsRecord) -> some View {
        HStack {
            Text(record.artistName + " — " + record.trackName).font(.caption).lineLimit(2)
            Spacer()
            Button("Değiştir") { self.selected = nil; lines = [] }
        }.padding(.horizontal)
    }
    private var syncedPanel: some View {
        VStack(spacing: 8) {
            lyricsScroll
            syncBar
        }
    }
    private var lyricsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .center, spacing: 20) {
                    ForEach(lines) { line in lineButton(line) }
                }.padding(.vertical, 30)
            }.onChange(of: activeLine) { value in
                if follow, let value { withAnimation { proxy.scrollTo(value, anchor: .center) } }
            }
        }
    }
    private func lineButton(_ line: LyricLine) -> some View {
        Button {
            guard library.current?.id == item.id else { return }
            library.seek(max(0, line.seconds - offset))
        } label: {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.title3.bold()).multilineTextAlignment(.center)
                .foregroundStyle(activeLine == line.id ? Color.mint : Color.secondary)
                .frame(maxWidth: .infinity).padding(.horizontal)
        }.buttonStyle(.plain).id(line.id)
    }
    private var syncBar: some View {
        HStack {
            Toggle("Takip", isOn: $follow).labelsHidden()
            Text("Senkron: \(offset, specifier: "%.1f") sn").font(.caption)
            Slider(value: $offset, in: -15...15, step: 0.1)
            Button("0") { offset = 0 }
        }.padding(.horizontal)
    }
    @MainActor private func search() async {
        guard !loading else { return }; loading = true; message = nil
        defer { loading = false }
        do {
            let records = try await LyricsClient.shared.search(title: title, artist: artist)
            try Task.checkCancellation()
            results = records
            let matches = records.filter { SongIdentity.confident($0, artist: artist, title: title, duration: item.duration) }
            if matches.count == 1, let record = matches.first { choose(record) }
            else if records.isEmpty { message = "Eşleşen söz bulunamadı. Başlığı sadeleştirip sanatçıyı kontrol et." }
            else { message = "Otomatik eşleşme kesin değil. Doğru kayıt/süreyi seç." }
        } catch is CancellationError { }
        catch { message = error.localizedDescription }
    }
    private func choose(_ record: LyricsRecord) {
        selected = record; lines = LRCParser.parse(record.syncedLyrics ?? ""); results = []; message = nil
        do { try LyricsCache.save(record, id: item.id) }
        catch { message = "Söz gösteriliyor fakat çevrimdışı kaydedilemedi: " + error.localizedDescription }
    }
}
