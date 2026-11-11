import SwiftUI
import UIKit

enum ImportPreferences {
    static var audioOnly: Bool { UserDefaults.standard.bool(forKey: "preferAudioOnly") }
    static var maxHeight: Int { UserDefaults.standard.object(forKey: "maxVideoHeight") as? Int ?? 720 }
    static var preferCombined: Bool { UserDefaults.standard.object(forKey: "preferCombined") as? Bool ?? true }
}
enum FormatSelection {
    static func best(_ formats: [YouTubeMediaFormat], audioOnly: Bool, maxHeight: Int, preferCombined: Bool) -> YouTubeMediaFormat? {
        let candidates = formats.filter { $0.audioOnly == audioOnly }
        if audioOnly { return candidates.max { $0.bitrate < $1.bitrate } }
        let fitting = maxHeight == 0 ? candidates : candidates.filter { $0.height <= maxHeight }
        let pool = fitting.isEmpty ? candidates.sorted { $0.height < $1.height }.prefix(1).map { $0 } : fitting
        if preferCombined, let combined = pool.filter({ $0.companionAudioURL == nil }).max(by: { $0.height < $1.height }) { return combined }
        return pool.max { lhs, rhs in lhs.height == rhs.height ? lhs.bitrate < rhs.bitrate : lhs.height < rhs.height }
    }
}
struct ResolveJob: Identifiable, Codable {
    var id = UUID()
    var video: SavedVideo
    var audioOnly: Bool
    var maxHeight: Int
    var preferCombined: Bool
    var status = "Bekliyor"
    var error: String?
}
@MainActor final class ImportFlow: ObservableObject {
    @Published var jobs: [ResolveJob] = []
    @Published var working = false
    @Published var event = 0
    @Published var message: String?
    private var worker: Task<Void, Never>?
    private var resumeAfterWorker = false
    private let stateURL: URL
    private let automaticallyResolve: Bool
    init(stateURL: URL? = nil, automaticallyResolve: Bool = true) {
        self.stateURL = stateURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("resolve-jobs.json")
        self.automaticallyResolve = automaticallyResolve
        do {
            if FileManager.default.fileExists(atPath: self.stateURL.path) { jobs = try JSONDecoder().decode([ResolveJob].self, from: Data(contentsOf: self.stateURL)) }
            for i in jobs.indices where jobs[i].status == "Çözülüyor" { jobs[i].status = "Bekliyor" }
        } catch { message = "Bağlantı kuyruğu okunamadı: " + error.localizedDescription }
    }
    @discardableResult private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: stateURL, options: .atomic)
            return true
        } catch { message = "Bağlantı kuyruğu kaydedilemedi: " + error.localizedDescription; return false }
    }
    @discardableResult func enqueue(_ videos: [SavedVideo], audioOnly: Bool? = nil) -> Bool {
        guard !videos.isEmpty else { return false }
        let previous = jobs
        let selectedAudioOnly = audioOnly ?? ImportPreferences.audioOnly
        func key(_ id: String, _ audio: Bool) -> String { id + (audio ? ":audio" : ":video") }
        var active = Set(jobs.filter { ["Bekliyor", "Çözülüyor"].contains($0.status) }.map { key($0.video.id, $0.audioOnly) })
        // Build the batch first and publish once: appending inside the loop fired one
        // @Published change per playlist entry, which is what made large lists stall the UI.
        var added: [ResolveJob] = []
        added.reserveCapacity(videos.count)
        for video in videos where active.insert(key(video.id, selectedAudioOnly)).inserted {
            added.append(ResolveJob(video: video, audioOnly: selectedAudioOnly, maxHeight: ImportPreferences.maxHeight, preferCombined: ImportPreferences.preferCombined))
        }
        guard !added.isEmpty else { return true }
        jobs.append(contentsOf: added)
        guard save() else { jobs = previous; return false }
        message = nil; event += 1; if automaticallyResolve { resume() }; return true
    }
    func resume() {
        if let worker { if worker.isCancelled { resumeAfterWorker = true }; return }
        guard jobs.contains(where: { $0.status == "Bekliyor" }) else { return }
        working = true
        worker = Task { @MainActor in
            let background = UIApplication.shared.beginBackgroundTask(withName: "KontYT resolve links") { self.worker?.cancel() }
            defer {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
                self.worker = nil; self.working = false
                if self.resumeAfterWorker { self.resumeAfterWorker = false; self.resume() }
            }
            while !Task.isCancelled, let i = self.jobs.firstIndex(where: { $0.status == "Bekliyor" }) {
                let snapshot = self.jobs[i], id = snapshot.id
                self.jobs[i].status = "Çözülüyor"; self.jobs[i].error = nil
                guard self.save() else { self.jobs[i].status = "Bekliyor"; break }
                do {
                    let options = try await YouTubeWebClient.shared.mediaOptions(for: snapshot.video.id)
                    try Task.checkCancellation()
                    guard let index = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[index].status != "İptal" else { continue }
                    guard let format = FormatSelection.best(options.formats, audioOnly: snapshot.audioOnly, maxHeight: snapshot.maxHeight, preferCombined: snapshot.preferCombined) else { throw YouTubeMediaError.unavailable("Tercih edilen ses/video biçimi bulunamadı. Ayarlar'dan türü değiştirip yeniden dene.") }
                    let title = options.title ?? snapshot.video.title
                    guard DownloadCenter.shared.enqueueResolved(format, title: title) else { throw YouTubeMediaError.unavailable("Biçim indirme sırasına eklenemedi.") }
                    self.jobs[index].video.title = title; self.jobs[index].status = "İndirme sırasına aktarıldı"
                } catch {
                    if let index = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[index].status != "İptal" {
                        self.jobs[index].status = Task.isCancelled ? "Bekliyor" : "Hata"
                        self.jobs[index].error = Task.isCancelled ? nil : error.localizedDescription
                    }
                }
                self.save()
                // A server cooldown is shared; do not mark every remaining playlist entry failed.
                if self.jobs.first(where: { $0.id == id })?.status == "Hata",
                   self.jobs.first(where: { $0.id == id })?.error?.contains("HTTP 429") == true { break }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    func retry(_ id: UUID) { if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].status = "Bekliyor"; jobs[i].error = nil; save(); resume() } }
    func cancel(_ id: UUID) { if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].status = "İptal"; save() } }
    func pauseResolution() { worker?.cancel() }
    func remove(_ id: UUID) {
        let previous = jobs
        jobs.removeAll { $0.id == id }
        if !save() { jobs = previous }
        // An in-flight worker checks the ID again before handing anything to DownloadCenter.
    }
    func clearHistory() {
        let previous = jobs
        jobs.removeAll { ["Hata", "İptal", "İndirme sırasına aktarıldı"].contains($0.status) }
        if !save() { jobs = previous }
    }
}
