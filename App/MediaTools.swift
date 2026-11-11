import SwiftUI
import UniformTypeIdentifiers

struct PlaybackBookmark: Identifiable, Codable {
    var id = UUID()
    var itemID: UUID
    var seconds: Double
    var title: String
}
struct CollectionBackup: Codable {
    var schemaVersion = 1
    var exportedAt = Date()
    var collections: CollectionState
    var bookmarks: [PlaybackBookmark]
}
struct CollectionDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let content = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = content
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct MediaEditor: View {
    let item: MediaItem
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) var dismiss
    @State private var title = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Görünen başlık", text: $title)
                Text("Bu işlem arşivdeki görünen başlığı değiştirir; dosyanın gömülü ID3/MP4 etiketlerini değiştirmez.").font(.caption)
            }.navigationTitle("Başlığı düzenle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") { library.rename(item, to: title); dismiss() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.onAppear { title = item.name }
        }
    }
}
struct BackupView: View {
    @EnvironmentObject var collections: Collections
    @EnvironmentObject var library: Library
    @State private var document = CollectionDocument(data: Data())
    @State private var exporting = false
    @State private var importing = false
    @State private var pending: CollectionBackup?
    @State private var confirming = false
    @State private var message: String?
    var body: some View {
        Form {
            Section("Koleksiyon yedeği") {
                Text("Listeler, favoriler, YouTube bağlantıları ve yer imleri JSON olarak yedeklenir. Medya dosyaları, API anahtarı, indirme URL’leri ve aktif kuyruk bu yedeğe dahil değildir.")
                Text("Medya dosyalarını ayrıca arşivin paylaş menüsünden kopyala. Başka kurulumda dosya kimlikleri değişirse listeler yeniden eşleştirilmez.").font(.caption).foregroundStyle(.secondary)
                Button("Koleksiyonu dışa aktar") {
                    do {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        document = CollectionDocument(data: try encoder.encode(CollectionBackup(collections: collections.state, bookmarks: library.bookmarks)))
                        exporting = true
                    } catch { message = error.localizedDescription }
                }
                Button("Koleksiyon yedeği aç") { importing = true }
            }
        }.navigationTitle("Yedek ve geri yükleme")
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "KontYT-koleksiyon") { result in
            switch result { case .success: message = "Koleksiyon yedeği kaydedildi. Medya dosyaları dahil değil."; case .failure(let error): message = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try DiskFile.size(url)
                guard size < 10 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                let backup = try JSONDecoder().decode(CollectionBackup.self, from: Data(contentsOf: url))
                guard backup.schemaVersion == 1 else { throw CocoaError(.fileReadUnknown) }
                guard Set(backup.collections.playlists.map(\.id)).count == backup.collections.playlists.count,
                      Set(backup.collections.videos.map(\.id)).count == backup.collections.videos.count,
                      Set(backup.bookmarks.map(\.id)).count == backup.bookmarks.count,
                      backup.collections.playlists.allSatisfy({ Set($0.itemIDs).count == $0.itemIDs.count }),
                      backup.collections.videos.allSatisfy({ $0.id.count == 11 && $0.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") } }),
                      backup.bookmarks.allSatisfy({ $0.seconds.isFinite && $0.seconds >= 0 }) else { throw CocoaError(.fileReadCorruptFile) }
                pending = backup; confirming = true
            } catch { message = error.localizedDescription }
        }
        .confirmationDialog("Mevcut koleksiyonun yerine yedek yüklensin mi?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Koleksiyonu değiştir", role: .destructive) {
                if let pending { collections.state = pending.collections; collections.save(); library.bookmarks = pending.bookmarks; library.saveBookmarks() }
                pending = nil
            }
            Button("Vazgeç", role: .cancel) { pending = nil }
        }
        .alert("Yedekleme", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("Tamam") { message = nil }
        } message: { Text(message ?? "") }
    }
}

// Pure validation shared by production code and unit tests.
enum MediaRules {
    static func youTubeID(_ raw: String) -> String? {
        guard let u = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), let host = u.host?.lowercased(), ["https", "http"].contains(u.scheme?.lowercased() ?? "") else { return nil }
        let parts = u.pathComponents.filter { $0 != "/" }
        var id: String?
        if host == "youtu.be" { id = parts.first }
        else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            id = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value
            if id == nil, parts.count > 1, ["shorts", "embed", "live"].contains(parts[0]) { id = parts[1] }
        }
        guard let id, id.count == 11, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return id
    }
    static func boundedSeek(_ value: Double, duration: Double) -> Double? {
        guard value.isFinite, duration.isFinite, duration >= 0 else { return nil }
        return min(max(value, 0), duration)
    }
}
