import SwiftUI
import UIKit

@MainActor final class ClipboardMonitor: ObservableObject {
    private var lastChange = -1
    private var reading = false
    func check(_ receive: @escaping (URL) -> Void) {
        guard UIApplication.shared.applicationState == .active,
              UserDefaults.standard.object(forKey: "autoClipboard") as? Bool ?? false,
              !reading else { return }
        let pasteboard = UIPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChange else { return }
        lastChange = count; reading = true
        Task { @MainActor in
            defer { reading = false }
            do {
                let patterns: Set<UIPasteboard.DetectionPattern> = try await withCheckedThrowingContinuation { continuation in
                    pasteboard.detectPatterns(for: [.probableWebURL]) { result in
                        continuation.resume(with: result)
                    }
                }
                guard pasteboard.changeCount == count, patterns.contains(.probableWebURL), UIApplication.shared.applicationState == .active, UserDefaults.standard.object(forKey: "autoClipboard") as? Bool ?? false else { return }
                // iOS may ask for paste permission here. This is never bypassed.
                if let url = pasteboard.url, SharedInbox.accepted(url) { receive(url) }
                else if let text = pasteboard.string, let url = SharedInbox.extract(text) { receive(url) }
            } catch { /* System paste control remains available; no repeated permission loop. */ }
        }
    }
}
