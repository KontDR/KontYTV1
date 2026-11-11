import SwiftUI
import UIKit

struct StudioRoot: View {
    @EnvironmentObject var library: Library
    @StateObject private var collections = Collections()
    @StateObject private var incoming = IncomingLinks()
    @StateObject private var flow = ImportFlow()
    @StateObject private var clipboard = ClipboardMonitor()
    @AppStorage("keepScreenAwake") private var keepAwake = true
    @AppStorage("autoClipboard") private var autoClipboard = false
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0
    @State private var showGlobalPlayer = false
    var body: some View {
        TabView(selection: $tab) {
            LibraryView().modifier(GlobalMiniPlayer(onOpen: { showGlobalPlayer = true })).tag(0).tabItem { Label("Arşiv", systemImage: "square.stack.fill") }
            DownloadsView().modifier(GlobalMiniPlayer(onOpen: { showGlobalPlayer = true })).tag(1).tabItem { Label("İndirmeler", systemImage: "arrow.down.circle.fill") }
            CollectionsView().modifier(GlobalMiniPlayer(onOpen: { showGlobalPlayer = true })).tag(2).tabItem { Label("Koleksiyon", systemImage: "heart.text.square.fill") }
            YouTubeSiteTab().environmentObject(library).modifier(GlobalMiniPlayer(onOpen: { showGlobalPlayer = true })).tag(3).tabItem { Label("YouTube", systemImage: "play.rectangle.fill") }
            SettingsView().modifier(GlobalMiniPlayer(onOpen: { showGlobalPlayer = true })).tag(4).tabItem { Label("Ayarlar", systemImage: "slider.horizontal.3") }
        }.environmentObject(collections).environmentObject(incoming).environmentObject(flow).tint(.mint)
        .onAppear {
            // The Wi-Fi receiver belongs to the app, not to the settings screen.
            WiFiUploadServer.shared.onFile = { url, name in try await library.add(url, suggestedName: name) }
            WiFiUploadServer.shared.setForeground(phase == .active)
            DownloadCenter.shared.setForeground(phase == .active)
            incoming.refresh(); if incoming.autoImportHandoff() { tab = 3 }
            flow.resume(); UIApplication.shared.isIdleTimerDisabled = keepAwake && phase == .active
            if !incoming.items.isEmpty { tab = 3 }
            clipboard.check { url in incoming.open(url); tab = 3 }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            // Jetsam is the usual reason an app "just closes"; give the system its memory back first.
            library.handleMemoryWarning()
            CrashLog.note("Bellek uyarisi alindi")
        }
        .onChange(of: keepAwake) { value in UIApplication.shared.isIdleTimerDisabled = value && phase == .active }
        .onChange(of: tab) { value in
            // If the app ever dies silently, the log names the tab that was opening.
            CrashLog.note("Sekme " + String(value))
        }
        .onChange(of: flow.event) { _ in tab = 1 }
        .onChange(of: incoming.externalQuery) { value in if value != nil { tab = 3 } }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in clipboard.check { url in incoming.open(url); tab = 3 } }
        .onChange(of: phase) { value in handleScenePhase(value) }
        .onOpenURL { url in incoming.open(url); tab = 3 }
        .onReceive(NotificationCenter.default.publisher(for: .kontytShowPlayer)) { _ in showGlobalPlayer = true }
        .sheet(isPresented: $showGlobalPlayer) { NowPlayingView().environmentObject(library) }
        .alert("KontYT", isPresented: Binding(get: { collections.error != nil || library.playbackError != nil }, set: { if !$0 { collections.error = nil; library.playbackError = nil } })) {
            Button("Tamam") { collections.error = nil; library.playbackError = nil }
        } message: { Text(library.playbackError ?? collections.error ?? "") }
    }
    /// Foreground and background only. `.inactive` is the half second a sheet animation takes;
    /// treating it as a real trip produced three log lines and three audio kicks in one second,
    /// right before the process disappeared. Nothing in `.inactive` may kick audio or downloads.
    private func handleScenePhase(_ value: ScenePhase) {
        guard value != .inactive else { CrashLog.note("Gecis"); return }
        CrashLog.note(value == .active ? "On planda" : "Arka planda")
        if value == .active {
            UIApplication.shared.isIdleTimerDisabled = keepAwake
            DownloadCenter.shared.setForeground(true)
            WiFiUploadServer.shared.setForeground(true)
            incoming.refresh(); flow.resume(); DownloadCenter.shared.drainChunks()
            DownloadCenter.shared.drainInbox(); if !incoming.items.isEmpty { tab = 3 }
            // The video teardown may have paused the player while we were away; a running track keeps
            // going and the lock screen buttons are re-armed.
            library.installRemoteCommands()
            library.ensureAudioContinues()
            // A share left a link on the handoff pasteboard: take it and open the sheet.
            if incoming.autoImportHandoff() { tab = 3 }
            clipboard.check { url in incoming.open(url); tab = 3 }
        } else {
            UIApplication.shared.isIdleTimerDisabled = false
            DownloadCenter.shared.setForeground(false)
            WiFiUploadServer.shared.setForeground(false)
            library.rememberPosition()
            // Jetsam is the one death we can influence: hand the in-memory caches back on the way out.
            library.releaseCachesQuietly()
        }
    }
}
private struct TransitionPicker: View {
    @Binding var fade: Double
    var body: some View {
        Picker("Parça geçişi", selection: $fade) {
            Text("Kapalı").tag(0.0)
            Text("1 sn").tag(1.0)
            Text("2 sn").tag(2.0)
            Text("3 sn").tag(3.0)
        }.pickerStyle(.menu)
    }
}

struct CollectionsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var collections: Collections
    @State private var adding = false
    @State private var renaming: MediaPlaylist?
    @State private var renameText = ""
    @State private var name = ""
    var body: some View {
        NavigationStack {
            List {
                bannerSection
                favoritesSection
                playlistsSection
                recentSection
                nowPlayingSection
            }.navigationTitle("Koleksiyon").kontytBrand()
            .alert("Yeni liste", isPresented: $adding) {
                TextField("Liste adı", text: $name)
                Button("Oluştur") { collections.addPlaylist(name); name = "" }
                Button("Vazgeç", role: .cancel) {}
            }
            .alert("Listeyi yeniden adlandır", isPresented: renameAlert) {
                TextField("Liste adı", text: $renameText)
                Button("Kaydet") { saveRename() }
                Button("Vazgeç", role: .cancel) { renaming = nil }
            }
        }
    }
    private var renameAlert: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }
    private func saveRename() {
        if let playlist = renaming { collections.renamePlaylist(playlist.id, to: renameText) }
        renaming = nil
    }
    private var bannerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("SANA AİT BİR ARŞİV").font(.caption.bold()).foregroundStyle(.mint)
                Text("Ritmini yanında taşı.").font(.largeTitle.bold())
                Text("Favoriler ve listeler bu cihazda saklanır.").foregroundStyle(.secondary)
            }.padding(.vertical)
        }.listRowBackground(Color.mint.opacity(0.08))
    }
    private var favoritesSection: some View {
        Section("Favoriler") {
            let favorites = library.items.filter { collections.state.favorites.contains($0.id) }
            if favorites.isEmpty { Text("Arşivde bir öğeye basılı tutup favorilere ekle.").foregroundStyle(.secondary) }
            ForEach(favorites) { item in
                favoriteRow(item, queue: favorites)
            }
        }
    }
    private func favoriteRow(_ item: MediaItem, queue: [MediaItem]) -> some View {
        Button { library.startQueue(queue, startingAt: item.id) } label: {
            Label(item.name, systemImage: item.isVideo ? "film" : "music.note")
        }
        .contextMenu {
            Button { library.playNext(item) } label: { Label("Sırada sonra çal", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { collections.favorite(item.id) } label: { Label("Favorilerden çıkar", systemImage: "heart.slash") }
        }
    }
    private var playlistsSection: some View {
        Section("Çalma listeleri") {
            ForEach(collections.state.playlists) { playlist in playlistRow(playlist) }
            Button { adding = true } label: { Label("Yeni çalma listesi", systemImage: "plus") }
            Text("Arşivde Çoklu seç ile birden fazla parçayı tek seferde bir listeye ekleyebilirsin.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func playlistRow(_ playlist: MediaPlaylist) -> some View {
        NavigationLink {
            PlaylistView(id: playlist.id)
        } label: {
            Label("\(playlist.name) · \(playlistItemCount(playlist))", systemImage: "music.note.list")
        }
        .swipeActions {
            Button("Sil", role: .destructive) { collections.removePlaylist(playlist.id) }
            Button("Yeniden adlandır") { renameText = playlist.name; renaming = playlist }
        }
    }
    private func playlistItemCount(_ playlist: MediaPlaylist) -> Int {
        let valid = Set(library.items.map(\.id))
        return playlist.itemIDs.filter { valid.contains($0) }.count
    }
    private var recentSection: some View {
        Section("Son çalınanlar") {
            let recent = recentItems
            if recent.isEmpty { Text("Henüz oynatma geçmişi yok.").foregroundStyle(.secondary) }
            ForEach(recent.prefix(10)) { item in
                Button { library.startQueue(recent, startingAt: item.id) } label: {
                    Label(item.name, systemImage: item.isVideo ? "film" : "music.note")
                }
            }
        }
    }
    private var recentItems: [MediaItem] {
        library.recentlyPlayed.compactMap { id in library.items.first { $0.id == id } }
    }
    private var nowPlayingSection: some View {
        Section("Şimdi çalıyor") {
            if let current = library.current {
                Text(current.name)
                transportRow
            } else {
                Text("Henüz bir dosya seçilmedi.").foregroundStyle(.secondary)
            }
        }
    }
    private var transportRow: some View {
        HStack {
            Button { library.previous() } label: { Image(systemName: "backward.end.fill") }
            Spacer()
            Button { library.playing ? library.pause() : library.resume() } label: {
                Image(systemName: library.playing ? "pause.fill" : "play.fill")
            }
            Spacer()
            Button { library.next() } label: { Image(systemName: "forward.end.fill") }
        }.buttonStyle(.borderless)
    }
}
struct PlaylistView: View {
    let id: UUID
    @EnvironmentObject var collections: Collections
    @EnvironmentObject var library: Library
    var playlist: MediaPlaylist? { collections.state.playlists.first { $0.id == id } }
    var items: [MediaItem] { (playlist?.itemIDs ?? []).compactMap { id in library.items.first { $0.id == id } } }
    var body: some View {
        List {
            if !items.isEmpty {
                Button("Sırayla çal") { library.startQueue(items) }
                Button("Karışık çal") { library.startShuffledQueue(items) }
            }
            ForEach(items) { item in
                Button { library.startQueue(items, startingAt: item.id) } label: { Label(item.name, systemImage: item.isVideo ? "film" : "music.note") }
            }.onDelete { offsets in
                let removed = Set(offsets.map { items[$0].id })
                if let i = collections.state.playlists.firstIndex(where: { $0.id == id }) {
                    collections.state.playlists[i].itemIDs.removeAll { removed.contains($0) }; collections.save()
                }
            }
            if items.isEmpty { Text("Arşivde bir öğeye basılı tutarak bu listeye ekle.").foregroundStyle(.secondary) }
        }.navigationTitle(playlist?.name ?? "Liste")
        .toolbar { EditButton() }
    }
}
struct DiscoveryView: View {
    @EnvironmentObject var incoming: IncomingLinks
    @EnvironmentObject var collections: Collections
    @EnvironmentObject var flow: ImportFlow
    @StateObject private var search = YouTubeSearch()
    @State private var query = ""
    @State private var browserRequest: BrowserRequest?
    @State private var lastPlaylist: URL?
    @State private var lastPlaylistInbox: InboxLink?
    @State private var browserVideos: [SavedVideo] = []
    @State private var browserNotice: String?
    @State private var batchWarning: String?
    @State private var autoBrowserTried = Set<String>()
    @AppStorage("autoBrowserFallback") private var autoBrowserFallback = true
    @State private var downloadingVideo: SavedVideo?
    @State private var quickVideo: SavedVideo?
    @State private var quickInbox: InboxLink?
    @AppStorage("askDownloadType") private var askDownloadType = true
    @State private var batchVideos: [SavedVideo] = []
    @State private var showBatch = false
    @State private var batchInbox: InboxLink?
    @State private var handling = false
    @State private var handledInbox = Set<UUID>()
    @State private var pasteDebounce: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            List {
                searchSection
                if !search.results.isEmpty { resultsSection }
                savedSection
                inboxSection
            }.navigationTitle("YouTube").kontytBrand()
            .toolbar {
                Button { browserVideos = []; browserNotice = nil; browserRequest = BrowserRequest(url: URL(string: "https://m.youtube.com")!) } label: {
                    Label("Tarayıcı", systemImage: "globe")
                }
                .disabled(browserRequest != nil)
            }
            .onAppear {
                // Keşfe dönüldüğünde eski link/arama kalmasın: her seferinde temiz başlangıç.
                query = ""
                search.clear()
                lastPlaylist = nil
                lastPlaylistInbox = nil
                handledInbox.removeAll()
                incoming.items.removeAll()
                if !handling, !showBatch, quickVideo == nil, downloadingVideo == nil, browserRequest == nil { resumeIncoming() }
            }
            .onChange(of: incoming.externalQuery) { value in
                if let value, !handling, !showBatch, quickVideo == nil, downloadingVideo == nil, browserRequest == nil { incoming.externalQuery = nil; submit(value) }
            }
            .onChange(of: handling) { value in if !value, !showBatch, quickVideo == nil, downloadingVideo == nil, browserRequest == nil { resumeIncoming() } }
            .onChange(of: incoming.items.count) { _ in processInbox() }
            .onChange(of: query) { value in
                pasteDebounce?.cancel()
                guard value.hasPrefix("https://") || value.hasPrefix("http://"), let url = SharedInbox.extract(value) else { return }
                let list = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "list" })?.value
                guard MediaRules.youTubeID(url.absoluteString) != nil || (list?.count ?? 0) > 10 else { return }
                pasteDebounce = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                    guard query == value else { return }; submit(value)
                }
            }
            .onChange(of: flow.event) { _ in clearSearch() }
            .sheet(item: $browserRequest, onDismiss: { finishBrowserImport() }) { request in
                YouTubeBrowserView(url: request.url) { videos, notice in
                    browserVideos = videos; browserNotice = notice
                }
            }
            .sheet(item: $quickVideo, onDismiss: { quickInbox = nil; resumeIncoming() }) { video in
                QuickDownloadSheet(video: video, onQueued: {
                    if let item = quickInbox { incoming.consume(item) }
                    quickInbox = nil; clearSearch()
                }).environmentObject(flow)
            }
            .sheet(isPresented: $showBatch, onDismiss: { batchInbox = nil; resumeIncoming() }) { BulkMediaSheet(videos: batchVideos, warning: batchWarning ?? search.error, onQueued: {
                if let item = batchInbox { incoming.consume(item) }
                batchInbox = nil; clearSearch()
            }).environmentObject(flow) }
            .sheet(item: $downloadingVideo, onDismiss: { resumeIncoming() }) { video in MediaDownloadSheet(video: video, onQueued: { clearSearch(); flow.event += 1 }) }
        }
    }
    private var searchSection: some View {
        Section {
            Text("BAĞLANTIYI YAPIŞTIR · SIRAYA AL").font(.caption.bold()).foregroundStyle(.mint)
            searchField
            Text("Tek bağlantıda Müzik / Video seç. Liste bağlantısında türü ve kayıtları seçebilirsin.")
                .font(.caption).foregroundStyle(.secondary)
            if search.loading || handling { ProgressView("Bağlantı işleniyor…") }
            if let notice = search.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let error = search.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if let url = lastPlaylist { browserFallbackButton(url) }
        }
    }
    private var searchField: some View {
        HStack {
            TextField("Ara veya YouTube bağlantısı", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.go)
                .onSubmit { submit(query) }
            PasteButton(payloadType: String.self) { values in
                if let text = values.first { submit(text) }
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Panodan yapıştır (izin sormaz)")
            Button { submit(query) } label: { Image(systemName: "arrow.right.circle.fill") }
                .disabled(search.loading || handling)
        }
    }
    @ViewBuilder private func browserFallbackButton(_ url: URL) -> some View {
        Button { browserVideos = []; browserNotice = nil; browserRequest = BrowserRequest(url: url) } label: {
            Label(search.error == nil ? "Listeyi tarayıcıda aç / onayı kontrol et" : "Tarayıcıda aç ve yüklenenleri oku", systemImage: "globe")
        }.disabled(handling || search.loading || search.loadingAll)
        if search.error != nil {
            Text("Anonim istek başarısız olduysa tarayıcı yolu tek çözümdür: listeyi uygulama içi tarayıcıda aç, gerekirse giriş/onay yap, sayfayı aşağı kaydır.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var resultsSection: some View {
        Section("Sonuçlar · \(search.results.count)") {
            if search.hasNextPage {
                Button("Sonraki sayfa") { Task { await search.loadMore() } }.disabled(search.loading || search.loadingAll)
                Button("Liste sayfalarını yükle · en çok 500") { Task { await search.loadAllPages() } }.disabled(search.loading || search.loadingAll)
            }
            if search.loadingAll { Button("Yüklemeyi durdur") { search.stopPages() } }
            Button("Seç / Tümünü indir…") { batchWarning = nil; batchVideos = search.results; showBatch = true }
            ForEach(search.results) { video in row(video) }
        }
    }
    private var savedSection: some View {
        Section("Kayıtlı bağlantılar") {
            ForEach(collections.state.videos) { video in row(video) }
                .onDelete { offsets in collections.state.videos.remove(atOffsets: offsets); collections.save() }
        }
    }
    @ViewBuilder private var inboxSection: some View {
        if !incoming.items.isEmpty {
            Section("Bekleyen paylaşımlar") {
                ForEach(incoming.items) { item in
                    Button(item.url.absoluteString) { submit(item.url.absoluteString, inboxID: item.id) }
                        .font(.caption).disabled(handling)
                }
            }
        }
        if incoming.unavailable {
            Section("Paylaşım") {
                Text("Paylaş → KontYT artık uygulamayı kendisi açar ve bağlantıyı doğrudan getirir. Sistem açmayı reddederse bağlantı panoya bırakılır: yukarıdaki “Panodan yapıştır” düğmesi izin sormadan alır.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let error = incoming.error {
            Section("Paylaşım durumu") { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func finishBrowserImport() {
        guard !browserVideos.isEmpty else { resumeIncoming(); return }
        let collected = browserVideos; browserVideos = []
        handling = true
        Task { @MainActor in
            // Rows the page left without a label get their real name here (bounded, four at a time).
            let named = await TitleResolver.shared.filling(collected)
            batchVideos = named
            batchWarning = browserNotice
            if let item = lastPlaylistInbox, incoming.items.contains(where: { $0.id == item.id }) { batchInbox = item }
            else { batchInbox = nil }
            search.clear(); query = ""; showBatch = true; handling = false
        }
    }
    private func clearSearch() { query = ""; search.clear(); lastPlaylist = nil; lastPlaylistInbox = nil }
    private func resumeIncoming() {
        if let value = incoming.externalQuery { incoming.externalQuery = nil; submit(value) }
        else { processInbox() }
    }
    private func processInbox() {
        guard !handling, !showBatch, quickVideo == nil, downloadingVideo == nil, browserRequest == nil, let first = incoming.items.first(where: { !handledInbox.contains($0.id) }) else { return }
        handledInbox.insert(first.id); submit(first.url.absoluteString, inboxID: first.id)
    }
    private func submit(_ raw: String, inboxID: UUID? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !handling else { return }
        if let url = SharedInbox.extract(text) {
            let hasList = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "list" && !($0.value ?? "").isEmpty } ?? false
            if !hasList, let id = MediaRules.youTubeID(url.absoluteString) {
                // Show the real song/video name, not the raw watch id: oEmbed answers without a login.
                queueNamedVideo(id: id, url: url, inboxID: inboxID)
                return
            }
            if hasList {
                lastPlaylist = url
                lastPlaylistInbox = inboxID.map { InboxLink(id: $0, url: url) }
            }
            handling = true; query = ""
            Task { @MainActor in
                await search.search(url.absoluteString)
                if hasList, search.hasNextPage { await search.loadAllPages() }
                if hasList, !search.results.isEmpty {
                    batchWarning = nil; batchVideos = search.results; showBatch = true
                    batchInbox = inboxID.map { InboxLink(id: $0, url: url) }
                }
                handling = false
                // Anonymous fetching cannot see a logged-in list. Hand the link to the in-app
                // browser, which auto-detects the loaded entries with the user's own session.
                if hasList, search.results.isEmpty, autoBrowserFallback, browserRequest == nil,
                   autoBrowserTried.insert(url.absoluteString).inserted {
                    browserVideos = []; browserNotice = nil
                    browserRequest = BrowserRequest(url: url)
                }
            }
        } else {
            query = text
            Task { await search.search(text) }
        }
    }
    /// Looks the name up first, then runs the normal single-link flow (Müzik / Video question included).
    private func queueNamedVideo(id: String, url: URL, inboxID: UUID?) {
        let placeholder = SavedVideo(id: id, title: "YouTube · " + id, channel: "")
        guard TitleResolver.needsName(placeholder) else {
            queueOrAsk(placeholder, inbox: inboxID.map { InboxLink(id: $0, url: url) })
            return
        }
        Task { @MainActor in
            let info = await TitleResolver.shared.info(for: id)
            let video = info.map { SavedVideo(id: id, title: $0.title, channel: $0.channel) } ?? placeholder
            queueOrAsk(video, inbox: inboxID.map { InboxLink(id: $0, url: url) })
        }
    }
    private func queueOrAsk(_ video: SavedVideo, inbox: InboxLink? = nil) {
        if askDownloadType { quickInbox = inbox; quickVideo = video }
        else if flow.enqueue([video]) {
            if let inbox { incoming.consume(inbox) }; clearSearch()
        } else { search.error = flow.message }
    }
    private func row(_ video: SavedVideo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                RemoteThumbnail(videoID: video.id)
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title).font(.headline).lineLimit(2)
                    Text(video.channel).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("İndir") {
                    queueOrAsk(video)
                }.buttonStyle(.borderless)
                Button("Kalite seç") { downloadingVideo = video }.buttonStyle(.borderless)
                Spacer()
                Button { collections.saveVideo(video) } label: { Image(systemName: "bookmark") }.buttonStyle(.borderless)
                Link(destination: video.url) { Image(systemName: "arrow.up.right.square") }
            }.font(.subheadline)
        }.padding(.vertical, 6)
    }
}
struct SettingsView: View {
    @EnvironmentObject var library: Library
    @AppStorage("keepScreenAwake") private var keepAwake = true
    @AppStorage("autoClipboard") private var autoClipboard = false
    @AppStorage("preferAudioOnly") private var audioOnly = false
    @AppStorage("askDownloadType") private var askDownloadType = true
    @AppStorage("maxVideoHeight") private var maxHeight = 720
    @AppStorage("preferCombined") private var combined = true
    @AppStorage("chunkedTransfers") private var chunks = true
    @AppStorage("compatibilityMode") private var compatibility = true
    @AppStorage("transitionFade") private var transitionFade = 2.0
    @AppStorage("audioOnlyVideos") private var audioOnlyVideos = false
    @AppStorage("pictureInPicture") private var pictureInPicture = false
    @AppStorage("blockYouTubeAds") private var blockYouTubeAds = true
    @AppStorage("siteBrowserResetTick") private var siteBrowserResetTick = 0
    @State private var diagnosticsText = "Tanılama için Ayarlar açıldığında okunur."
    @AppStorage("resumePlayback") private var resumePlayback = false
    @AppStorage("autoBrowserFallback") private var autoBrowserFallback = true
    @ObservedObject private var wifi = WiFiUploadServer.shared
    var storage: String {
        let bytes = library.items.reduce(Int64(0)) { value, item in
            let size = (try? DiskFile.size(library.file(item))) ?? 0
            return value + Int64(size)
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    var body: some View {
        NavigationStack {
            Form {
                quickSection
                playbackSection
                listSection
                transferSection
                backupSection
                deviceSection
                diagnosticsSection
                programSection
            }
            .navigationTitle("Kontrol merkezi").kontytBrand()
        }
    }
    private var wifiBinding: Binding<Bool> {
        Binding(get: { wifi.enabled || wifi.running }, set: { value in if value { wifi.start() } else { wifi.stop() } })
    }
    private var quickSection: some View {
        Section("Hızlı indirme ve ekran") {
            Toggle("Uygulama öndeyken ekranı açık tut", isOn: $keepAwake)
            Toggle("Panodaki YouTube bağlantısını otomatik işle", isOn: $autoClipboard)
            Text("Kapalıyken iOS pano izni sormaz; YouTube sekmesindeki pano düğmesiyle tek dokunuşta alırsın.").font(.caption).foregroundStyle(.secondary)
            Toggle("Tek bağlantıda Müzik / Video sor", isOn: $askDownloadType)
            Toggle("Soru kapalıysa: yalnızca M4A ses", isOn: $audioOnly)
            Picker("Video kalite sınırı", selection: $maxHeight) {
                Text("360p").tag(360); Text("720p").tag(720); Text("1080p").tag(1080); Text("En yüksek").tag(0)
            }
            Toggle("Birleşik/hızlı MP4 tercih et", isOn: $combined)
            Toggle("H.264 / AAC uyumluluk modu", isOn: $compatibility)
            Toggle("Yeni YouTube işlerinde 8 MB parçalı aktarım", isOn: $chunks)
            Text("Pano erişimi için iOS izin sorabilir; sistem izni atlanmaz. Ekran açık tutma yalnızca uygulama öndeyken geçerlidir. Kaynak hız sınırlaması ve ağ koşulları için hız garantisi yoktur.")
                .font(.caption)
        }
    }
    private var playbackSection: some View {
        Section("Oynatma") {
            Toggle("Kaldığı yerden devam et", isOn: $resumePlayback)
            Text("Kapalıyken her parça baştan başlar (varsayılan). Açıkken son konum hatırlanır ve 3 saniyeden sonrası devam eder.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Kayıtlı konumları temizle") { library.clearStoredPositions() }.font(.caption)
            Toggle("Video dosyalarını yalnızca ses olarak oynat", isOn: $audioOnlyVideos)
            Toggle("Resim içinde resim (PiP)", isOn: $pictureInPicture)
            Toggle("YouTube reklamlarını engelle", isOn: $blockYouTubeAds)
            Text("YouTube sekmesindeki sayfada reklam blokları oynatıcıya hiç verilmez, reklam alanları gizlenir ve kalan reklam ileri sarılır. Tamamen cihazda çalışır. Değişiklik sayfayı bir kez yeniler.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Tarayıcı kimliğini yenile") { siteBrowserResetTick += 1 }
                .font(.caption)
            Text("Çerezler, yerel depo ve önbellek silinir; sekme yepyeni bir tarayıcı kimliğiyle (yeni depo + farklı Safari user agent) yeniden açılır. Arşivine, indirmelerine ve diğer hesaplara dokunmaz. \"Bot değilsin\" duvarı çıkarsa kullan.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Açıkken oynatıcının sağ üstünde PiP simgesi çıkar; uygulamadan çıkınca video küçük pencerede devam eder ve ses susmaz. Kapalıyken AVKit hiç PiP kurmaz — kapanma şikâyeti bu yolu tamamen kapatmıştı, o yüzden varsayılan kapalı.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Kapalıyken video, oynatıcının içinde görüntüyle açılır ve geri plana geçince PiP ile devam eder. Açıkken video hiç çizilmez, ses çalar; oynatıcı menüsündeki “Videoyu göster” ile tek seferlik geri alabilirsin.")
                .font(.caption).foregroundStyle(.secondary)
            TransitionPicker(fade: $transitionFade)
            Text("Parça bitmeden önce ses yumuşakça kısılır, yeni parça kısıktan açılır. Kesintisiz çapraz geçiş (iki motor aynı anda) henüz yok.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var listSection: some View {
        Section("Liste okuma") {
            Toggle("Liste okunamazsa tarayıcıyı otomatik aç", isOn: $autoBrowserFallback)
            Text("Açıkken hata alan oynatma listesi, giriş yaptığın uygulama içi tarayıcıda açılır ve yüklenen kayıtlar otomatik algılanır.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var transferSection: some View {
        Section("Dosya aktarımı") {
            Toggle("Wi-Fi yükleme açık kalsın", isOn: wifiBinding)
            if wifi.running, !wifi.address.isEmpty { Text(wifi.address).font(.caption.monospaced()).textSelection(.enabled) }
            NavigationLink("Wi-Fi ile bilgisayardan yükle") { WiFiUploadView() }
            Text("Sunucu, uygulama açık kaldığı sürece Ayarlar'dan çıksan da çalışmaya devam eder. Uygulama arka plana geçince ya da kapanınca durur.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var backupSection: some View {
        Section("Yedekleme") { NavigationLink("Koleksiyon yedeği ve geri yükleme") { BackupView() } }
    }
    private var deviceSection: some View {
        Section("Bu cihaz") {
            LabeledContent("Yerel medya", value: "\(library.items.count) dosya")
            LabeledContent("Medya boyutu", value: storage)
            LabeledContent("Söz önbelleği", value: cacheSize(library.cacheSizes.lyrics))
            LabeledContent("Kapak önbelleği", value: cacheSize(library.cacheSizes.artwork))
            LabeledContent("Küçük resim önbelleği", value: cacheSize(library.cacheSizes.thumbs))
            Button("Söz, kapak ve küçük resim önbelleğini temizle") { library.clearCaches() }
            Text("Dosyalar cihazda saklanır. Uygulamayı silmek arşivi de siler; önemli dosyaları yedekle. Önbellek temizliği medya dosyalarına dokunmaz.").font(.caption)
        }
    }
    private func cacheSize(_ bytes: Int64) -> String {
        bytes == 0 ? "Boş" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private var diagnosticsSection: some View {
        Section("Kapandıysa: tanılama") {
            Text(diagnosticsText).font(.caption2.monospaced()).textSelection(.enabled)
            HStack {
                Button("Tanılama kaydını kopyala") { UIPasteboard.general.string = CrashLog.tail(40) }
                Spacer()
                Button("Temizle") { CrashLog.clear(); diagnosticsText = CrashLog.tail(8) }
            }.font(.caption)
            Text("Kayıt boşsa ve uygulama yine de kapandıysa onu iOS zorla kapatmıştır: ya bellek (çok büyük liste/video) ya da imza süresi. Sistem raporu: Ayarlar › Gizlilik ve Güvenlik › Analizler ve İyileştirmeler › Analiz Verileri › “KontYT” ile başlayan .ips dosyası.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { diagnosticsText = CrashLog.tail(8) }
    }
    private var programSection: some View {
        Section("Program bilgisi") {
            Text("Emre Güner tarafından keyfi üretilmiştir.")
            Text("By KontDR").font(.headline)
            Text("KontYT 0.13.39 · R54").font(.caption).foregroundStyle(.secondary)
        }
    }
}
