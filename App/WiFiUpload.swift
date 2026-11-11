import SwiftUI
import Network
import Darwin

// A LAN HTTP receiver owned by the app, not by the settings screen. Uploads stream to disk,
// never into one large Data. It keeps serving while the user navigates elsewhere, and stops
// when the app leaves the foreground or is terminated.
@MainActor final class WiFiUploadServer: ObservableObject {
    static let shared = WiFiUploadServer()
    @Published var address = ""
    @Published var code = ""
    @Published var running = false
    @Published var message = ""
    /// The user asked for the receiver; it survives screen changes and is restored on foreground.
    @Published private(set) var enabled = false
    private var listener: NWListener?
    private var clients: [UUID: UploadClient] = [:]
    var onFile: ((URL, String) async throws -> Void)?
    private init() {}
    /// Called by the root view whenever the scene becomes active or backgrounded.
    func setForeground(_ active: Bool) {
        if active {
            guard enabled, listener == nil else { return }
            openListener()
        } else {
            closeListener(keepEnabled: true)
            message = "Uygulama arka planda; Wi-Fi yükleme duraklatıldı. Öne gelince yeniden açılır."
        }
    }
    func start() {
        enabled = true
        openListener()
    }
    func stop() {
        enabled = false
        closeListener(keepEnabled: false)
        address = ""; code = ""
    }
    private func openListener() {
        closeListener(keepEnabled: true)
        code = String(Int.random(in: 100000...999999))
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .wifi
            let server = try NWListener(using: parameters, on: 8080)
            listener = server
            server.stateUpdateHandler = { [weak self, weak server] state in
                Task { @MainActor in
                    guard let self, let server, self.listener === server else { return }
                    switch state {
                    case .ready:
                        self.running = true
                        self.address = Self.localAddress().map { "http://\($0):8080" } ?? "Wi-Fi IPv4 adresi bulunamadı; Wi-Fi bağlantını kontrol et."
                        self.message = "Bilgisayar ve iPhone aynı Wi-Fi ağında olmalı."
                    case .failed(let error):
                        self.closeListener(keepEnabled: true)
                        self.message = error.localizedDescription + " Wi-Fi bağlantısını kontrol edip yeniden aç."
                    default: break
                    }
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            server.start(queue: .main)
        } catch {
            running = false
            message = "8080 portu açılamadı: " + error.localizedDescription
        }
    }
    private func closeListener(keepEnabled: Bool) {
        listener?.cancel(); listener = nil
        for client in Array(clients.values) { client.close() }
        clients.removeAll(); running = false
        address = ""
        if !keepEnabled { code = "" }
    }
    private func accept(_ connection: NWConnection) {
        guard listener != nil, clients.count < 4 else { connection.cancel(); return }
        let id = UUID()
        let client = UploadClient(connection: connection, code: code)
        clients[id] = client
        client.finished = { [weak self] in self?.clients.removeValue(forKey: id) }
        client.importFile = { [weak self] file, name in
            guard let self, let onFile = self.onFile else { throw UploadFailure.invalid("Arşiv hazır değil.") }
            try await onFile(file, name)
            self.message = name + " arşive eklendi."
        }
        connection.start(queue: .main); client.receive()
    }
    private static func localAddress() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var pointer = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == "en0", let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }
}
private enum UploadFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
@MainActor private final class UploadClient {
    let connection: NWConnection
    let code: String
    var finished: (() -> Void)?
    var importFile: ((URL, String) async throws -> Void)?
    private var header = Data()
    private var remaining: Int64?
    private var file: URL?
    private var handle: FileHandle?
    private var name = ""
    private var closed = false
    private var responding = false
    private var timeout: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    init(connection: NWConnection, code: String) { self.connection = connection; self.code = code }
    func close() {
        guard !closed else { return }; closed = true
        timeout?.cancel(); importTask?.cancel(); try? handle?.close(); handle = nil
        if importTask == nil, let file { try? FileManager.default.removeItem(at: file) }
        connection.cancel(); finished?()
    }
    func receive() {
        guard !closed, !responding else { return }
        timeout?.cancel()
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000); self?.close() } catch { }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed, !self.responding else { return }
                do {
                    if let data, !data.isEmpty { try self.consume(data) }
                    if !self.responding {
                        if complete || error != nil { self.close() } else { self.receive() }
                    }
                } catch { self.reply(400, error.localizedDescription) }
            }
        }
    }
    private func consume(_ data: Data) throws {
        if remaining == nil {
            header.append(data)
            guard let boundary = header.range(of: Data("\r\n\r\n".utf8)) else {
                if header.count > 16384 { throw UploadFailure.invalid("Başlık çok büyük.") }; return
            }
            guard boundary.lowerBound <= 16384, let text = String(data: header[..<boundary.lowerBound], encoding: .utf8) else { throw UploadFailure.invalid("Geçersiz istek.") }
            let lines = text.components(separatedBy: "\r\n")
            let request = (lines.first ?? "").split(separator: " ")
            guard request.count == 3 else { throw UploadFailure.invalid("Geçersiz istek.") }
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].lowercased()
                guard fields[key] == nil else { throw UploadFailure.invalid("Tekrarlanan başlık.") }
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if request[0] == "GET", request[1] == "/" { reply(200, Self.page, type: "text/html; charset=utf-8"); return }
            guard request[0] == "POST", request[1] == "/upload", fields["x-kontyt-code"] == code,
                  fields["origin"] == nil || fields["origin"] == "http://" + (fields["host"] ?? ""),
                  fields["transfer-encoding"] == nil else { reply(403, "Kod veya istek geçersiz."); return }
            guard let length = fields["content-length"].flatMap(Int64.init), length > 0, length <= 2_147_483_648 else { throw UploadFailure.invalid("Dosya sınırı 2 GB.") }
            name = (fields["x-file-name"]?.removingPercentEncoding ?? "medya").replacingOccurrences(of: "\\", with: "/")
            name = (name as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            guard ["mp3", "m4a", "mp4", "mov", "wav", "aac", "aiff", "aif", "caf"].contains(ext), name.count < 240 else { throw UploadFailure.invalid("Desteklenmeyen dosya türü.") }
            let directory = FileManager.default.temporaryDirectory
            let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard free > length * 2 + 100_000_000 else { throw UploadFailure.invalid("Telefonda yeterli boş alan yok.") }
            let url = directory.appendingPathComponent("kontyt-upload-" + UUID().uuidString).appendingPathExtension(ext)
            file = url
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw UploadFailure.invalid("Geçici dosya açılamadı.") }
            handle = try FileHandle(forWritingTo: url); remaining = length
            let body = Data(header[boundary.upperBound...]); header = Data()
            try consume(body); return
        }
        guard let left = remaining, Int64(data.count) <= left else { throw UploadFailure.invalid("Dosya boyutu uyuşmuyor.") }
        try handle?.write(contentsOf: data); remaining = left - Int64(data.count)
        if remaining == 0 {
            try handle?.close(); handle = nil; responding = true; timeout?.cancel()
            guard let file, let importFile else { throw UploadFailure.invalid("Alıcı hazır değil.") }
            importTask = Task { @MainActor in
                defer {
                    importTask = nil
                    if closed { try? FileManager.default.removeItem(at: file) }
                }
                do { try await importFile(file, name); if !closed { reply(200, "Arşive eklendi.") } }
                catch { if !closed { reply(400, error.localizedDescription) } }
            }
        }
    }
    private func reply(_ status: Int, _ text: String, type: String = "text/plain; charset=utf-8") {
        guard !closed else { return }; responding = true; timeout?.cancel()
        let body = Data(text.utf8)
        var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in Task { @MainActor in self?.close() } })
    }
    private static let page = #"""
<!doctype html><html lang="tr"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>KontYT · Wi-Fi yükleme</title><style>body{background:#101719;color:#eef9f5;font:16px system-ui;max-width:560px;margin:8vh auto;padding:24px}h1{color:#79e5c0}input,button{display:block;margin:18px 0;padding:14px;border-radius:12px;border:1px solid #48655b;background:#182923;color:inherit;max-width:95%}button{cursor:pointer;background:#255944}progress{width:100%}small{color:#b0c4bb}</style><h1>KontYT</h1><h2>Bilgisayardan arşivine</h2><p>Telefondaki kodu gir, müzik veya video dosyalarını seç.</p><input id="code" inputmode="numeric" maxlength="6" placeholder="6 haneli kod" aria-label="Eşleştirme kodu"><input id="files" type="file" multiple accept=".mp3,.m4a,.mp4,.mov,.wav,.aac,.aiff,.aif,.caf"><button id="send">Dosyaları yükle</button><progress id="progress" value="0" max="100"></progress><p id="status" role="status"></p><small>KontYT açık ve ön planda kalsın. Dosya başına en fazla 2 GB. Yerel HTTP bağlantısı şifreli değildir; yalnızca güvendiğin Wi-Fi ağında kullan.</small><script>const el=id=>document.getElementById(id);el('send').onclick=async()=>{const files=[...el('files').files],code=el('code').value;if(!/^\d{6}$/.test(code)||!files.length){el('status').textContent='Kodu gir ve dosya seç.';return}el('send').disabled=true;try{for(const file of files){el('status').textContent=file.name+' yükleniyor…';await new Promise((resolve,reject)=>{const x=new XMLHttpRequest();x.open('POST','/upload');x.setRequestHeader('X-KontYT-Code',code);x.setRequestHeader('X-File-Name',encodeURIComponent(file.name));x.upload.onprogress=e=>{if(e.lengthComputable)el('progress').value=e.loaded/e.total*100};x.onload=()=>x.status===200?resolve():reject(new Error(x.responseText));x.onerror=()=>reject(new Error('Bağlantı kesildi. Telefondaki arşivi kontrol et.'));x.send(file)})}el('status').textContent='Dosyalar arşive eklendi.'}catch(e){el('status').textContent=e.message}finally{el('send').disabled=false}}</script></html>
"""#
}
struct WiFiUploadView: View {
    @ObservedObject private var server = WiFiUploadServer.shared
    var body: some View {
        Form {
            Section("Bilgisayardan yükle") {
                Text("Aynı Wi-Fi ağındaki bilgisayarın tarayıcısından aşağıdaki adresi aç.")
                if server.running {
                    Text(server.address).font(.headline).textSelection(.enabled)
                    LabeledContent("Eşleştirme kodu", value: server.code)
                    Button("Sunucuyu kapat", role: .destructive) { server.stop() }
                } else { Button("Wi-Fi yüklemeyi aç · 8080") { server.start() } }
                if !server.message.isEmpty { Text(server.message).font(.caption) }
            }
            Section("Aktarım sırasında") {
                Text("Sunucu, sen kapatana kadar açık kalır: bu ekrandan çıksan da çalışır. Uygulama arka plana geçince ya da kapanınca durur; öne gelince kendiliğinden yeniden açılır. Yarım dosyalar temizlenir, arşive eklenenler korunur. Desteklenen dosyalar: MP3, M4A, MP4, MOV, WAV, AAC, AIFF ve CAF. Dosya başına 2 GB.")
                Text("Yerel HTTP şifreli değildir. Yalnızca güvendiğin ağda kullan; modemden port yönlendirme açma.").font(.caption)
            }
        }.navigationTitle("Wi-Fi ile yükle")
    }
}
