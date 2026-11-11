import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let status = UILabel()
    private let done = UIButton(type: .system)
    private var started = false
    private var receivedURLs: [URL] = []
    private let copy = UIButton(type: .system)
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel(); title.text = "KontYT’ye gönder"; title.font = .preferredFont(forTextStyle: .title1)
        status.numberOfLines = 0; status.text = "Bağlantı okunuyor…"
        done.setTitle("Kapat", for: .normal); done.addTarget(self, action: #selector(close), for: .touchUpInside)
        copy.setTitle("Bağlantıyı kopyala ve kapat", for: .normal); copy.addTarget(self, action: #selector(copyAndClose), for: .touchUpInside); copy.isHidden = true
        let image = UIImageView(image: UIImage(named: "BrandMark")); image.contentMode = .scaleAspectFit; image.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let stack = UIStackView(arrangedSubviews: [image, title, status, copy, done]); stack.axis = .vertical; stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }; started = true
        Task { await receive() }
    }
    private func value(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }
    @MainActor private func receive() async {
        do {
            var urls = Set<URL>()
            for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
                for provider in item.attachments ?? [] {
                    let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url.identifier : UTType.plainText.identifier
                    guard provider.hasItemConformingToTypeIdentifier(type) else { continue }
                    let result = try await value(provider, type: type)
                    if let url = result as? URL, SharedInbox.accepted(url) { urls.insert(url) }
                    else if let string = result as? String, let url = SharedInbox.extract(string) { urls.insert(url) }
                }
            }
            guard !urls.isEmpty else { throw InboxError.invalid }
            receivedURLs = Array(urls)
            var stored = true
            for url in urls {
                let outcome = try SharedInbox.store(url, allowPasteboard: false)
                if outcome == .pasteboard { stored = false }
            }
            // The old behaviour the app always had: share, KontYT opens by itself on the download sheet.
            var opened = false
            if let first = receivedURLs.first { opened = await openHostApp(with: first) }
            // Only when the direct hand-over is refused do we fall back to the pasteboard, so a working
            // share never touches the user's clipboard and never triggers an iOS paste prompt.
            if !opened, !stored { for url in receivedURLs { SharedInbox.copyToHandoff(url) } }
            if opened {
                status.text = "\(urls.count) bağlantı hazır. KontYT açılıyor…"
            } else if !stored {
                status.text = "\(urls.count) bağlantı panoya kopyalandı. KontYT’yi aç: bağlantı otomatik alınacak, olmazsa YouTube sekmesindeki pano düğmesine bas."
            } else {
                status.text = "\(urls.count) bağlantı KontYT’ye kaydedildi. KontYT’yi açtığında tek video otomatik sıraya alınır; liste için seçim ekranı açılır."
            }
            copy.isHidden = false
        } catch { status.text = error.localizedDescription; copy.isHidden = receivedURLs.isEmpty }
    }
    /// Hands the link to the host app. `NSExtensionContext.open` is the supported route (iOS 14+) and
    /// is what makes "Paylaş → KontYT → indirme ekranı" work; the responder chain stays as a fallback
    /// for systems that refuse it, and the pasteboard path above covers everything else.
    private func openHostApp(with url: URL) async -> Bool {
        guard var components = URLComponents(string: "kontyt://import") else { return false }
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let target = components.url else { return false }
        if let context = extensionContext {
            let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                context.open(target) { success in continuation.resume(returning: success) }
            }
            if accepted { return true }
        }
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:")
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: target)
                return true
            }
            responder = current.next
        }
        return false
    }
    @objc private func copyAndClose() {
        UIPasteboard.general.string = receivedURLs.map(\.absoluteString).joined(separator: "\n")
        close()
    }
    @objc private func close() { extensionContext?.completeRequest(returningItems: nil) }
}
