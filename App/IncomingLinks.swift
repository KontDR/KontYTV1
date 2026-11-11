import SwiftUI

@MainActor final class IncomingLinks: ObservableObject {
    @Published var items: [InboxLink] = []
    @Published var error: String?
    /// True when the build has no shared container (free Apple ID strips App Groups).
    @Published var unavailable = false
    @Published var externalQuery: String?
    func refresh() {
        if Bundle.main.object(forInfoDictionaryKey: "KontYTShareMode") as? String == "standalone" {
            items = []; unavailable = false; return
        }
        do {
            items = try SharedInbox.load()
            error = nil
            unavailable = false
        } catch let failure {
            // A missing App Group is a normal state on free signing, not an error to shout about.
            // NB: a bare `catch` binds `error` to the thrown value and shadows this property.
            if AppGroupResolver.resolved() == nil {
                items = []; self.error = nil; unavailable = true
            } else {
                self.error = failure.localizedDescription
            }
        }
    }
    /// Sharing from YouTube used to land in the app by itself. When there is no shared
    /// container, the extension leaves the link on the handoff pasteboard; this picks it up
    /// as soon as the app becomes active, and remembers what it already took.
    ///
    /// iOS asks for permission the moment the pasteboard is read, so the read happens only when the
    /// pasteboard actually changed since the last time we looked - not on every foreground.
    @discardableResult
    func autoImportHandoff() -> Bool {
        guard externalQuery == nil else { return false }
        let change = UIPasteboard.general.changeCount
        guard change != UserDefaults.standard.integer(forKey: "handoffChangeCount") else { return false }
        UserDefaults.standard.set(change, forKey: "handoffChangeCount")
        guard let url = SharedInbox.pasteboardLinks().first else { return false }
        let key = url.absoluteString
        guard UserDefaults.standard.string(forKey: "handoffSeen") != key else { return false }
        UserDefaults.standard.set(key, forKey: "handoffSeen")
        SharedInbox.clearHandoff(url)
        open(url)
        return true
    }
    /// User-initiated paste read: no background clipboard scanning, no surprise prompt loop.
    @discardableResult
    func importPasteboard() -> Bool {
        guard let url = SharedInbox.pasteboardLinks().first else {
            error = "Panoda YouTube bağlantısı bulunamadı."
            return false
        }
        error = nil
        open(url)
        return true
    }
    func consume(_ item: InboxLink) {
        do { try SharedInbox.remove(item.id); items.removeAll { $0.id == item.id } }
        catch { self.error = error.localizedDescription }
    }
    func open(_ url: URL) {
        if SharedInbox.accepted(url) { externalQuery = url.absoluteString; return }
        guard url.scheme == "kontyt", url.host == "import", let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let link = SharedInbox.extract(raw) else { return }
        externalQuery = link.absoluteString
    }
}
