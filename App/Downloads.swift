import SwiftUI
import UIKit

struct DownloadJob: Identifiable, Codable {
    var id = UUID()
    var url: URL
    var name: String
    var status = "Bekliyor"
    var received: Int64 = 0
    var expected: Int64 = 0
    var error: String?
    var resumeData: Data?
    var stagedFile: String?
    var preferredFilename: String?
    var companionAudioURL: URL?
    var stagedAudioFile: String?
    var fetchingAudio: Bool?
    var mergedFile: String?
    var availableAt: Date?
    var sourceVideoID: String?
    var formatID: Int?
    var details: TrackDetails?
    var chunked: Bool?
    var partialFile: String?
    var partialAudioFile: String?
    var totalLength: Int64?
    var audioTotalLength: Int64?
    var pendingChunkFile: String?
    var pendingChunkStart: Int64?
    var pendingChunkEnd: Int64?
}

// URLSession callbacks and all public operations are dispatched on the main queue.
final class DownloadCenter: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadCenter()
    static let sessionID = "com.kontyt.transfers.v1"
    static var backgroundCompletion: (() -> Void)?
    @Published var jobs: [DownloadJob] = []
    @Published var stateError: String?
    @Published var speeds: [UUID: Double] = [:]
    private var progressUpdates: [UUID: Date] = [:]
    private var samples: [UUID: (date: Date, bytes: Int64)] = [:]
    var onFile: ((URL, String, UUID, TrackDetails?) async throws -> Void)?
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var merges: [UUID: Task<Void, Never>] = [:]
    private var appends: [UUID: Task<Void, Never>] = [:]
    private let fm = FileManager.default
    private var restoring = true
    private var backgroundEventsFinished = false
    private var foreground = false
    func setForeground(_ active: Bool) { foreground = active }
    private var root: URL { fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Transfers", isDirectory: true) }
    private var index: URL { root.appendingPathComponent("jobs.json") }
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true; config.isDiscretionary = false; config.httpMaximumConnectionsPerHost = 2
        config.waitsForConnectivity = true; config.allowsCellularAccess = true; config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    private override init() {
        super.init()
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            if fm.fileExists(atPath: index.path) { jobs = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: index)) }
        } catch { stateError = "İndirme geçmişi okunamadı: " + error.localizedDescription }
        session.getAllTasks { active in
            DispatchQueue.main.async {
                for task in active {
                    if let id = task.taskDescription.flatMap(UUID.init(uuidString:)), let download = task as? URLSessionDownloadTask,
                       self.jobs.contains(where: { $0.id == id && $0.status != "İptal edildi" }) { self.tasks[id] = download }
                    else { task.cancel() }
                }
                for i in self.jobs.indices {
                    if ["İndiriliyor", "Ses indiriliyor", "Duraklatılıyor"].contains(self.jobs[i].status), self.tasks[self.jobs[i].id] == nil { self.jobs[i].status = "Duraklatıldı" }
                    if self.jobs[i].status == "Yeniden sorgulanıyor" { self.jobs[i].status = "Hata"; self.jobs[i].error = "Adres yenileme kesildi; yeniden dene." }
                    if ["Birleştiriliyor", "Doğrulanıyor"].contains(self.jobs[i].status) { self.jobs[i].status = "İşleme bekliyor" }
                }
                // Only successful terminal jobs are history; keep active, paused and failed work.
                self.jobs.removeAll { $0.status == "Tamamlandı" && self.tasks[$0.id] == nil }
                self.restoring = false; self.persist(); self.drainChunks(); self.drainInbox(); self.pump()
            }
        }
    }
    @discardableResult private func persist() -> Bool {
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: index, options: .atomic)
            return true
        } catch { stateError = "İndirme geçmişi kaydedilemedi: " + error.localizedDescription; return false }
    }
    @discardableResult func enqueue(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              !(host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")) else { return false }
        jobs.insert(DownloadJob(url: url, name: url.lastPathComponent.isEmpty ? "Medya" : url.lastPathComponent), at: 0)
        guard persist() else { jobs.removeFirst(); return false }
        pump(); return true
    }
    @discardableResult func enqueueResolved(_ format: YouTubeMediaFormat, title: String) -> Bool {
        func allowed(_ url: URL) -> Bool {
            guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
            return host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
        }
        guard allowed(format.url), format.companionAudioURL.map(allowed) ?? true else { return false }
        if let videoID = format.sourceVideoID, jobs.contains(where: { $0.sourceVideoID == videoID && $0.formatID == format.id && !["Tamamlandı", "İptal edildi", "Hata", "İşleme hatası", "Arşiv hatası"].contains($0.status) }) { return true }
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r")).joined(separator: " ")
        let name = String(safe.prefix(160)) + "." + format.ext
        var job = DownloadJob(url: format.url, name: name)
        job.preferredFilename = name; job.companionAudioURL = format.companionAudioURL; job.details = format.details
        job.availableAt = format.availableAt; job.sourceVideoID = format.sourceVideoID; job.formatID = format.id
        job.chunked = UserDefaults.standard.object(forKey: "chunkedTransfers") as? Bool ?? true
        job.totalLength = format.contentLength; job.audioTotalLength = format.audioContentLength
        jobs.insert(job, at: 0)
        guard persist() else { jobs.removeFirst(); return false }
        pump(); return true
    }
    private func pump() {
        guard !restoring else { return }
        while tasks.count < 2, let i = jobs.lastIndex(where: { ["Bekliyor", "Ses bekliyor"].contains($0.status) && tasks[$0.id] == nil }) {
            if jobs[i].status == "Ses bekliyor" { jobs[i].fetchingAudio = true; jobs[i].received = 0; jobs[i].expected = 0 }
            let isAudio = jobs[i].fetchingAudio == true
            let offset = partialSize(jobs[i])
            let total = isAudio ? jobs[i].audioTotalLength : jobs[i].totalLength
            if jobs[i].chunked == true { jobs[i].received = offset; jobs[i].expected = total ?? 0 }
            if jobs[i].chunked == true, let total, total > 0, offset == total,
               let path = isAudio ? jobs[i].partialAudioFile : jobs[i].partialFile {
                acceptPart(i, path: path); drainInbox(); continue
            }
            let task: URLSessionDownloadTask
            if let data = jobs[i].resumeData, jobs[i].chunked != true { task = session.downloadTask(withResumeData: data) }
            else {
                let url = isAudio ? jobs[i].companionAudioURL ?? jobs[i].url : jobs[i].url
                var request = URLRequest(url: url)
                if url.host?.hasSuffix(".googlevideo.com") == true {
                    request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
                    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                }
                if jobs[i].chunked == true, let header = TransferRange.header(offset: offset, total: total, openEnded: !foreground) { request.setValue(header, forHTTPHeaderField: "Range") }
                task = session.downloadTask(with: request)
            }
            let id = jobs[i].id; task.taskDescription = id.uuidString
            task.earliestBeginDate = jobs[i].availableAt
            samples[id] = (Date(), offset)
            tasks[id] = task; jobs[i].status = isAudio ? "Ses indiriliyor" : "İndiriliyor"; jobs[i].error = nil
            task.resume()
        }
        persist()
    }
    func pause(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), let task = tasks[id], ["İndiriliyor", "Ses indiriliyor"].contains(jobs[i].status) else { return }
        jobs[i].status = "Duraklatılıyor"; persist()
        if jobs[i].chunked == true { jobs[i].resumeData = nil; task.cancel(); return }
        task.cancel(byProducingResumeData: { data in
            DispatchQueue.main.async {
                if let i = self.jobs.firstIndex(where: { $0.id == id }), ["Duraklatılıyor", "Duraklatıldı"].contains(self.jobs[i].status) {
                    self.jobs[i].resumeData = data; self.jobs[i].status = "Duraklatıldı"; self.persist()
                }
            }
        })
    }
    func retry(_ id: UUID) {
        guard tasks[id] == nil, merges[id] == nil, appends[id] == nil, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].error = nil
        if jobs[i].pendingChunkFile != nil { jobs[i].status = "Parça yazılıyor"; drainChunks(); return }
        if jobs[i].stagedFile != nil && (jobs[i].companionAudioURL == nil || jobs[i].stagedAudioFile != nil) {
            jobs[i].status = "İşleme bekliyor"; drainInbox()
        } else { jobs[i].status = jobs[i].stagedFile != nil && jobs[i].companionAudioURL != nil ? "Ses bekliyor" : "Bekliyor"; pump() }
        persist()
    }
    func refreshAndRetry(_ id: UUID) {
        guard tasks[id] == nil, merges[id] == nil, appends[id] == nil, let i = jobs.firstIndex(where: { $0.id == id }), let videoID = jobs[i].sourceVideoID else { return }
        jobs[i].status = "Yeniden sorgulanıyor"; jobs[i].error = nil; persist()
        Task { @MainActor in
            do {
                let options = try await YouTubeWebClient.shared.mediaOptions(for: videoID)
                guard let current = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[current].status == "Yeniden sorgulanıyor" else { return }
                guard let format = options.formats.first(where: { $0.id == self.jobs[current].formatID }) else {
                    throw YouTubeMediaError.unavailable("Önceden seçilen kalite artık yok. YouTube sonucundan yeniden biçim seç.")
                }
                self.cleanup(current)
                self.jobs[current].url = format.url; self.jobs[current].companionAudioURL = format.companionAudioURL; self.jobs[current].details = format.details
                self.jobs[current].chunked = UserDefaults.standard.object(forKey: "chunkedTransfers") as? Bool ?? true
                self.jobs[current].totalLength = format.contentLength; self.jobs[current].audioTotalLength = format.audioContentLength
                self.jobs[current].availableAt = format.availableAt; self.jobs[current].resumeData = nil
                self.jobs[current].fetchingAudio = false; self.jobs[current].received = 0; self.jobs[current].expected = 0
                self.jobs[current].status = "Bekliyor"; self.persist(); self.pump()
            } catch {
                if let current = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[current].status == "Yeniden sorgulanıyor" {
                    self.jobs[current].status = "Hata"; self.jobs[current].error = error.localizedDescription; self.persist()
                }
            }
        }
    }
    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].status = "İptal edildi"; jobs[i].resumeData = nil
        tasks[id]?.cancel(); merges[id]?.cancel(); appends[id]?.cancel()
        if merges[id] == nil && appends[id] == nil { cleanup(i) }
        persist(); pump()
    }
    func clearFinished() {
        jobs.removeAll { ["Tamamlandı", "İptal edildi"].contains($0.status) && tasks[$0.id] == nil && merges[$0.id] == nil && appends[$0.id] == nil }
        persist()
    }
    private func cleanupCancelled(_ id: UUID) {
        if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status == "İptal edildi" { cleanup(i); persist() }
    }
    private func cleanup(_ i: Int) {
        for path in [jobs[i].stagedFile, jobs[i].stagedAudioFile, jobs[i].mergedFile, jobs[i].partialFile, jobs[i].partialAudioFile, jobs[i].pendingChunkFile].compactMap({ $0 }) { try? fm.removeItem(at: root.appendingPathComponent(path)) }
        jobs[i].stagedFile = nil; jobs[i].stagedAudioFile = nil; jobs[i].mergedFile = nil; jobs[i].partialFile = nil; jobs[i].partialAudioFile = nil; jobs[i].pendingChunkFile = nil; jobs[i].pendingChunkStart = nil; jobs[i].pendingChunkEnd = nil
    }
    func drainInbox() {
        guard onFile != nil else { return }
        let ready = jobs.filter { ["İşleme bekliyor", "Arşive aktarılıyor"].contains($0.status) && $0.stagedFile != nil && ($0.companionAudioURL == nil || $0.stagedAudioFile != nil) }.map(\.id)
        for id in ready where merges[id] == nil {
            merges[id] = Task { @MainActor in
                let bg = UIApplication.shared.beginBackgroundTask(withName: "KontYT processing") { self.merges[id]?.cancel() }
                defer {
                    if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
                    self.merges.removeValue(forKey: id); self.cleanupCancelled(id); self.finishBackgroundEventsIfReady()
                }
                await self.processJob(id)
            }
        }
    }
    @MainActor private func processJob(_ id: UUID) async {
        guard let onFile, let i = jobs.firstIndex(where: { $0.id == id }), let staged = jobs[i].stagedFile else { return }
        var newOutput: URL?
        do {
            var source = root.appendingPathComponent(staged)
            let ext = (jobs[i].name as NSString).pathExtension.lowercased()
            if source.pathExtension == "incoming" {
                let typed = root.appendingPathComponent(id.uuidString + ".source." + (ext.isEmpty ? "mp4" : ext))
                if fm.fileExists(atPath: typed.path) { try fm.removeItem(at: typed) }
                try fm.moveItem(at: source, to: typed); source = typed; jobs[i].stagedFile = typed.lastPathComponent
            }
            let snapshot = jobs[i]
            if snapshot.companionAudioURL != nil, let audio = snapshot.stagedAudioFile {
                if let merged = snapshot.mergedFile, fm.fileExists(atPath: root.appendingPathComponent(merged).path) { source = root.appendingPathComponent(merged) }
                else {
                    jobs[i].status = "Birleştiriliyor"; persist()
                    let output = root.appendingPathComponent(id.uuidString + ".merged.mp4"); newOutput = output
                    try? fm.removeItem(at: output)
                    try await MediaProcessor.merge(video: source, audio: root.appendingPathComponent(audio), output: output)
                    try Task.checkCancellation()
                    guard let current = jobs.firstIndex(where: { $0.id == id }), jobs[current].status != "İptal edildi" else { throw CancellationError() }
                    jobs[current].mergedFile = output.lastPathComponent; source = output
                }
            }
            guard let current = jobs.firstIndex(where: { $0.id == id }), jobs[current].status != "İptal edildi" else { throw CancellationError() }
            jobs[current].status = "Doğrulanıyor"; persist()
            let job = jobs[current]
            let details = job.details ?? job.sourceVideoID.map { TrackDetails(videoID: $0, title: (job.name as NSString).deletingPathExtension, channel: "") }
            try await onFile(source, job.name, id, details)
            guard let completed = jobs.firstIndex(where: { $0.id == id }), jobs[completed].status != "İptal edildi" else { return }
            // onFile has successfully imported the media; only remove the transfer history.
            cleanup(completed); jobs.remove(at: completed); persist()
        } catch {
            if let newOutput { try? fm.removeItem(at: newOutput) }
            if let current = jobs.firstIndex(where: { $0.id == id }), jobs[current].status != "İptal edildi" {
                jobs[current].mergedFile = nil
                jobs[current].status = "İşleme hatası"; jobs[current].error = error.localizedDescription; persist()
            }
        }
    }
    func drainChunks() {
        let ready = jobs.filter { $0.status == "Parça yazılıyor" && $0.pendingChunkFile != nil }.map(\.id)
        for id in ready where appends[id] == nil {
            appends[id] = Task { @MainActor in
                let background = UIApplication.shared.beginBackgroundTask(withName: "KontYT assemble bytes") { self.appends[id]?.cancel() }
                defer {
                    if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
                    self.appends.removeValue(forKey: id); self.cleanupCancelled(id); self.finishBackgroundEventsIfReady()
                }
                guard let i = self.jobs.firstIndex(where: { $0.id == id }), let chunk = self.jobs[i].pendingChunkFile,
                      let start = self.jobs[i].pendingChunkStart, let end = self.jobs[i].pendingChunkEnd,
                      let path = self.jobs[i].fetchingAudio == true ? self.jobs[i].partialAudioFile : self.jobs[i].partialFile else { return }
                let source = self.root.appendingPathComponent(chunk), output = self.root.appendingPathComponent(path)
                do {
                    let currentSize = self.partialSize(self.jobs[i])
                    if currentSize != end + 1 { try await TransferRange.appendOffMain(source, to: output, expectedOffset: start) }
                    let assembledBytes = try DiskFile.size(output)
                    guard assembledBytes == end + 1 else { throw YouTubeMediaError.unavailable("Birleştirilen parça boyutu beklenen sınırla uyuşmuyor.") }
                    try Task.checkCancellation()
                    guard let current = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[current].status != "İptal edildi" else { return }
                    self.jobs[current].pendingChunkFile = nil; self.jobs[current].pendingChunkStart = nil; self.jobs[current].pendingChunkEnd = nil
                    try? self.fm.removeItem(at: source)
                    let total = self.jobs[current].fetchingAudio == true ? self.jobs[current].audioTotalLength ?? 0 : self.jobs[current].totalLength ?? 0
                    self.jobs[current].received = end + 1; self.jobs[current].expected = total
                    if end + 1 == total { self.acceptPart(current, path: path); self.drainInbox() }
                    else { self.jobs[current].status = self.jobs[current].fetchingAudio == true ? "Ses bekliyor" : "Bekliyor" }
                    self.persist(); self.pump()
                } catch {
                    if let current = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[current].status != "İptal edildi" {
                        self.jobs[current].status = "Hata"; self.jobs[current].error = "Parça birleştirme: " + error.localizedDescription; self.persist()
                    }
                }
            }
        }
    }
    private func partialSize(_ job: DownloadJob) -> Int64 {
        guard let path = job.fetchingAudio == true ? job.partialAudioFile : job.partialFile else { return 0 }
        return (try? DiskFile.size(root.appendingPathComponent(path))) ?? 0
    }
    private func acceptPart(_ i: Int, path: String) {
        jobs[i].resumeData = nil
        if jobs[i].fetchingAudio == true {
            jobs[i].stagedAudioFile = path; jobs[i].partialAudioFile = nil; jobs[i].status = "İşleme bekliyor"
        } else {
            jobs[i].stagedFile = path; jobs[i].partialFile = nil
            jobs[i].status = jobs[i].companionAudioURL == nil ? "Arşive aktarılıyor" : "Ses bekliyor"
        }
        persist()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)), let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let tick = Date()
        if let last = progressUpdates[id], tick.timeIntervalSince(last) < 0.5 { return }
        progressUpdates[id] = tick
        if jobs[i].chunked == true, let response = downloadTask.response as? HTTPURLResponse,
           let header = response.value(forHTTPHeaderField: "Content-Range"), let range = HTTPContentRange(header) {
            if jobs[i].fetchingAudio == true, jobs[i].audioTotalLength == nil { jobs[i].audioTotalLength = range.total }
            else if jobs[i].fetchingAudio != true, jobs[i].totalLength == nil { jobs[i].totalLength = range.total }
        }
        let offset = jobs[i].chunked == true ? partialSize(jobs[i]) : 0
        jobs[i].received = offset + totalBytesWritten
        jobs[i].expected = jobs[i].chunked == true ? (jobs[i].fetchingAudio == true ? jobs[i].audioTotalLength ?? 0 : jobs[i].totalLength ?? 0) : totalBytesExpectedToWrite
        let now = Date()
        if let sample = samples[id], now.timeIntervalSince(sample.date) >= 0.75 {
            let instant = max(0, Double(jobs[i].received - sample.bytes)) / now.timeIntervalSince(sample.date)
            speeds[id] = (speeds[id] ?? 0) > 0 ? (speeds[id]! * 0.5 + instant * 0.5) : instant
            samples[id] = (now, jobs[i].received)
        }
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage,
           available < max(Int64(100 * 1024 * 1024), totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite - totalBytesWritten + 100 * 1024 * 1024 : 0) {
            jobs[i].status = "Hata"; jobs[i].error = "Yeterli boş alan yok."; downloadTask.cancel(); persist()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)), let i = jobs.firstIndex(where: { $0.id == id }), ["İndiriliyor", "Ses indiriliyor"].contains(jobs[i].status) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                throw YouTubeMediaError.unavailable("Sunucu dosyayı vermedi (HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)). Adres süresi dolmuş olabilir; YouTube’dan yeniden sorgula.")
            }
            let mime = response.mimeType?.lowercased() ?? ""
            guard !mime.contains("text/html"), !mime.contains("application/json") else { throw URLError(.cannotDecodeContentData) }
            let isAudio = jobs[i].fetchingAudio == true
            jobs[i].name = jobs[i].preferredFilename ?? response.suggestedFilename ?? jobs[i].name
            let ext = (jobs[i].name as NSString).pathExtension.lowercased()
            let staged = id.uuidString + (isAudio ? ".audio.m4a" : ".source." + (ext.isEmpty ? "mp4" : ext))
            if jobs[i].chunked == true, response.statusCode == 206 {
                let offset = partialSize(jobs[i])
                let bytes = try DiskFile.size(location)
                guard let header = response.value(forHTTPHeaderField: "Content-Range"), let range = HTTPContentRange(header), range.start == offset, bytes == range.end - range.start + 1 else { throw YouTubeMediaError.unavailable("Sunucunun parça yanıtı geçersiz; dosyaya eklenmedi.") }
                let previousTotal = isAudio ? jobs[i].audioTotalLength : jobs[i].totalLength
                if let previousTotal, previousTotal != range.total { throw YouTubeMediaError.unavailable("Kaynak boyutu değişti; YouTube adresini yenileyip baştan indir.") }
                let partial = id.uuidString + (isAudio ? ".partial.audio.m4a" : ".partial." + (ext.isEmpty ? "mp4" : ext))
                if isAudio { jobs[i].partialAudioFile = partial; jobs[i].audioTotalLength = range.total }
                else { jobs[i].partialFile = partial; jobs[i].totalLength = range.total }
                persist()
                let chunk = id.uuidString + ".chunk.download"
                let destination = root.appendingPathComponent(chunk)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: location, to: destination)
                jobs[i].pendingChunkFile = chunk; jobs[i].pendingChunkStart = range.start; jobs[i].pendingChunkEnd = range.end
                jobs[i].status = "Parça yazılıyor"; persist(); drainChunks()
            } else {
                let bytes = try DiskFile.size(location)
                let expected = isAudio ? jobs[i].audioTotalLength : jobs[i].totalLength
                if let expected, expected > 0, bytes != expected { throw YouTubeMediaError.unavailable("İndirilen boyut eksik/uyuşmuyor. Beklenen \(expected), alınan \(bytes) byte.") }
                let target = root.appendingPathComponent(staged)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: location, to: target)
                if let old = isAudio ? jobs[i].partialAudioFile : jobs[i].partialFile { try? fm.removeItem(at: root.appendingPathComponent(old)) }
                acceptPart(i, path: staged)
            }
            persist(); drainInbox()
        } catch { jobs[i].status = "Hata"; jobs[i].error = error.localizedDescription; persist() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        tasks.removeValue(forKey: id)
        progressUpdates.removeValue(forKey: id)
        if let sample = samples.removeValue(forKey: id), let job = jobs.first(where: { $0.id == id }), Date().timeIntervalSince(sample.date) > 0 {
            let rate = max(0, Double(job.received - sample.bytes)) / Date().timeIntervalSince(sample.date)
            if rate > 0 { speeds[id] = rate }
        }
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { pump(); return }
        if jobs[i].status == "Duraklatılıyor" { jobs[i].status = "Duraklatıldı" }
        else if let error = error as NSError?, ["İndiriliyor", "Ses indiriliyor"].contains(jobs[i].status) {
            jobs[i].status = "Hata"; jobs[i].error = error.localizedDescription
            jobs[i].resumeData = jobs[i].chunked == true ? nil : error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        }
        persist(); pump()
    }
    private func finishBackgroundEventsIfReady() {
        guard backgroundEventsFinished, appends.isEmpty, merges.isEmpty else { return }
        backgroundEventsFinished = false
        let completion = Self.backgroundCompletion; Self.backgroundCompletion = nil
        completion?()
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundEventsFinished = true
        finishBackgroundEventsIfReady()
    }
}

final class TransferAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Before anything else: a tiny breadcrumb file so a silent close can still be explained.
        CrashLog.install()
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DownloadCenter.sessionID else { completionHandler(); return }
        DownloadCenter.backgroundCompletion = completionHandler
        _ = DownloadCenter.shared
    }
}
struct DownloadsView: View {
    @EnvironmentObject var incoming: IncomingLinks
    @EnvironmentObject var flow: ImportFlow
    @ObservedObject private var center = DownloadCenter.shared
    @State private var link = ""
    @State private var invalid = false
    @State private var showFinishedTransfers = false
    @State private var showFinishedResolve = false
    // Bulk lists can hold hundreds of rows. Rendering only what is still moving keeps the
    // list responsive while a playlist is being transferred.
    private static let rowLimit = 60
    private var visibleResolveJobs: [ResolveJob] {
        let active = flow.jobs.filter { !["İndirme sırasına aktarıldı", "İptal"].contains($0.status) }
        let shown = showFinishedResolve ? flow.jobs : active
        return Array(shown.prefix(Self.rowLimit))
    }
    private var visibleTransfers: [DownloadJob] {
        let active = center.jobs.filter { !["Tamamlandı", "İptal edildi"].contains($0.status) }
        let shown = showFinishedTransfers ? center.jobs : active
        return Array(shown.prefix(Self.rowLimit))
    }
    var body: some View {
        NavigationStack {
            List {
                linkSection
                if !flow.jobs.isEmpty { resolveSection }
                if let error = center.stateError { Section("Kayıt hatası") { Text(error).foregroundStyle(.orange) } }
                transferSection
            }
            .navigationTitle("İndirme merkezi").kontytBrand()
            .alert("Bağlantı desteklenmiyor", isPresented: $invalid) { Button("Tamam", role: .cancel) {} } message: {
                Text("Geçerli YouTube veya doğrudan HTTPS medya bağlantısı gir.")
            }
        }
    }
    private var linkSection: some View {
        Section("YouTube veya doğrudan medya bağlantısı") {
            TextField("YouTube / https://…/dosya.mp4", text: $link)
                .onSubmit { submitLink() }
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Button("Kuyruğa ekle") { submitLink() }
            Text("Aynı anda iki aktarım. iOS arka plan zamanlamasını yönetir; uygulamayı zorla kapatırsan aktarımlar durabilir. Devam ettirme sunucuya bağlıdır.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var resolveSection: some View {
        Section("Bağlantı çözümleme sırası") {
            HStack {
                Button("Devam") { flow.resume() }
                Spacer()
                Button("Duraklat") { flow.pauseResolution() }
                Spacer()
                Button("Geçmişi temizle") { flow.clearHistory() }
            }.buttonStyle(.borderless)
            Toggle("Aktarılanları da göster", isOn: $showFinishedResolve).font(.caption)
            Text("\(flow.jobs.count) kayıt · listede \(visibleResolveJobs.count) satır")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(visibleResolveJobs) { job in resolveRow(job) }
            if let message = flow.message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
    }
    private func resolveRow(_ job: ResolveJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.video.title).font(.headline).lineLimit(2)
            Text(job.status).font(.caption).foregroundStyle(.secondary)
            if let error = job.error { Text(error).font(.caption).foregroundStyle(.orange) }
            resolveActions(job)
        }
    }
    private func resolveActions(_ job: ResolveJob) -> some View {
        HStack {
            if job.status == "Hata" { Button("Yeniden dene") { flow.retry(job.id) } }
            Button("Kaydı sil", role: .destructive) { flow.remove(job.id) }
            if ["Bekliyor", "Çözülüyor"].contains(job.status) { Button("İptal", role: .destructive) { flow.cancel(job.id) } }
        }.buttonStyle(.borderless)
    }
    private var transferSection: some View {
        Section("Aktarımlar") {
            HStack {
                Button("Tamamlanan/iptal edilen geçmişi temizle") { center.clearFinished() }
                Spacer()
                Toggle("Geçmiş", isOn: $showFinishedTransfers).labelsHidden()
            }.buttonStyle(.borderless)
            if center.jobs.isEmpty { Text("Kuyruk boş").foregroundStyle(.secondary) }
            else if visibleTransfers.isEmpty { Text("Etkin aktarım yok. Geçmiş düğmesini aç.").font(.caption).foregroundStyle(.secondary) }
            Text("\(center.jobs.count) kayıt · listede \(visibleTransfers.count) satır").font(.caption2).foregroundStyle(.secondary)
            ForEach(visibleTransfers) { job in transferRow(job) }
        }
    }
    private func transferRow(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.name).font(.headline).lineLimit(2)
            if job.expected > 0 { ProgressView(value: min(Double(job.received) / Double(job.expected), 1)) }
            transferStatus(job)
            if let error = job.error { Text(error).font(.caption).foregroundStyle(.orange) }
            transferActions(job)
        }.padding(.vertical, 6)
    }
    private func transferStatus(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(job.status) · \(ByteCountFormatter.string(fromByteCount: job.received, countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
            if let speed = center.speeds[job.id], speed > 0, ["İndiriliyor", "Ses indiriliyor", "Parça yazılıyor"].contains(job.status) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/sn")
                    .font(.caption.monospacedDigit()).foregroundStyle(.mint)
            }
        }
    }
    private func transferActions(_ job: DownloadJob) -> some View {
        HStack {
            if ["İndiriliyor", "Ses indiriliyor"].contains(job.status) { Button("Duraklat") { center.pause(job.id) } }
            if ["Duraklatıldı", "Hata", "İşleme hatası", "Arşiv hatası"].contains(job.status) {
                Button(job.stagedFile != nil ? "Dosyayı yeniden doğrula / kurtar" : "Devam / yeniden dene") { center.retry(job.id) }
                if job.sourceVideoID != nil { Button("YouTube adresini yenile") { center.refreshAndRetry(job.id) } }
            }
            if !["Tamamlandı", "İptal edildi"].contains(job.status) { Button("İptal", role: .destructive) { center.cancel(job.id) } }
        }.buttonStyle(.borderless)
    }
    private func submitLink() {
        if let url = SharedInbox.extract(link) { incoming.open(url); link = ""; return }
        invalid = !center.enqueue(link)
        if !invalid { link = "" }
    }
}
