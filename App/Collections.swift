import SwiftUI
import Security

struct MediaPlaylist: Identifiable, Codable {
    var id = UUID()
    var name: String
    var itemIDs: [UUID] = []
}
struct SavedVideo: Identifiable, Codable {
    let id: String
    var title: String
    var channel: String
    /// Never force-unwrapped: a stored row may carry an id we would not accept again today, and that
    /// used to be able to kill the app while drawing a list.
    var url: URL {
        var components = URLComponents(string: "https://www.youtube.com/watch") ?? URLComponents()
        components.queryItems = [URLQueryItem(name: "v", value: id)]
        return components.url ?? URL(string: "https://www.youtube.com/") ?? URL(fileURLWithPath: "/")
    }
}
struct CollectionState: Codable {
    var favorites: Set<UUID> = []
    var playlists: [MediaPlaylist] = []
    var videos: [SavedVideo] = []
}
@MainActor
final class Collections: ObservableObject {
    @Published var state = CollectionState()
    @Published var error: String?
    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("collections.json")
    init() {
        do { if FileManager.default.fileExists(atPath: url.path) { state = try JSONDecoder().decode(CollectionState.self, from: Data(contentsOf: url)) } }
        catch { self.error = error.localizedDescription }
    }
    func save() {
        do { try JSONEncoder().encode(state).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
    func favorite(_ id: UUID) {
        if state.favorites.contains(id) { state.favorites.remove(id) } else { state.favorites.insert(id) }; save()
    }
    func addPlaylist(_ name: String) {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state.playlists.append(MediaPlaylist(name: text)); save()
    }
    func add(_ item: UUID, to playlist: UUID) {
        guard let i = state.playlists.firstIndex(where: { $0.id == playlist }), !state.playlists[i].itemIDs.contains(item) else { return }
        state.playlists[i].itemIDs.append(item); save()
    }
    @discardableResult
    func add(_ items: [UUID], to playlist: UUID) -> Int {
        guard let i = state.playlists.firstIndex(where: { $0.id == playlist }) else { return 0 }
        let existing = Set(state.playlists[i].itemIDs)
        let fresh = items.filter { existing.contains($0) == false }
        guard !fresh.isEmpty else { return 0 }
        state.playlists[i].itemIDs.append(contentsOf: fresh); save()
        return fresh.count
    }
    @discardableResult
    func createPlaylist(named name: String, containing items: [UUID] = []) -> UUID? {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let playlist = MediaPlaylist(name: text, itemIDs: items)
        state.playlists.append(playlist); save()
        return playlist.id
    }
    func renamePlaylist(_ id: UUID, to name: String) {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
        state.playlists[i].name = text; save()
    }
    func removePlaylist(_ id: UUID) {
        state.playlists.removeAll { $0.id == id }; save()
    }
    func setFavorite(_ ids: [UUID], value: Bool) {
        for id in ids { if value { state.favorites.insert(id) } else { state.favorites.remove(id) } }
        save()
    }
    func toggleFavorite(_ ids: [UUID]) {
        let allFavorite = ids.allSatisfy { state.favorites.contains($0) }
        setFavorite(ids, value: !allFavorite)
    }
    func playlistCount(for item: UUID) -> Int {
        state.playlists.filter { $0.itemIDs.contains(item) }.count
    }
    func saveVideo(_ video: SavedVideo) {
        guard !state.videos.contains(where: { $0.id == video.id }) else { return }
        state.videos.insert(video, at: 0); save()
    }
    func saveLink(_ raw: String) -> Bool {
        guard let id = MediaRules.youTubeID(raw) else { return false }
        saveVideo(SavedVideo(id: id, title: "YouTube · \(id)", channel: "Kayıtlı bağlantı")); return true
    }
}

enum APIKeyStore {
    static let service = "KontYT.YouTube"
    static func read() -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ value: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return true }
        var a = q
        a[kSecValueData as String] = Data(value.utf8)
        a[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(a as CFDictionary, nil) == errSecSuccess
    }
}
@MainActor
final class YouTubeSearch: ObservableObject {
    @Published var results: [SavedVideo] = []
    @Published var loading = false
    @Published var error: String?
    @Published var notice: String?
    @Published var hasNextPage = false
    @Published var loadingAll = false
    private var continuation: YouTubeContinuation?
    private var visitedTokens = Set<String>()
    private var stopRequested = false
    private var generation = UUID()
    func search(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !loading, !loadingAll else { return }
        generation = UUID(); let requestID = generation
        loading = true; error = nil; notice = nil; results = []; visitedTokens = []; continuation = nil; hasNextPage = false
        defer { if requestID == generation { loading = false } }
        do {
            let batch = try await YouTubeWebClient.shared.load(query)
            guard requestID == generation else { return }
            results = batch.videos; continuation = batch.continuation
            hasNextPage = continuation != nil
            updateNotice(more: batch.hasMore)
        } catch { if requestID == generation { self.error = error.localizedDescription } }
    }
    private func updateNotice(more: Bool) {
        notice = "\(results.count) bağlantı okundu. " + (hasNextPage ? "Devam sayfası var." : (more ? "Devam işareti var ama sayfalama verisi alınamadı; liste eksik olabilir." : "Sayfada başka devam kaydı bulunamadı; gizli/kullanılamayan öğeler dahil olmayabilir."))
    }
    func loadMore() async {
        guard !loading, let next = continuation, results.count < 500 else { return }
        guard !visitedTokens.contains(next.token) else { continuation = nil; hasNextPage = false; error = "Tekrarlanan sayfa anahtarı nedeniyle durduruldu."; return }
        let requestID = generation
        loading = true; error = nil
        defer { if requestID == generation { loading = false } }
        do {
            let batch = try await YouTubeWebClient.shared.nextPage(next)
            guard requestID == generation else { return }
            visitedTokens.insert(next.token)
            var seen = Set(results.map(\.id))
            let additions = batch.videos.filter { seen.insert($0.id).inserted }
            results.append(contentsOf: additions.prefix(500 - results.count))
            continuation = batch.continuation; hasNextPage = continuation != nil && results.count < 500
            if results.count >= 500 { notice = "500 kayıt sınırına ulaşıldı; bu listenin tamamı olmayabilir." }
            else { updateNotice(more: batch.hasMore) }
        } catch { if requestID == generation { self.error = "Sayfa alınamadı; mevcut sonuçlar korundu. " + error.localizedDescription } }
    }
    func clear() { generation = UUID(); stopRequested = true; results = []; notice = nil; error = nil; continuation = nil; hasNextPage = false; loading = false; loadingAll = false }
    func stopPages() { stopRequested = true }
    func loadAllPages() async {
        guard !loadingAll, !loading else { return }
        let requestID = generation
        loadingAll = true; stopRequested = false
        defer { if requestID == generation { loadingAll = false } }
        while requestID == generation && hasNextPage && !stopRequested && !Task.isCancelled && results.count < 500 {
            await loadMore()
            if error != nil { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

/// Adds one selection (possibly many archive items) to any playlist, creating a new one inline.
struct AddToPlaylistSheet: View {
    let itemIDs: [UUID]
    var onDone: (String) -> Void = { _ in }
    @EnvironmentObject var collections: Collections
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    private var trimmed: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            List {
                Section("Yeni liste oluştur") {
                    HStack {
                        TextField("Liste adı", text: $newName).textInputAutocapitalization(.words)
                        Button("Oluştur") { create() }.disabled(trimmed.isEmpty).buttonStyle(.borderless)
                    }
                    Text(itemIDs.count > 1 ? "\(itemIDs.count) öğe yeni listeye eklenecek." : "Seçilen öğe yeni listeye eklenecek.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Mevcut listeler") {
                    if collections.state.playlists.isEmpty { Text("Henüz liste yok; yukarıdan oluştur.").foregroundStyle(.secondary) }
                    ForEach(collections.state.playlists) { playlist in
                        Button { add(to: playlist.id, name: playlist.name) } label: {
                            HStack {
                                Label(playlist.name, systemImage: "music.note.list").foregroundStyle(.primary)
                                Spacer()
                                Text("\(playlist.itemIDs.count)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Listeye ekle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Kapat") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    private func create() {
        guard collections.createPlaylist(named: trimmed, containing: itemIDs) != nil else { return }
        onDone("\(itemIDs.count) öğe “\(trimmed)” listesine eklendi.")
        newName = ""; dismiss()
    }
    private func add(to id: UUID, name: String) {
        let added = collections.add(itemIDs, to: id)
        onDone(added == 0 ? "Seçilenler zaten “\(name)” listesinde." : "\(added) öğe “\(name)” listesine eklendi.")
        dismiss()
    }
}
