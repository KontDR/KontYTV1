import SwiftUI
import AVKit
import MediaPlayer
import UniformTypeIdentifiers

struct MediaItem: Identifiable, Codable {
    let id: UUID
    var name: String
    let filename: String
    let isVideo: Bool
    var duration: Double? = nil
    var sourceVideoID: String? = nil
    var channel: String? = nil
    var artworkFilename: String? = nil
}

@MainActor
final class Library: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var busy = false
    @Published var processingTitle: String?
    private var extractionTask: Task<Void, Never>?
    private let liveAudioGain = LiveAudioGain()
    private var gainSetupTask: Task<Void, Never>?
    private var gainSetupMessage: String?
    @Published var liveGainFactor: Float = 1
    @Published var liveReverbMix: Float = 0
    @Published var livePitchSemitones: Float = 0
    @Published var liveGainStatus = "Uyumlu yerel ses izi bekleniyor"
    @Published var shuffled = false
    private var orderedQueue: [UUID] = []
    func setLiveGain(_ factor: Float) {
        liveGainFactor = LiveGainMath.bounded(factor)
        liveAudioGain.set(liveGainFactor)
        liveGainStatus = gainSetupMessage ?? liveAudioGain.status
    }
    func setLiveReverb(_ mix: Float) {
        liveReverbMix = LiveGainMath.reverbBounded(mix)
        liveAudioGain.setReverb(liveReverbMix)
        liveGainStatus = gainSetupMessage ?? liveAudioGain.status
    }
    func setLivePitch(_ semitones: Float) {
        livePitchSemitones = LiveGainMath.pitchBounded(semitones)
        liveAudioGain.setPitch(livePitchSemitones)
        liveGainStatus = gainSetupMessage ?? liveAudioGain.status
    }
    func resetLiveEffects() {
        liveGainFactor = 1; liveReverbMix = 0; livePitchSemitones = 0
        liveAudioGain.resetAll()
        liveGainStatus = gainSetupMessage ?? liveAudioGain.status
    }
    var liveEffectsActive: Bool { liveGainFactor > 1.0001 || liveReverbMix > 0.001 || abs(livePitchSemitones) >= 0.05 }
    private func installLiveGain(on item: AVPlayerItem) {
        gainSetupTask?.cancel(); liveAudioGain.resetStatus(); gainSetupMessage = nil
        liveGainStatus = liveAudioGain.status
        gainSetupTask = Task<Void, Never> { @MainActor in
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .audio)
                try Task.checkCancellation()
                guard self.player.currentItem === item else { return }
                guard let track = tracks.first else { self.gainSetupMessage = "Bu dosyada ses izi yok"; self.liveGainStatus = "Bu dosyada ses izi yok"; return }
                try self.liveAudioGain.attach(to: item, track: track)
                self.liveGainStatus = self.liveAudioGain.status
            } catch is CancellationError { }
            catch { if self.player.currentItem === item { self.gainSetupMessage = error.localizedDescription; self.liveGainStatus = error.localizedDescription } }
        }
    }
    func toggleShuffle() {
        if shuffled {
            let valid = Set(items.map(\.id))
            queue = orderedQueue.filter { valid.contains($0) }; shuffled = false; return
        }
        orderedQueue = queue
        if queue.count < 2, items.count > 1 { orderedQueue = items.map(\.id) }
        if let id = current?.id { queue = [id] + orderedQueue.filter { $0 != id }.shuffled() }
        else { queue = orderedQueue.shuffled() }
        shuffled = true
    }
    func startShuffledQueue(_ media: [MediaItem]) {
        orderedQueue = media.map(\.id)
        let random = media.shuffled(); queue = random.map(\.id); shuffled = true
        if let first = random.first { play(first) }
    }

    private var artworkCache: [String: UIImage] = [:]
    private var nowPlayingArtworkCache: [String: MPMediaItemArtwork] = [:]
    private let coverArtwork: MPMediaItemArtwork? = UIImage(named: "BrandMark").map { image in MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
    func repairVideo(_ item: MediaItem) {
        guard extractionTask == nil else { message = "Önce mevcut işlemi bitir veya iptal et."; return }
        processingTitle = "Video yeniden paketleniyor: " + item.name
        extractionTask = Task { @MainActor in
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            let background = UIApplication.shared.beginBackgroundTask(withName: "KontYT repair") { self.extractionTask?.cancel() }
            defer {
                try? FileManager.default.removeItem(at: output)
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
                processingTitle = nil; extractionTask = nil
            }
            do {
                try await MediaProcessor.remuxVideo(from: file(item), to: output)
                let id = UUID(), title = item.name + " (Onarılmış)"
                try await add(output, suggestedName: title + ".mp4", identifier: id)
                if let videoID = item.sourceVideoID { await enrich(id, details: TrackDetails(videoID: videoID, title: title, channel: item.channel ?? "")) }
                message = "Onarılmış kopya arşive eklendi; orijinal dosyan korundu."
            } catch { message = error.localizedDescription }
        }
    }
    func extractAudio(_ item: MediaItem) {
        guard extractionTask == nil else { message = "Önce mevcut dönüştürme işlemini bitir veya iptal et."; return }
        processingTitle = "M4A ses çıkarılıyor: " + item.name
        let source = file(item)
        extractionTask = Task { @MainActor in
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            let bg = UIApplication.shared.beginBackgroundTask(withName: "KontYT audio export") { self.extractionTask?.cancel() }
            defer {
                try? FileManager.default.removeItem(at: output)
                if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
                processingTitle = nil; extractionTask = nil
            }
            do {
                try await MediaProcessor.extractAudio(from: source, to: output)
                try Task.checkCancellation()
                let id = UUID()
                try await add(output, suggestedName: item.name + ".m4a", identifier: id)
                if let videoID = item.sourceVideoID { await enrich(id, details: TrackDetails(videoID: videoID, title: item.name, channel: item.channel ?? "")) }
                message = "M4A ses dosyası arşive eklendi."
            } catch { message = error is CancellationError ? "Ses çıkarma iptal edildi." : error.localizedDescription }
        }
    }
    func boostAudio(_ item: MediaItem, decibels: Float) {
        guard extractionTask == nil else {
            message = "Önce mevcut işlemi bitir veya iptal et."
            return
        }
        let gain: Float = AudioBoost.gain(decibels)
        let gainLabel: String = String(Int(gain))
        processingTitle = "Ses yükseltilmiş kopya hazırlanıyor (+" + gainLabel + " dB)"
        extractionTask = Task<Void, Never> { @MainActor in
            await self.runAudioBoost(item, gain: gain)
        }
    }
    private func runAudioBoost(_ item: MediaItem, gain: Float) async {
        let manager: FileManager = FileManager.default
        let temporaryRoot: URL = manager.temporaryDirectory
        let temp: URL = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let background: UIBackgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "KontYT audio boost") {
            self.extractionTask?.cancel()
        }
        defer {
            try? manager.removeItem(at: temp)
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            processingTitle = nil
            extractionTask = nil
        }
        do {
            try await makeBoostedCopy(item, gain: gain, directory: temp)
            message = "Yeni M4A kopyası eklendi. Orijinal korundu. Limiter tepe seviyelerini sınırlar; ses bozulması yine olabilir. Düşük cihaz sesinden başlayarak dinle."
        } catch is CancellationError {
            message = "Ses işleme iptal edildi; orijinal korundu."
        } catch {
            message = error.localizedDescription
        }
    }
    private func checkBoostSpace(_ item: MediaItem, directory: URL) throws {
        let source: URL = file(item)
        let bytes: Int64 = try DiskFile.size(source)
        let duration: Double = item.duration ?? 0.0
        let needed: Double = AudioBoost.requiredSpace(sourceBytes: bytes, duration: duration)
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        let values: URLResourceValues = try directory.resourceValues(forKeys: keys)
        if let free = values.volumeAvailableCapacityForImportantUsage {
            let available: Double = Double(free)
            if available < needed {
                throw YouTubeMediaError.unavailable("Ses işleme için yeterli boş alan yok.")
            }
        }
    }
    private func makeBoostedCopy(_ item: MediaItem, gain: Float, directory: URL) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try checkBoostSpace(item, directory: directory)
        let input: URL = directory.appendingPathComponent("input.m4a")
        let caf: URL = directory.appendingPathComponent("boost.caf")
        let output: URL = directory.appendingPathComponent("boost.m4a")
        var source: URL = file(item)
        if item.isVideo {
            try await MediaProcessor.extractAudio(from: source, to: input)
            source = input
        }
        try await AudioBoost.renderOffMain(source: source, output: caf, decibels: gain)
        try Task.checkCancellation()
        try await MediaProcessor.extractAudio(from: caf, to: output)
        try Task.checkCancellation()
        let id: UUID = UUID()
        let gainLabel: String = String(Int(gain))
        let name: String = item.name + " (+" + gainLabel + " dB)"
        let filename: String = name + ".m4a"
        try await add(output, suggestedName: filename, identifier: id)
        if let videoID = item.sourceVideoID {
            let channel: String = item.channel ?? ""
            let details: TrackDetails = TrackDetails(videoID: videoID, title: name, channel: channel)
            await enrich(id, details: details)
        }
    }
    func cancelProcessing() { extractionTask?.cancel() }
    @Published var message: String?
    @Published var playbackError: String?
    @Published var current: MediaItem?
    @Published var playing = false
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1
    @Published var repeatMode = 0 // 0 off, 1 queue, 2 track
    @Published var sleepUntil: Date?
    @Published var loopA: Double?
    @Published var loopB: Double?
    @Published var bookmarks: [PlaybackBookmark] = []
    @Published var recentlyPlayed: [UUID] = []
    /// Off by default: a finished track starts at 0:00 unless the user opts in.
    var resumeEnabled: Bool { UserDefaults.standard.bool(forKey: "resumePlayback") }
    private func setPosition(_ seconds: Double?, for id: UUID) {
        if let seconds { positions[id.uuidString] = seconds } else { positions[id.uuidString] = nil }
        UserDefaults.standard.set(positions, forKey: "positions")
    }
    func clearStoredPositions() {
        positions.removeAll()
        UserDefaults.standard.removeObject(forKey: "positions")
    }
    func storedPosition(_ item: MediaItem) -> Double? {
        guard resumeEnabled, let value = positions[item.id.uuidString], value > 3 else { return nil }
        return value
    }
    private func notePlayed(_ id: UUID) {
        recentlyPlayed.removeAll { $0 == id }
        recentlyPlayed.insert(id, at: 0)
        if recentlyPlayed.count > 30 { recentlyPlayed.removeLast(recentlyPlayed.count - 30) }
        UserDefaults.standard.set(recentlyPlayed.map(\.uuidString), forKey: "recentlyPlayed")
    }
    func loadRecentHistory() {
        let strings = UserDefaults.standard.stringArray(forKey: "recentlyPlayed") ?? []
        let valid = Set(items.map(\.id))
        let loaded = strings.compactMap(UUID.init(uuidString:)).filter { valid.contains($0) }
        recentlyPlayed = loaded
    }
    func saveBookmarks() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(bookmarks), forKey: "bookmarks") }
        catch { message = error.localizedDescription }
    }
    func addBookmark() {
        guard let id = current?.id else { return }
        bookmarks.append(PlaybackBookmark(itemID: id, seconds: elapsed, title: "Yer imi \(bookmarks.filter { $0.itemID == id }.count + 1)")); saveBookmarks()
    }
    func markLoop() {
        if loopA == nil { loopA = elapsed }
        else if loopB == nil, elapsed > (loopA ?? 0) + 1 { loopB = elapsed }
        else { loopA = nil; loopB = nil }
    }
    func rename(_ item: MediaItem, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let previous = items[i].name
        items[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try save(); if current?.id == item.id { current = items[i]; updateNowPlaying() } }
        catch { items[i].name = previous; message = error.localizedDescription }
    }
    private var positions: [String: Double] = UserDefaults.standard.dictionary(forKey: "positions") as? [String: Double] ?? [:]
    private var timeObserver: Any?
    private var itemStatusObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var audioObservers: [NSObjectProtocol] = []
    private var lastSavedSecond = -1
    private var lastNowPlayingSecond = -1
    private var interruptedPlayback = false
    func seek(_ seconds: Double) {
        guard let target = MediaRules.boundedSeek(seconds, duration: duration > 0 ? duration : max(0, seconds)) else { return }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }
    func setRate(_ value: Float) { rate = value; if playing { player.rate = value }; updateNowPlaying() }
    func setSleep(minutes: Int) { sleepUntil = minutes > 0 ? Date().addingTimeInterval(Double(minutes * 60)) : nil }
    func rememberPosition() {
        guard let current, elapsed.isFinite else { return }
        guard resumeEnabled else {
            // Keeping stale numbers would silently resume later if the option is switched on.
            if positions[current.id.uuidString] != nil { setPosition(nil, for: current.id) }
            return
        }
        setPosition(elapsed, for: current.id)
    }
    let player = AVPlayer()
    @Published var queue: [UUID] = [] {
        didSet { UserDefaults.standard.set(queue.map(\.uuidString), forKey: "playbackQueue") }
    }
    private var endObserver: NSObjectProtocol?
    /// Closing the video surface must not stop the sound: the same player keeps going.
    @Published var videoDetached = false
    /// Settings › Oynatma: play video files as sound only by default. A per-item override
    /// ("Videoyu göster") still works and is reset for every new track.
    var audioOnlyVideos: Bool { UserDefaults.standard.bool(forKey: "audioOnlyVideos") }
    private var fadeInTimer: Timer?
    /// True when the user (or a system pause) asked for silence; PiP teardown must respect it.
    private var userPaused = false
    private var fadingOut = false
    private var fadingIn = false
    /// Track-to-track fade length in seconds; 0 turns it off.
    var transitionFade: Double {
        let stored = UserDefaults.standard.object(forKey: "transitionFade") as? Double
        return min(4, max(0, stored ?? 2))
    }
    /// "Sonraki" without destroying the current queue.
    func playNext(_ item: MediaItem) {
        if let id = current?.id, let index = queue.firstIndex(of: id) {
            queue.removeAll { $0 == item.id }
            queue.insert(item.id, at: min(index + 1, queue.count))
        } else if queue.isEmpty { queue = [item.id] } else { queue.insert(item.id, at: 0) }
        message = item.name + " sırada sonraki."
    }
    func addToQueue(_ additions: [MediaItem]) {
        let existing = Set(queue)
        let fresh = additions.map(\.id).filter { !existing.contains($0) }
        guard !fresh.isEmpty else { message = "Seçilenler zaten sırada."; return }
        queue.append(contentsOf: fresh)
        message = "\(fresh.count) parça sıraya eklendi."
    }
    func removeMany(_ targets: [MediaItem]) { for item in targets { remove(item) } }
    /// Sıradakiler sheet: reorder and drop rows without restarting playback.
    func moveQueue(fromOffsets: IndexSet, toOffset: Int) { queue.move(fromOffsets: fromOffsets, toOffset: toOffset) }
    func moveQueueItem(_ id: UUID, by delta: Int) {
        guard let index = queue.firstIndex(of: id) else { return }
        let target = index + delta
        guard queue.indices.contains(target) else { return }
        queue.swapAt(index, target)
    }
    func removeFromQueue(_ id: UUID) {
        guard id != current?.id else { message = "Çalan parça sıradan çıkarılmaz; önce başka bir parçaya geç."; return }
        queue.removeAll { $0 == id }
    }
    /// Only rebuildable caches: lyrics json and artwork jpg. Media files are never counted or removed.
    var cacheSizes: (lyrics: Int64, artwork: Int64, thumbs: Int64) {
        (Self.folderSize(LyricsCache.folder), Self.folderSize(ArtworkStore.folder), Self.folderSize(ThumbnailStore.folder))
    }
    static func folderSize(_ url: URL) -> Int64 {
        let list = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return list.reduce(Int64(0)) { total, file in total + Int64((try? DiskFile.size(file)) ?? 0) }
    }
    /// iOS is asking for memory back. Only the in-memory artwork goes; the files stay.
    func handleMemoryWarning() {
        artworkCache.removeAll(); nowPlayingArtworkCache.removeAll()
        message = "Bellek uyarısı: kapak önbelleği boşaltıldı. Dosyalara dokunulmadı."
    }
    func clearCaches() {
        let fm = FileManager.default
        for folder in [LyricsCache.folder, ArtworkStore.folder, ThumbnailStore.folder] { try? fm.removeItem(at: folder) }
        artworkCache.removeAll(); nowPlayingArtworkCache.removeAll()
        message = "Söz, kapak ve küçük resim önbelleği temizlendi. Medya dosyalarına dokunulmadı."
    }
    func startQueue(_ items: [MediaItem], startingAt id: UUID? = nil) {
        shuffled = false; orderedQueue = []
        queue = items.map(\.id)
        if let first = items.first(where: { $0.id == id }) ?? items.first { play(first) }
    }
    func next(automatic: Bool = false) {
        if repeatMode == 2 && automatic { seek(0); resume(); return }
        if repeatMode == 1, current?.id == queue.last, let id = queue.first, let first = items.first(where: { $0.id == id }) { positions[id.uuidString] = 0; play(first); return }
        guard let id = current?.id, let i = queue.firstIndex(of: id), i + 1 < queue.count,
              let item = items.first(where: { $0.id == queue[i + 1] }) else { pause(); return }
        play(item)
    }
    func previous() {
        guard let id = current?.id, let i = queue.firstIndex(of: id), i > 0,
              let item = items.first(where: { $0.id == queue[i - 1] }) else { player.seek(to: .zero); return }
        play(item)
    }
    private let fm = FileManager.default
    private var remoteTargets: [Any] = []
    var root: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    var mediaFolder: URL { root.appendingPathComponent("Media", isDirectory: true) }
    var index: URL { root.appendingPathComponent("library.json") }
    private let audioExt = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac"]
    private let videoExt = ["mp4", "mov", "m4v"]

    init() {
        queue = (UserDefaults.standard.stringArray(forKey: "playbackQueue") ?? []).compactMap(UUID.init(uuidString:))
        if let data = UserDefaults.standard.data(forKey: "bookmarks"), let saved = try? JSONDecoder().decode([PlaybackBookmark].self, from: data) { bookmarks = saved }
        do {
            try fm.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: index.path) {
                items = try JSONDecoder().decode([MediaItem].self, from: Data(contentsOf: index))
                loadRecentHistory()
            }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch { message = error.localizedDescription }
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                if let a = self.loopA, let b = self.loopB, self.elapsed >= b { self.seek(a) }
                let total = self.player.currentItem?.duration.seconds ?? 0
                self.duration = total.isFinite ? total : 0
                if let deadline = self.sleepUntil, Date() >= deadline { self.pause(); self.sleepUntil = nil }
                let second = Int(self.elapsed)
                if second % 10 == 0 && self.lastSavedSecond != second { self.lastSavedSecond = second; self.rememberPosition() }
                let gainStatus = self.gainSetupMessage ?? self.liveAudioGain.status
                if self.liveGainStatus != gainStatus { self.liveGainStatus = gainStatus }
                if self.lastNowPlayingSecond != second { self.lastNowPlayingSecond = second; self.updateNowPlaying() }
                self.updateFade(elapsed: self.elapsed, total: total)
            }
        }
        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let active = player.timeControlStatus == .playing
            Task { @MainActor in self?.playing = active; self?.updateNowPlaying() }
        }
        audioObservers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue { self.interruptedPlayback = self.playing; self.pause() }
                else if self.interruptedPlayback && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { self.resume(); self.interruptedPlayback = false }
            }
        })
        audioObservers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor in self?.pause() } }
        })
        installRemoteCommands()
    }
    /// Control Centre / lock screen: every button the system offers is wired here, and the
    /// configuration is re-applied on demand because iOS drops targets after some interruptions.
    func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        let all = [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                   center.nextTrackCommand, center.previousTrackCommand, center.stopCommand,
                   center.changePlaybackPositionCommand, center.skipForwardCommand, center.skipBackwardCommand,
                   center.seekForwardCommand, center.seekBackwardCommand]
        for command in all { command.removeTarget(nil) }
        remoteTargets.removeAll()
        for command in all { command.isEnabled = false }
        // No +/-15 s buttons: the lock screen and Control Centre show previous/next instead, which is
        // what a music queue needs. Leaving the intervals in place makes iOS draw the skip buttons.
        center.skipForwardCommand.preferredIntervals = []
        center.skipBackwardCommand.preferredIntervals = []
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        remoteTargets.append(center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }; return .success
        })
        remoteTargets.append(center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        })
        remoteTargets.append(center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.playing { self.pause() } else { self.resume() }
            }; return .success
        })
        remoteTargets.append(center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }; return .success
        })
        remoteTargets.append(center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }; return .success
        })
        remoteTargets.append(center.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        })
        remoteTargets.append(center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = event.positionTime
            Task { @MainActor in self?.seek(target) }
            return .success
        })

    }
    func file(_ item: MediaItem) -> URL { mediaFolder.appendingPathComponent(item.filename) }
    func save() throws {
        try JSONEncoder().encode(items).write(to: index, options: .atomic)
    }
    private var importingIDs = Set<UUID>()
    func add(_ source: URL, suggestedName: String? = nil, identifier: UUID? = nil, details: TrackDetails? = nil) async throws {
        let id = identifier ?? UUID()
        guard importingIDs.insert(id).inserted else { throw YouTubeMediaError.unavailable("Bu dosya zaten arşive aktarılıyor; mevcut işlemi bekle.") }
        defer { importingIDs.remove(id) }
        if let existing = items.first(where: { $0.id == id }), fm.fileExists(atPath: file(existing).path) {
            _ = try await MediaInspector.inspect(file(existing))
            if let details { await enrich(existing.id, details: details) }
            return
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let proposed = (suggestedName ?? source.lastPathComponent) as NSString
        let ext = proposed.pathExtension.lowercased()
        guard audioExt.contains(ext) || videoExt.contains(ext) else { throw YouTubeMediaError.unavailable("Desteklenmeyen dosya uzantısı: " + ext) }
        let size = try DiskFile.size(source)
        if let available = try mediaFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, available < size + 100 * 1024 * 1024 { throw YouTubeMediaError.unavailable("Arşiv kopyası için yeterli boş alan yok.") }
        let filename = id.uuidString + "." + ext
        let destination = mediaFolder.appendingPathComponent(filename)
        // Validate a unique typed copy before modifying the archive or index.
        let pending = mediaFolder.appendingPathComponent(UUID().uuidString + ".import." + ext)
        defer { try? fm.removeItem(at: pending) }
        try await TransferRange.appendOffMain(source, to: pending, expectedOffset: 0)
        let info = try await MediaInspector.inspect(pending)
        try Task.checkCancellation()
        // No await between taking this snapshot and saving: concurrent imports retain one another.
        let previous = items
        let backup = mediaFolder.appendingPathComponent(UUID().uuidString + ".backup." + ext)
        let hadDestination = fm.fileExists(atPath: destination.path)
        if hadDestination { try fm.moveItem(at: destination, to: backup) }
        do {
            try fm.moveItem(at: pending, to: destination)
            let item = MediaItem(id: id, name: proposed.deletingPathExtension, filename: filename, isVideo: info.hasVideo, duration: info.duration)
            items.removeAll { $0.id == id }; items.insert(item, at: 0)
            try save()
            if hadDestination { try? fm.removeItem(at: backup) }
        } catch {
            items = previous
            try? fm.removeItem(at: destination)
            if hadDestination { try? fm.moveItem(at: backup, to: destination) }
            throw error
        }
        if let details { await enrich(id, details: details) }
    }
    func artwork(for item: MediaItem) -> UIImage? {
        guard let filename = item.artworkFilename else { return nil }
        if let cached = artworkCache[filename] { return cached }
        guard let image = UIImage(contentsOfFile: ArtworkStore.url(filename).path) else { return nil }
        if artworkCache.count >= 24 { artworkCache.removeAll() }
        artworkCache[filename] = image
        return image
    }
    func enrich(_ id: UUID, details: TrackDetails) async {
        guard let original = items.first(where: { $0.id == id }) else { return }
        var filename = original.artworkFilename
        if artwork(for: original) == nil {
            filename = try? await ArtworkStore.download(videoID: details.videoID, identifier: id)
        }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let previous = items[index]
        items[index].sourceVideoID = details.videoID; items[index].channel = details.channel
        items[index].artworkFilename = filename
        if !details.title.isEmpty, items[index].name == original.name { items[index].name = details.title }
        do {
            try save()
            if current?.id == id { current = items[index]; updateNowPlaying() }
        } catch { items[index] = previous; message = "Medya indirildi; ek bilgiler kaydedilemedi: " + error.localizedDescription }
    }
    func refreshArtwork(_ item: MediaItem) {
        let job = DownloadCenter.shared.jobs.first { $0.id == item.id }
        guard let videoID = item.sourceVideoID ?? job?.sourceVideoID else {
            message = "Eski dosyanın YouTube kimliği saklanmamış. Kaynak bağlantısından yeniden indir veya sonraki sürümde elle eşleştir."; return
        }
        Task { await enrich(item.id, details: TrackDetails(videoID: videoID, title: item.name, channel: item.channel ?? job?.details?.channel ?? "")) }
    }
    func download(_ text: String) async {
        if !DownloadCenter.shared.enqueue(text) { message = "Doğrudan HTTPS medya bağlantısı kullan. YouTube sayfa bağlantısı desteklenmiyor." }
    }
    func play(_ item: MediaItem) {
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { message = error.localizedDescription; return }
        if !queue.contains(item.id) { shuffled = false; orderedQueue = []; queue = [item.id] }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        rememberPosition()
        current = item
        loopA = nil; loopB = nil
        elapsed = 0
        duration = (item.duration?.isFinite == true) ? max(0, item.duration ?? 0) : 0
        CrashLog.note("Calma basladi: " + item.name)
        let playerItem = AVPlayerItem(url: file(item))
        // Slow practice speeds keep a natural pitch; the tap only ever touches gain/reverb/pitch.
        playerItem.audioTimePitchAlgorithm = .spectral
        itemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] value, _ in
            if value.status == .failed {
                let error = value.error as NSError?
                let detail = (error?.localizedDescription ?? "Bilinmeyen AVPlayer hatası") + " [\(error?.domain ?? "AVPlayer"):\(error?.code ?? 0)]"
                Task { @MainActor in
                    guard let self, self.player.currentItem === value else { return }
                    self.pause(); self.playbackError = "Oynatma hatası: " + detail + " Arşivde dosyaya basılı tutup yeniden paketlemeyi deneyebilir veya sağlam kaynaktan yeniden indirebilirsin." }
            }
        }
        player.replaceCurrentItem(with: playerItem)
        installLiveGain(on: playerItem)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === playerItem else { return }
                if let id = self.current?.id { self.positions[id.uuidString] = 0; UserDefaults.standard.set(self.positions, forKey: "positions") }
                self.elapsed = 0
                CrashLog.note("Parca bitti, siradaki caliyor")
                self.next(automatic: true)
            }
        }
        if let saved = storedPosition(item) { player.seek(to: CMTime(seconds: saved, preferredTimescale: 600)) }
        else { player.seek(to: .zero); if positions[item.id.uuidString] != nil { setPosition(nil, for: item.id) } }
        notePlayed(item.id)
        resetVideoDetach(for: item)
        resume()
        startFadeIn()
    }
    /// A new video starts with its picture again; audio-only files are unaffected.
    private func resetVideoDetach(for item: MediaItem) {
        videoDetached = item.isVideo && audioOnlyVideos
    }
    func detachVideoSurface() {
        guard current?.isVideo == true else { return }
        videoDetached = true
        ensureAudioContinues()
    }
    /// Picture-in-picture close, video teardown and app foregrounding all land here.
    /// The picture may vanish; the sound only stops if the user actually paused it.
    /// Kept deliberately small: this runs while AVKit is unwinding the video view, so it does nothing
    /// when the player is already running and never repeats within half a second (the log used to show
    /// three kicks in one second, right before the process disappeared).
    private var lastAudioKick = Date.distantPast
    func ensureAudioContinues() {
        guard current != nil, !userPaused else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAudioKick) > 0.5 else { return }
        lastAudioKick = now
        CrashLog.note("Ses devam ettiriliyor")
        let wasPlaying = playing && player.rate != 0
        if !wasPlaying {
            do { try AVAudioSession.sharedInstance().setActive(true) } catch { return }
            player.playImmediately(atRate: rate)
        }
        playing = true
        if !wasPlaying { updateNowPlaying() }
    }
    /// Frees the in-memory caches when the app goes to the background, without a user facing message.
    func releaseCachesQuietly() {
        artworkCache.removeAll(); nowPlayingArtworkCache.removeAll()
    }
    /// Fades the tail of the outgoing track; the incoming track fades in via `startFadeIn`.
    private func updateFade(elapsed: Double, total: Double) {
        let fade = transitionFade
        guard fade > 0.2, total > fade + 1, playing, !fadingIn else {
            if !fadingOut, !fadingIn, player.volume < 1 { player.volume = 1 }
            return
        }
        let remaining = total - elapsed
        if remaining <= fade, remaining > 0 {
            fadingOut = true
            player.volume = Float(max(0.02, remaining / fade))
        }
    }
    private func startFadeIn() {
        fadingOut = false
        fadeInTimer?.invalidate(); fadeInTimer = nil
        let fade = transitionFade
        guard fade > 0.2 else { player.volume = 1; return }
        fadingIn = true
        player.volume = 0
        let ticks = 8
        let interval = max(0.04, (fade * 0.5) / Double(ticks))
        var step = 0
        fadeInTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                step += 1
                self.player.volume = min(1, Float(step) / Float(ticks))
                if step >= ticks {
                    timer.invalidate(); self.fadeInTimer = nil
                    self.fadingIn = false
                    self.player.volume = 1
                }
            }
        }
    }
    func resume() {
        guard let current, let item = player.currentItem else { return }
        if item.status == .failed { play(current); return }
        do { try AVAudioSession.sharedInstance().setActive(true) } catch { message = error.localizedDescription; return }
        userPaused = false
        player.playImmediately(atRate: rate); playing = true; updateNowPlaying()
        CrashLog.note("Devam")
    }
    func pause() {
        userPaused = true
        player.pause(); playing = false; rememberPosition(); updateNowPlaying()
        CrashLog.note("Duraklatildi")
    }
    private func queueIndex(_ id: UUID) -> Int { max(0, queue.firstIndex(of: id) ?? 0) }
    /// MediaPlayer throws (and kills the app) inside the bridge if a value is not finite, so every
    /// number is cleaned first. NaN used to arrive through a track whose duration failed to load.
    private func safeNumber(_ value: Double) -> NSNumber {
        NSNumber(value: value.isFinite ? max(0, value) : 0)
    }
    func updateNowPlaying() {
        guard let current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.name,
            MPMediaItemPropertyAlbumTitle: "KontYT · Yerel arşiv",
            MPNowPlayingInfoPropertyPlaybackRate: safeNumber(playing ? Double(rate) : 0),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: safeNumber(1),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: safeNumber(elapsed),
            MPMediaItemPropertyPlaybackDuration: safeNumber(duration),
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: current.isVideo ? MPNowPlayingInfoMediaType.video.rawValue : MPNowPlayingInfoMediaType.audio.rawValue),
            MPNowPlayingInfoPropertyPlaybackQueueCount: NSNumber(value: max(1, queue.count)),
            MPNowPlayingInfoPropertyPlaybackQueueIndex: NSNumber(value: queueIndex(current.id))
        ]
        if let image = artwork(for: current), image.size.width >= 1, image.size.height >= 1 {
            let key = current.artworkFilename ?? current.id.uuidString
            let artwork = nowPlayingArtworkCache[key] ?? MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            if nowPlayingArtworkCache.count >= 12 { nowPlayingArtworkCache.removeAll() }
            nowPlayingArtworkCache[key] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
        } else if let coverArtwork { MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = coverArtwork }
        if let channel = current.channel { MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] = channel }
    }
    func remove(_ item: MediaItem) {
        do {
            if current?.id == item.id {
                pause(); player.replaceCurrentItem(with: nil); current = nil
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
            recentlyPlayed.removeAll { $0 == item.id }
            UserDefaults.standard.set(recentlyPlayed.map(\.uuidString), forKey: "recentlyPlayed")
            let source = file(item)
            let trash = mediaFolder.appendingPathComponent(UUID().uuidString + ".pending-delete")
            let hadFile = fm.fileExists(atPath: source.path)
            let previous = items
            if hadFile { try fm.moveItem(at: source, to: trash) }
            do {
                items.removeAll { $0.id == item.id }
                try save()
            } catch {
                items = previous
                if hadFile { try? fm.moveItem(at: trash, to: source) }
                throw error
            }
            if hadFile { try? fm.removeItem(at: trash) }
            queue.removeAll { $0 == item.id }
            orderedQueue.removeAll { $0 == item.id }
            bookmarks.removeAll { $0.itemID == item.id }; saveBookmarks()
            positions.removeValue(forKey: item.id.uuidString)
            UserDefaults.standard.set(positions, forKey: "positions")
            if let filename = item.artworkFilename {
                try? fm.removeItem(at: ArtworkStore.url(filename)); artworkCache.removeValue(forKey: filename); nowPlayingArtworkCache.removeValue(forKey: filename)
            }
            try? fm.removeItem(at: LyricsCache.url(item.id))
            UserDefaults.standard.removeObject(forKey: "lyricsOffset." + item.id.uuidString)
        } catch { message = error.localizedDescription }
    }
}

@main
struct KontYTApp: App {
    @UIApplicationDelegateAdaptor(TransferAppDelegate.self) var delegate
    @StateObject private var library = Library()
    var body: some Scene {
        WindowGroup { StudioRoot().environmentObject(library).preferredColorScheme(.dark)
            .onAppear {
                DownloadCenter.shared.onFile = { [weak library] url, name, identifier, details in
                    guard let library else { throw URLError(.unknown) }
                    try await library.add(url, suggestedName: name, identifier: identifier, details: details)
                }
                DownloadCenter.shared.drainInbox()
            } }
    }
}

struct LibraryRow: View {
    let item: MediaItem
    let selecting: Bool
    let selected: Bool
    let favorite: Bool
    let listed: Bool
    var body: some View {
        HStack(spacing: 14) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.mint : Color.secondary)
            }
            MediaThumbnail(item: item)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).foregroundStyle(.primary).lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.isVideo ? "Çevrimdışı video" : "Çevrimdışı ses")
                        .font(.caption).foregroundStyle(.secondary)
                    if favorite { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink) }
                    if listed { Image(systemName: "music.note.list").font(.caption2).foregroundStyle(.mint) }
                }
            }
            Spacer()
            if !selecting { Image(systemName: "play.circle.fill").foregroundStyle(.mint) }
        }
    }
}

struct LibrarySelectionBar: View {
    let count: Int
    let total: Int
    let allSelected: Bool
    let onFavorite: () -> Void
    let onAddToList: () -> Void
    let onQueue: () -> Void
    let onDelete: () -> Void
    let onToggleAll: () -> Void
    let onDone: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text("\(count)/\(total)").font(.caption.bold()).monospacedDigit()
            Spacer(minLength: 0)
            item("heart.fill", "Favori", Color.pink, count > 0, onFavorite)
            item("music.note.list", "Listeye", Color.mint, count > 0, onAddToList)
            item("text.append", "Sıraya", Color.mint, count > 0, onQueue)
            item(allSelected ? "checkmark.circle.fill" : "checkmark.circle",
                 allSelected ? "Hiçbiri" : "Tümü", Color.mint, total > 0, onToggleAll)
            item("trash.fill", "Sil", Color.red, count > 0, onDelete)
            Button("Bitir", action: onDone).font(.caption.bold()).buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.mint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
    private func item(_ system: String, _ title: String, _ tint: Color, _ enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: system).font(.subheadline)
                Text(title).font(.system(size: 9))
            }
            .foregroundStyle(enabled ? tint : Color.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}

struct LibraryView: View {
    @EnvironmentObject var incoming: IncomingLinks
    @EnvironmentObject var collections: Collections
    @EnvironmentObject var library: Library
    @State private var query = ""
    @State private var importing = false
    @State private var showDownload = false
    @State private var link = ""
    @State private var filter = 0
    @State private var sortOrder = 0
    @State private var favoritesOnly = false
    private enum LibrarySheet: Identifiable {
        case editor(MediaItem), addToList
        var id: String {
            switch self {
            case .editor(let item): return item.id.uuidString
            case .addToList: return "add-to-list"
            }
        }
    }
    @State private var activeSheet: LibrarySheet?
    @State private var selectMode = false
    @State private var selection = Set<UUID>()
    @State private var confirmDelete = false
    @State private var note: String?
    var selectedItems: [MediaItem] { filtered.filter { selection.contains($0.id) } }
    var filtered: [MediaItem] {
        let result = library.items.filter { item in
            (filter == 0 || (filter == 1 && !item.isVideo) || (filter == 2 && item.isVideo)) &&
            (!favoritesOnly || collections.state.favorites.contains(item.id)) &&
            (query.isEmpty || item.name.localizedCaseInsensitiveContains(query))
        }
        switch sortOrder {
        case 1: return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case 2: return result.sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
        case 3: return result.sorted { ($0.duration ?? 0) < ($1.duration ?? 0) }
        default: return result
        }
    }
    private var messageAlert: Binding<Bool> {
        Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })
    }
    private var noteAlert: Binding<Bool> {
        Binding(get: { note != nil }, set: { if !$0 { note = nil } })
    }
    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                typePicker
                if selectMode { selectionBar }
                if library.items.isEmpty { emptyState } else { archiveList }
                if let operation = library.processingTitle { processingBar(operation) }
                if library.busy { busyBar }
            }
            .navigationTitle("KontYT").kontytBrand()
            .searchable(text: $query, prompt: "Arşivde ara")
            .toolbar { toolbarItems }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
                importFiles(result)
            }
            .sheet(item: $activeSheet) { sheet in sheetContent(sheet) }
            .confirmationDialog("\(selection.count) öğe arşivden silinsin mi?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Sil", role: .destructive) { deleteSelection() }
                Button("Vazgeç", role: .cancel) {}
            }
            .alert("Bağlantıdan indir", isPresented: $showDownload) { downloadAlert } message: {
                Text("YouTube veya doğrudan HTTPS ses/video bağlantısı. Aktarımı İndirmeler sekmesinden takip et.")
            }
            .alert("KontYT", isPresented: messageAlert) { Button("Tamam") { library.message = nil } } message: { Text(library.message ?? "") }
            .alert("Liste", isPresented: noteAlert) { Button("Tamam") { note = nil } } message: { Text(note ?? "") }
        }.tint(.mint)
    }

    private var typePicker: some View {
        HStack(spacing: 10) {
            Picker("Tür", selection: $filter) {
                Text("Tümü").tag(0)
                Text("Müzik").tag(1)
                Text("Video").tag(2)
            }
            .pickerStyle(.segmented)
            Button { favoritesOnly.toggle() } label: {
                Image(systemName: favoritesOnly ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(favoritesOnly ? Color.pink : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(favoritesOnly ? "Sadece favoriler açık" : "Sadece favoriler")
        }
        .padding()
    }
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "play.rectangle.on.rectangle.fill").font(.system(size: 64)).foregroundStyle(.mint)
            Text("Arşivin her yerde yanında").font(.title2.bold())
            Text("Dosyalarını ekle, internet olmadan dinle ve izle.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Button("Dosya ekle") { importing = true }.buttonStyle(.borderedProminent).tint(.mint)
            Spacer()
        }
    }
    private var archiveList: some View {
        List {
            ForEach(filtered) { item in
                row(for: item)
            }
        }
        .listStyle(.plain)
    }
    private func row(for item: MediaItem) -> some View {
        Button { activate(item) } label: {
            LibraryRow(item: item,
                       selecting: selectMode,
                       selected: selection.contains(item.id),
                       favorite: collections.state.favorites.contains(item.id),
                       listed: collections.playlistCount(for: item.id) > 0)
        }
        .contextMenu { rowMenu(for: item) }
        .swipeActions { Button("Sil", role: .destructive) { library.remove(item) } }
        .swipeActions(edge: .leading) {
            Button { collections.favorite(item.id) } label: { Label("Favori", systemImage: "heart.fill") }.tint(.pink)
            Button { library.playNext(item) } label: { Label("Sırada sonra", systemImage: "text.line.first.and.arrowtriangle.forward") }.tint(.mint)
        }
    }
    @ViewBuilder private func rowMenu(for item: MediaItem) -> some View {
        Menu("Ses yükseltilmiş M4A kopyası") {
            Button("+3 dB · orijinali koru") { library.boostAudio(item, decibels: 3) }
            Button("+6 dB · bozulma riski artar") { library.boostAudio(item, decibels: 6) }
        }
        Button { library.refreshArtwork(item) } label: { Label("Kapağı / kaynak bilgisini tamamla", systemImage: "photo") }
        if item.isVideo {
            Button { library.repairVideo(item) } label: { Label("MP4’ü yeniden paketle / onar", systemImage: "wrench") }
            Button { library.extractAudio(item) } label: { Label("M4A ses çıkar", systemImage: "waveform") }
        }
        Button { activeSheet = .editor(item) } label: { Label("Başlığı düzenle", systemImage: "pencil") }
        Button { library.playNext(item) } label: { Label("Sırada sonra çal", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { library.addToQueue([item]) } label: { Label("Sıra sonuna ekle", systemImage: "text.append") }
        Button { collections.favorite(item.id) } label: { Label(favoriteLabel(item), systemImage: "heart") }
        Button { selection = [item.id]; activeSheet = .addToList } label: { Label("Listeye ekle…", systemImage: "music.note.list") }
        Button { selection.insert(item.id); selectMode = true } label: { Label("Çoklu seçime ekle", systemImage: "checkmark.circle") }
        ShareLink(item: library.file(item)) { Label("Dosyayı paylaş", systemImage: "square.and.arrow.up") }
        Button("Sil", role: .destructive) { library.remove(item) }
    }
    private func favoriteLabel(_ item: MediaItem) -> String {
        collections.state.favorites.contains(item.id) ? "Favorilerden çıkar" : "Favorilere ekle"
    }
    @ViewBuilder private func processingBar(_ operation: String) -> some View {
        HStack {
            ProgressView()
            Text(operation).font(.caption).lineLimit(1)
            Button("İptal") { library.cancelProcessing() }
        }.padding()
    }
    private var busyBar: some View {
        HStack { ProgressView(); Text("İndiriliyor · uygulamayı açık tut") }.font(.caption).padding()
    }
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button(selectMode ? "Bitti" : "Seç") { toggleSelectMode() }
                .fontWeight(.semibold)
            Menu { toolbarMenuItems } label: { Image(systemName: "plus.circle.fill").foregroundStyle(.mint) }
        }
    }
    @ViewBuilder private var toolbarMenuItems: some View {
        Picker("Sıralama", selection: $sortOrder) {
            Text("Son eklenen").tag(0)
            Text("Başlık A–Z").tag(1)
            Text("Süre · uzun önce").tag(2)
            Text("Süre · kısa önce").tag(3)
        }
        Button { importing = true } label: { Label("Dosyalardan ekle", systemImage: "folder") }
        Button { showDownload = true } label: { Label("Bağlantıdan indir", systemImage: "arrow.down.circle") }
    }
    @ViewBuilder private var selectionBar: some View {
        if selectMode {
            LibrarySelectionBar(count: selection.count,
                                total: filtered.count,
                                allSelected: !filtered.isEmpty && selection.count == filtered.count,
                                onFavorite: favoriteSelection,
                                onAddToList: addSelectionToList,
                                onQueue: queueSelection,
                                onDelete: { confirmDelete = true },
                                onToggleAll: toggleAll,
                                onDone: { toggleSelectMode() })
        }
    }
    @ViewBuilder private func sheetContent(_ sheet: LibrarySheet) -> some View {
        switch sheet {
        case .editor(let item): MediaEditor(item: item).environmentObject(library)
        case .addToList:
            AddToPlaylistSheet(itemIDs: Array(selection)) { text in note = text }
                .environmentObject(collections)
        }
    }
    @ViewBuilder private var downloadAlert: some View {
        TextField("https://…/dosya.mp4", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
        Button("İndir") { submitLink() }
        Button("Vazgeç", role: .cancel) {}
    }
    private func activate(_ item: MediaItem) {
        if selectMode { toggle(item.id); return }
        library.play(item)
        NotificationCenter.default.post(name: .kontytShowPlayer, object: nil)
    }
    private func toggleSelectMode() {
        selectMode.toggle()
        if !selectMode { selection.removeAll() }
    }
    private func toggleAll() {
        if !filtered.isEmpty, selection.count == filtered.count { selection.removeAll() }
        else { selection = Set(filtered.map(\.id)) }
    }
    private func addSelectionToList() {
        guard !selection.isEmpty else { return }
        activeSheet = .addToList
    }
    private func favoriteSelection() {
        collections.toggleFavorite(Array(selection))
        note = "\(selection.count) öğe favori durumu değiştirildi."
    }
    private func queueSelection() {
        library.addToQueue(selectedItems)
        note = "\(selection.count) öğe sıraya eklendi."
    }
    private func deleteSelection() {
        let targets = selectedItems
        library.removeMany(targets)
        selection.removeAll()
        selectMode = false
        note = "\(targets.count) öğe silindi."
    }
    private func importFiles(_ result: Result<[URL], Error>) {
        Task { @MainActor in
            do { for url in try result.get() { try await library.add(url) } }
            catch { library.message = error.localizedDescription }
        }
    }
    private func submitLink() {
        if let url = SharedInbox.extract(link) { incoming.open(url); link = "" }
        else { Task { await library.download(link); link = "" } }
    }
}
