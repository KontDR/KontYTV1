import UIKit

/// On-device breadcrumbs for "the app closed by itself" reports.
///
/// The exact answer always lives in the system report (Ayarlar › Gizlilik ve Güvenlik › Analizler ve
/// İyileştirmeler › Analiz Verileri › `KontYT-…ips`), but on a sideloaded build that is awkward to reach.
/// So the app keeps a very small text file of its own:
///
/// * one line per launch / foreground / background ("nokta"),
/// * one line before the process dies on a catchable signal or an uncaught exception,
/// * rotated at 8 KB so it can never grow.
///
/// A line of the form "KontYT kapandi, signal 9" means the system ended us without warning: iOS never
/// lets an app catch SIGKILL, so pressure kills and expired signatures look exactly the same here.
enum CrashLog {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static var file: URL { folder.appendingPathComponent("kontyt-crash.log") }
    private static let limit = 8 * 1024
    private static var installed = false

    /// Called once from the app delegate, before anything else can go wrong.
    static func install() {
        guard !installed else { return }
        installed = true
        kontytCrashDescriptor = open(file.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        for number in [SIGABRT, SIGSEGV, SIGILL, SIGFPE, SIGBUS, SIGTRAP] {
            _ = signal(number, kontytCrashHandler)
        }
        NSSetUncaughtExceptionHandler(kontytRecordException)
        // What the log ended with before this launch is the most useful line of all: a launch that
        // follows a silent ending proves the process was killed rather than crashed.
        let previous = tail(1)
        if !previous.hasPrefix("Henüz") { note("Onceki oturumun son satiri: " + String(previous.prefix(140))) }
        note("KontYT acildi")
    }

    /// Appends one timestamped line and keeps the file small.
    static func note(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = stamp + "  " + text.replacingOccurrences(of: "\n", with: " ") + "\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        let attributes = try? fm.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? Int) ?? 0
        if size > limit {
            let previous = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            try? String(previous.suffix(limit / 2)).write(to: file, atomically: true, encoding: .utf8)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Last lines, newest at the bottom - shown in Ayarlar.
    static func tail(_ lines: Int = 8) -> String {
        guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else {
            return "Henüz kayıt yok. Uygulama kapandıysa sistem raporuna bak: Ayarlar › Gizlilik ve Güvenlik › Analizler ve İyileştirmeler › Analiz Verileri › KontYT ile başlayan dosya."
        }
        let kept = text.split(separator: "\n").suffix(lines)
        return kept.joined(separator: "\n")
    }

    static func clear() {
        try? FileManager.default.removeItem(at: file)
        note("KontYT tanilama kaydi temizlendi")
    }
}

/// Signal handling must avoid allocation, locks and Swift runtime calls, so the handler only writes a
/// fixed prefix, one digit and a newline through pre-opened file descriptors.
private var kontytCrashDescriptor: Int32 = -1
private let kontytCrashPrefix = Array("KontYT kapandi, signal ".utf8)
private let kontytCrashDigits = Array("0123456789".utf8)
private let kontytCrashNewline: [UInt8] = [10]

private func kontytCrashHandler(_ number: Int32) -> Void {
    let descriptor = kontytCrashDescriptor
    if descriptor >= 0 {
        kontytCrashPrefix.withUnsafeBufferPointer { buffer in
            _ = write(descriptor, buffer.baseAddress, buffer.count)
        }
        var digit = kontytCrashDigits[Int(number) % 10]
        _ = write(descriptor, &digit, 1)
        kontytCrashNewline.withUnsafeBufferPointer { buffer in
            _ = write(descriptor, buffer.baseAddress, buffer.count)
        }
    }
    _ = signal(number, SIG_DFL)
    _ = raise(number)
}

/// Uncaught Objective-C exceptions. `NSSetUncaughtExceptionHandler` wants a plain C function pointer,
/// so this is a file-level function that captures nothing (CI: "a C function pointer cannot be formed
/// from a closure that captures context").
private func kontytRecordException(_ exception: NSException) {
    let names = exception.callStackSymbols.prefix(4).joined(separator: " | ")
    CrashLog.note("KontYT kapandi, istisna: " + exception.name.rawValue + " · " + (exception.reason ?? "") + " · " + names)
}
