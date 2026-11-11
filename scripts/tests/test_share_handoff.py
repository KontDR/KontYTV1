"""Free Apple IDs strip App Groups when AltStore re-signs, so sharing must not depend on the shared
container alone: the extension hands the link to the app, and the pasteboard is only a fallback."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def read(name: str) -> str:
    return (ROOT / name).read_text(encoding='utf-8')


class ShareHandoff(unittest.TestCase):
    def test_shared_inbox_falls_back_to_the_pasteboard(self):
        inbox = read('Shared/SharedInbox.swift')
        self.assertIn('enum Outcome { case shared, pasteboard }', inbox)
        self.assertIn('@discardableResult static func store(_ url: URL, allowPasteboard: Bool = true) throws -> Outcome', inbox)
        body = inbox.split('static func store(_ url: URL, allowPasteboard: Bool = true) throws -> Outcome', 1)[1].split('static func copyToHandoff', 1)[0]
        self.assertIn('copyToHandoff(url)', body)
        self.assertIn('return .pasteboard', body)
        self.assertNotIn('throw InboxError.unavailable', body)
        self.assertIn('static func copyToHandoff', inbox)
        self.assertIn('com.example.kontyt.inbox', inbox)
        self.assertIn('static func pasteboardLinks()', inbox)

    def test_extension_never_reports_a_permission_failure(self):
        view = read('ShareExtension/ShareViewController.swift')
        self.assertIn('SharedInbox.store(url, allowPasteboard: false)', view)
        self.assertIn('.pasteboard', view)
        self.assertIn('panoya kopyalandı', view)
        self.assertIn('pano düğmesine', view)
        self.assertNotIn('App Groups yetkisi', view)
        self.assertNotIn('Ortak paylaşım alanı açılamadı', view)

    def test_extension_hands_over_to_the_app(self):
        view = read('ShareExtension/ShareViewController.swift')
        self.assertIn('private func openHostApp(with url: URL) async -> Bool', view)
        self.assertIn('kontyt://import', view)
        self.assertIn('KontYT açılıyor', view)
        self.assertIn('NSSelectorFromString("openURL:")', view)
        self.assertIn('context.open(target)', view)
        self.assertIn('if !opened, !stored { for url in receivedURLs { SharedInbox.copyToHandoff(url) } }', view)

    def test_app_offers_one_tap_paste_import(self):
        links = read('App/IncomingLinks.swift')
        self.assertIn('func importPasteboard()', links)
        self.assertIn('SharedInbox.pasteboardLinks()', links)
        self.assertIn('@Published var unavailable = false', links)
        self.assertIn('AppGroupResolver.resolved() == nil', links)
        discovery = read('App/StudioViews.swift')
        self.assertIn('PasteButton(payloadType: String.self)', discovery)
        self.assertNotIn('doc.on.clipboard', discovery)
        self.assertIn('incoming.unavailable', discovery)

    def test_handoff_is_picked_up_automatically(self):
        links = read('App/IncomingLinks.swift')
        self.assertIn('func autoImportHandoff()', links)
        body = links.split('func autoImportHandoff()', 1)[1].split('func importPasteboard', 1)[0]
        self.assertIn('guard externalQuery == nil else { return false }', body)
        self.assertIn('UIPasteboard.general.changeCount', body)
        self.assertIn('handoffSeen', body)
        self.assertIn('SharedInbox.clearHandoff(url)', body)
        self.assertIn('open(url)', body)
        root = read('App/StudioViews.swift')
        self.assertGreaterEqual(root.count('incoming.autoImportHandoff()'), 2)

    def test_handoff_clear_does_not_wipe_foreign_clipboard_content(self):
        inbox = read('Shared/SharedInbox.swift')
        body = inbox.split('static func clearHandoff', 1)[1].split('static func pasteboardLinks', 1)[0]
        self.assertIn('UIPasteboard.general.string == url.absoluteString', body)
        self.assertIn('UIPasteboard.general.items = []', body)

    def test_clipboard_watching_is_opt_in_so_ios_stops_asking(self):
        monitor = read('App/ClipboardMonitor.swift')
        self.assertEqual(monitor.count('"autoClipboard") as? Bool ?? false'), 2)
        settings = read('App/StudioViews.swift')
        self.assertIn('@AppStorage("autoClipboard") private var autoClipboard = false', settings)


if __name__ == '__main__':
    unittest.main()
