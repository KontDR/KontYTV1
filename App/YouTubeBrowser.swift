import SwiftUI
import WebKit

struct BrowserRequest: Identifiable {
    let id = UUID()
    let url: URL
}
enum YouTubeBrowserPolicy {
    /// The in-app browser is an ordinary browser now: any HTTPS page opens, YouTube or not, so you can
    /// search the web and reach YouTube yourself. Only local/scripting schemes are refused.
    static func browsable(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
    static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
    /// Share links and playlist parsing stay YouTube-only; browsing does not.
    static func allowed(_ url: URL) -> Bool {
        guard browsable(url) else { return false }
        return isYouTube(url) || ["accounts.google.com", "consent.google.com"].contains(url.host?.lowercased() ?? "")
    }
    static func playlistID(_ url: URL) -> String? {
        guard SharedInbox.accepted(url), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = parts.queryItems?.first(where: { $0.name == "list" })?.value,
              !id.isEmpty, id.count < 256,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return id
    }
    static func target(_ url: URL, desktop: Bool = false) -> URL? {
        guard let id = playlistID(url) else { return nil }
        var parts = URLComponents(string: desktop ? "https://www.youtube.com/playlist" : "https://m.youtube.com/playlist")!
        parts.queryItems = [URLQueryItem(name: "list", value: id), URLQueryItem(name: "hl", value: "tr")]
        return parts.url
    }
}
@MainActor final class YouTubeBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private var source: URL
    var target: URL {
        guard !playlistID.isEmpty else { return source }
        var parts = URLComponents(string: desktop ? "https://www.youtube.com/playlist" : "https://m.youtube.com/playlist")!
        parts.queryItems = [URLQueryItem(name: "list", value: playlistID), URLQueryItem(name: "hl", value: "tr")]
        return parts.url ?? source
    }
    @Published var desktop = false
    @Published var diagnostics = "Henüz sayfa bilgisi alınmadı."
    /// Follows the playlist the user is currently looking at, not only the one that opened the browser.
    @Published private(set) var playlistID: String
    @Published var loading = false
    @Published var reading = false
    @Published var videos: [SavedVideo] = []
    @Published var message = "Liste otomatik algılanıyor. Sayfayı aşağı kaydırdıkça kayıt sayısı artar."
    @Published var currentAddress = ""
    /// Automatic local polling: no button press needed to see how many entries were found.
    @Published var autoDetect = true
    /// Popup: "this playlist was found, import it?" - shown once per list.
    @Published var showOffer = false
    @Published var offerCount = 0
    /// Last harvest report, shown in the diagnostics box so a failure can be read off the screen.
    @Published var report = "Henüz okuma yapılmadı."
    @Published private(set) var pageTitle = ""
    @Published private(set) var harvesting = false
    /// Live back/forward availability, so the buttons are honest about where you can go.
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    private var navigationObservers: [NSKeyValueObservation] = []
    /// A web content process can be killed under memory pressure; recover once per page, not in a loop.
    private var webProcessReloads = 0
    private var autoTimer: Timer?
    private var lastCount = 0
    private var stableTicks = 0
    private var offerShown = false
    /// Once a read stops finding new rows, the poll stops asking YouTube again and again.
    private var settled = false
    private var scrollRounds = 0
    private let autoScroll = true
    init(url: URL) {
        self.source = url
        self.playlistID = YouTubeBrowserPolicy.playlistID(url) ?? ""
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        navigationObservers = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoForward = view.canGoForward }
            }
        ]
        openTarget()
    }
    /// Any address may be typed here. A YouTube link that carries `list=` still switches the list reader on.
    func open(address: String) {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let looksLikeAddress = text.contains("://") || text.contains(".")
        let search = "https://m.youtube.com/results?search_query="
            + (text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        let candidate = SharedInbox.extract(text)
            ?? (looksLikeAddress ? (URL(string: text) ?? URL(string: "https://" + text)) : URL(string: search))
        guard let url = candidate, YouTubeBrowserPolicy.browsable(url) else {
            message = "Yalnız HTTPS adresleri açılabilir. Örnek: youtube.com veya bir liste bağlantısı."; return
        }
        source = url
        playlistID = YouTubeBrowserPolicy.playlistID(url) ?? ""
        videos = []; lastCount = 0; stableTicks = 0; settled = false; offerShown = false
        if playlistID.isEmpty {
            stopAutoDetect()
            message = "Geziniyorsun. Bir YouTube listesi açınca kayıtlar kendiliğinden okunur."
        }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45))
    }
    func openTarget() {
        guard YouTubeBrowserPolicy.browsable(target) else { message = "Geçerli bir HTTPS adresi gerekiyor."; return }
        let request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        webView.load(request)
    }
    /// Same history as the swipe gestures, now with visible buttons.
    func goBack() { guard webView.canGoBack else { return }; webView.goBack() }
    func goForward() { guard webView.canGoForward else { return }; webView.goForward() }
    func reloadPage() { webView.reload() }
    func setDesktop(_ value: Bool) {
        guard desktop != value else { return }
        desktop = value
        // Reuse the same WKWebView and persistent store: never erase login cookies on mode changes.
        webView.stopLoading(); diagnostics = "Görünüm değiştirildi; liste yeniden yükleniyor."
        openTarget()
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = desktop ? .desktop : .mobile
        guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow, preferences); return }
        guard let url = navigationAction.request.url, YouTubeBrowserPolicy.browsable(url) else {
            message = "Yalnız HTTPS adresleri açılabilir."
            decisionHandler(.cancel, preferences); return
        }
        decisionHandler(.allow, preferences)
    }
    func inspectPage() {
        let expected = webView.url
        let script = #"JSON.stringify({title: document.title, ready: document.readyState, agent: navigator.userAgent, errors: Array.from(document.querySelectorAll('yt-playability-error-supported-renderers, ytd-error-screen, ytm-error-page, ytd-background-promo-renderer, ytm-background-promo-renderer, .yt-player-error-message-renderer')).map(e => e.innerText || e.textContent || '').join(' ').slice(0, 600)})"#
        webView.evaluateJavaScript(script) { [weak self] value, error in
            Task { @MainActor in
                guard let self, self.webView.url == expected else { return }
                self.currentAddress = self.webView.url?.absoluteString ?? ""
                let mode = self.desktop ? "Masaüstü" : "Mobil"
                if let error { self.diagnostics = mode + " · " + error.localizedDescription; return }
                guard let text = value as? String, let data = text.data(using: .utf8),
                      let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return }
                self.diagnostics = ["Görünüm: " + mode, "Başlık: " + (fields["title"] ?? ""),
                                    "Durum: " + (fields["ready"] ?? ""), "Tarayıcı: " + (fields["agent"] ?? ""),
                                    "Sayfa hatası: " + (fields["errors"] ?? "")].joined(separator: "\n")
            }
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, YouTubeBrowserPolicy.allowed(url) { webView.load(navigationAction.request) }
        return nil
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        stopAutoDetect()
        CrashLog.note("Tarayici icerigi kapandi (web process)")
        loading = false; reading = false; harvesting = false
        guard webProcessReloads < 1 else {
            message = "Sayfa işlemi kapandı. Sayfayı elle yenile (⟳) ya da bu sekmeyi kapat."
            return
        }
        webProcessReloads += 1
        message = "Sayfa işlemi kapandı; sayfa yeniden yükleniyor…"
        webView.reload()
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; stopAutoDetect() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false; webProcessReloads = 0; currentAddress = webView.url?.absoluteString ?? ""
        inspectPage()
        followPlaylistPage()
        guard isPlaylistContext() else {
            stopAutoDetect()
            message = YouTubeBrowserPolicy.isYouTube(webView.url ?? source)
                ? "Liste sayfası değil. Bir oynatma listesi açınca kayıtlar kendiliğinden okunur."
                : "Bu sayfa YouTube dışında: serbestçe gezinebilirsin, liste okuma yalnız YouTube'da çalışır."
            return
        }
        harvest(offer: true)
        scheduleRetries()
        startAutoDetect()
        beginAutoScroll()
    }
    func stopAutoDetect() { autoTimer?.invalidate(); autoTimer = nil }
    private func startAutoDetect() {
        stopAutoDetect()
        guard autoDetect else { return }
        autoTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.followPlaylistPage()
                guard self.isPlaylistContext() else { self.stopAutoDetect(); return }
                guard !self.settled else { return }
                self.harvest(offer: true)
            }
        }
    }
    func setAutoDetect(_ value: Bool) {
        autoDetect = value
        if value { startAutoDetect(); harvest(offer: true) } else { stopAutoDetect() }
    }
    func autoCollect() { harvest(offer: true) }
    /// The list usually renders a moment after didFinish; retry a few times before reporting "not found".
    private func scheduleRetries() {
        for delay in [0.7, 1.8, 3.5] {
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.videos.isEmpty else { return }
                    self.harvest(offer: true)
                }
            }
        }
    }
    /// Scrolls the page down a few times so lazily-loaded rows exist, then stops. Never clicks anything.
    private func beginAutoScroll() {
        scrollRounds = 0
        scheduleScroll()
    }
    private func scheduleScroll() {
        guard autoScroll, scrollRounds < 3, isPlaylistContext() else { return }
        scrollRounds += 1
        webView.evaluateJavaScript("window.scrollTo({top: document.documentElement.scrollHeight, behavior: 'smooth'}); 'ok'") { _, _ in }
        Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.harvest(offer: true)
                self.scheduleScroll()
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false; message = error.localizedDescription
        diagnostics = "Gezinme hatası: \(error.localizedDescription)"; currentAddress = webView.url?.absoluteString ?? ""
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false; message = error.localizedDescription
        diagnostics = "Gezinme hatası: \(error.localizedDescription)"; currentAddress = webView.url?.absoluteString ?? ""
    }
    /// Follows whatever playlist page the user is looking at, including a watch page that carries "list=".
    private func followPlaylistPage() {
        guard let url = webView.url, let id = YouTubeBrowserPolicy.playlistID(url) else { return }
        guard id != playlistID else { return }
        playlistID = id
        videos = []; lastCount = 0; stableTicks = 0; offerShown = false; scrollRounds = 0; settled = false
        message = "Yeni liste algılandı; kayıtlar okunuyor…"
    }
    /// A page counts when it carries a playlist id: the playlist page itself, or a video that is
    /// playing inside a list (its side panel is the same list). Feeds and search results do not.
    func isPlaylistContext() -> Bool {
        guard let url = webView.url else { return false }
        if YouTubeBrowserPolicy.playlistID(url) != nil { return true }
        return !playlistID.isEmpty && url.absoluteString.contains(playlistID)
    }
    /// Reads every video id the page already holds: anchors, its own data blob, and the raw HTML.
    /// It makes no network request, clicks nothing and approves nothing.
    private var harvestScript: String {
        #"""

        function decodeEscapes(value) {
          return value.replace(/\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|n|t|.)/g, (whole, group) => {
            if (group.length > 1) return String.fromCharCode(parseInt(group.slice(1), 16));
            if (group === 'n') return '\n';
            if (group === 't') return '\t';
            return group;
          });
        }
        // YouTube ships the payload two ways: desktop as a plain object literal, mobile as a quoted
        // string full of \x22 escapes. Both must parse, otherwise every row is left without a title.
        function extractInitialData(text) {
          const marker = text.indexOf('ytInitialData');
          if (marker < 0) return null;
          const equals = text.indexOf('=', marker);
          if (equals < 0) return null;
          let index = equals + 1;
          while (index < text.length && /\s/.test(text[index])) index++;
          const quote = text[index];
          if (quote === '"' || quote === "'") {
            let cursor = index + 1, raw = '', closed = false;
            while (cursor < text.length) {
              const character = text[cursor];
              if (character === '\\') { raw += character + (text[cursor + 1] || ''); cursor += 2; continue; }
              if (character === quote) { closed = true; break; }
              raw += character; cursor++;
            }
            if (!closed) return null;
            const decoded = decodeEscapes(raw);
            try { return JSON.parse(decoded); } catch (error) {}
            try { return JSON.parse(decodeEscapes(decoded)); } catch (error) {}
            return null;
          }
          if (quote !== '{') return null;
          const start = index;
          let depth = 0, inString = false, escaped = false;
          for (let position = start; position < text.length && position < start + 12000000; position++) {
            const character = text[position];
            if (inString) {
              if (escaped) { escaped = false; }
              else if (character === '\\') { escaped = true; }
              else if (character === '"') { inString = false; }
              continue;
            }
            if (character === '"') { inString = true; continue; }
            if (character === '{') { depth++; continue; }
            if (character === '}') {
              depth--;
              if (depth === 0) {
                try { return JSON.parse(text.slice(start, position + 1)); } catch (error) { return null; }
              }
            }
          }
          return null;
        }
                const MAX = 500;
                const clean = (value) => (typeof value === 'string' ? value.replace(/\s+/g, ' ').trim().slice(0, 300) : '');
                const out = new Map();
                const meta = {url: location.href, path: location.pathname, title: document.title, list: '',
                              rows: 0, fromData: 0, fromFetch: 0, html: 0, status: 0, playlist: false};
                const put = (id, title, bucket) => {
                  if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{11}$/.test(id)) return false;
                  const text = clean(title);
                  if (out.has(id)) {
                    const seen = out.get(id) || '';
                    if (text.length > seen.length) out.set(id, text);
                    return false;
                  }
                  out.set(id, text);
                  if (bucket) meta[bucket] += 1;
                  return true;
                };
                const titleOf = (node, depth) => {
                  if (!node || depth > 5) return '';
                  if (typeof node === 'string') return clean(node);
                  if (Array.isArray(node)) { for (const part of node) { const found = titleOf(part, depth + 1); if (found) return found; } return ''; }
                  if (typeof node !== 'object') return '';
                  if (typeof node.content === 'string' && node.content) return clean(node.content);
                  if (typeof node.simpleText === 'string' && node.simpleText) return clean(node.simpleText);
                  if (Array.isArray(node.runs)) return clean(node.runs.map((run) => (run && run.text) ? run.text : '').join(''));
                  const keys = ['title', 'headline', 'metadata', 'primaryText', 'lockupMetadataViewModel', 'videoTitle'];
                  for (const key of keys) { const found = titleOf(node[key], depth + 1); if (found) return found; }
                  return '';
                };
                let listId = new URL(location.href).searchParams.get('list') || '';
                const isPlaylistPath = /\/playlist\/?$/.test(location.pathname);
                // 1) Rows rendered on screen (playlist page rows and the playlist panel beside a video).
                try {
                  // Rows only count on a page that is about a list; a feed never contributes rows.
                  if (!isPlaylistPath && !listId) throw new Error('no list on this page');
                  const selector = 'ytd-playlist-video-renderer, ytm-playlist-video-renderer, ' +
                    'ytd-playlist-panel-video-renderer, ytm-playlist-panel-video-renderer, ' +
                    'ytm-video-with-context-renderer, ytm-media-item, ytm-compact-video-renderer';
                  const labels = '#video-title, h4, .media-item-headline, .yt-core-attributed-string, ' +
                    'yt-formatted-string, [title], [aria-label]';
                  for (const row of document.querySelectorAll(selector)) {
                    const anchor = row.querySelector('a#thumbnail[href]') || row.querySelector('a[href*="watch"]');
                    if (!anchor) continue;
                    let link; try { link = new URL(anchor.getAttribute('href'), location.href); } catch (error) { continue; }
                    let title = '';
                    for (const node of row.querySelectorAll(labels)) {
                      const text = clean(node.getAttribute('title') || node.getAttribute('aria-label') || node.textContent || '');
                      if (text.length > title.length) title = text;
                    }
                    if (!title) title = clean(anchor.getAttribute('title') || anchor.getAttribute('aria-label') || '');
                    put(link.searchParams.get('v'), title, 'rows');
                  }
                } catch (error) {}
                // 2) The page's own data: playlist item renderers only, never recommendation shelves.
                const pick = (node, trusted) => {
                  if (!node || typeof node !== 'object') return null;
                  const video = node.playlistVideoRenderer;
                  if (video && typeof video.videoId === 'string') return {id: video.videoId, title: titleOf(video.title, 0)};
                  const panel = node.playlistPanelVideoRenderer;
                  if (panel && typeof panel.videoId === 'string') return {id: panel.videoId, title: titleOf(panel.title, 0)};
                  if (trusted) {
                    const lockup = node.lockupViewModel;
                    if (lockup && typeof lockup.contentId === 'string' && lockup.contentId.length === 11) {
                      const model = lockup.metadata && lockup.metadata.lockupMetadataViewModel;
                      const exact = model ? titleOf(model, 0) : '';
                      return {id: lockup.contentId, title: exact || titleOf(lockup.metadata, 0)};
                    }
                  }
                  return null;
                };
                const walk = (node, depth, trusted, bucket) => {
                  if (!node || typeof node !== 'object' || depth > 40) return;
                  if (Array.isArray(node)) { for (const child of node) walk(child, depth + 1, trusted, bucket); return; }
                  const hit = pick(node, trusted);
                  if (hit) put(hit.id, hit.title, bucket);
                  if (typeof node.playlistId === 'string' && !listId && /^[A-Za-z0-9_-]{10,64}$/.test(node.playlistId)) listId = node.playlistId;
                  for (const key in node) {
                    const value = node[key];
                    if (value && typeof value === 'object') walk(value, depth + 1, trusted, bucket);
                  }
                };
                let pageData = null;
                try { pageData = window.ytInitialData || null; } catch (error) {}
                if (!pageData) { try { if (typeof ytInitialData !== 'undefined') pageData = ytInitialData; } catch (error) {} }
                if (pageData) walk(pageData, 0, isPlaylistPath, 'fromData');
                // 3) Authoritative read: ask YouTube for the playlist page from inside this logged-in
                //    session and parse its embedded data. Cookies stay inside the web view.
                if (listId) {
                  try {
                    const response = await fetch(location.origin + '/playlist?list=' + encodeURIComponent(listId) + '&hl=tr',
                                                 {credentials: 'include'});
                    meta.status = response.status;
                    const text = await response.text();
                    meta.html = text.length;
                    const parsed = extractInitialData(text);
                    if (parsed) walk(parsed, 0, true, 'fromFetch');
                  } catch (error) {
                    meta.fetchError = String(error).slice(0, 160);
                  }
                }
                meta.list = listId;
                meta.playlist = Boolean(listId) && (isPlaylistPath || meta.rows > 0 || meta.fromData > 0 || meta.fromFetch > 0);
                const items = [];
                for (const entry of out) { items.push({id: entry[0], title: entry[1]}); if (items.length >= MAX) break; }
                return JSON.stringify({items: items, meta: meta});
        """#
    }
    /// Silent read. `offer` opens the "list found" popup once per playlist.
    ///
    /// WebKit's Swift overlay (`callAsyncJavaScript`/`evaluateJavaScript` with a content world and a
    /// `Result` handler) is `NS_REFINED_FOR_SWIFT`. With an iOS 16 deployment target the linker binds
    /// those symbols to `/usr/lib/swift/libswiftWebKit.dylib`, which iOS 18.4+ runtimes no longer ship,
    /// so dyld killed the app before launch (CI: "Test crashed with signal abrt"). The same async body
    /// now runs behind two plain Objective-C calls: one kick-off, then a short poll of a page global.
    func harvest(offer: Bool) {
        guard !harvesting else { return }
        guard YouTubeBrowserPolicy.isYouTube(webView.url ?? source) else {
            message = "Bu sayfa YouTube dışında: serbestçe gezinebilirsin, liste okuma yalnız YouTube'da çalışır."
            return
        }
        harvesting = true
        reading = true
        let expected = webView.url?.absoluteString ?? ""
        let kick = "window.__kontytHarvest = null; (async function () {" + harvestScript
            + "\n})().then(function (value) { window.__kontytHarvest = String(value); },"
            + " function (problem) { window.__kontytHarvest = 'ERR:' + ((problem && problem.message) ? problem.message : problem); });"
            + " 'started';"
        webView.evaluateJavaScript(kick) { [weak self] _, problem in
            Task { @MainActor in
                guard let self else { return }
                if let problem {
                    self.finishHarvest(nil, error: problem, expected: expected, offer: offer)
                } else {
                    self.pollHarvest(expected: expected, offer: offer, attempt: 0)
                }
            }
        }
    }
    private static let harvestPollRead =
        "(window.__kontytHarvest === null || window.__kontytHarvest === undefined) ? '' : String(window.__kontytHarvest)"
    /// The page fetch inside the script is a real network request, so allow up to ~6 s before giving up.
    private func pollHarvest(expected: String, offer: Bool, attempt: Int) {
        guard harvesting else { return }
        guard (webView.url?.absoluteString ?? "") == expected else { harvesting = false; reading = false; return }
        guard attempt < 40 else {
            finishHarvest(nil, error: NSError(domain: "KontYT.Harvest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Sayfa okuması zaman aşımına uğradı."]),
                expected: expected, offer: offer)
            return
        }
        webView.evaluateJavaScript(Self.harvestPollRead) { [weak self] value, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let text = value as? String, !text.isEmpty else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.pollHarvest(expected: expected, offer: offer, attempt: attempt + 1)
                    }
                    return
                }
                if text.hasPrefix("ERR:") {
                    self.finishHarvest(nil, error: NSError(domain: "KontYT.Harvest", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: String(text.dropFirst(4))]),
                        expected: expected, offer: offer)
                } else {
                    self.finishHarvest(text, error: nil, expected: expected, offer: offer)
                }
            }
        }
    }
    private func finishHarvest(_ value: Any?, error: Error?, expected: String, offer: Bool) {
        harvesting = false; reading = false
        guard (webView.url?.absoluteString ?? "") == expected else { return }
        if let error {
            message = "Tarayıcı sayfası okunamadı: " + error.localizedDescription
            report = "Okuma hatası: " + error.localizedDescription
            return
        }
        guard let string = value as? String, let data = string.data(using: .utf8), data.count < 12 * 1024 * 1024,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            message = "Sayfa verisi alınamadı. Listeye dönüp yüklenmesini bekle."
            return
        }
        let meta = object["meta"] as? [String: Any] ?? [:]
        // Only pages that actually carry a playlist id are allowed to feed the list, so a random
        // watch page or the home feed can never invent rows.
        let pageList = (meta["list"] as? String) ?? ""
        guard (meta["playlist"] as? Bool == true) || !pageList.isEmpty || isPlaylistContext() else {
            message = "Bu sayfada oynatma listesi yok. Listeyi aç; paneldeki ya da sayfadaki kayıtlar okunur."
            report = "Liste kimliği bulunamadı · " + ((meta["url"] as? String) ?? "")
            return
        }
        let additions = parseItems(object["items"])
        var known = Set(videos.map(\.id))
        for video in additions where videos.count < 500 && known.insert(video.id).inserted { videos.append(video) }
        if videos.count == lastCount { stableTicks += 1 } else { stableTicks = 0; lastCount = videos.count; settled = false }
        if stableTicks >= 3 { settled = true }
        updateMessage(meta)
        if offer, !videos.isEmpty, !offerShown { offerShown = true; offerCount = videos.count; showOffer = true }
    }
    private func parseItems(_ raw: Any?) -> [SavedVideo] {
        guard let list = raw as? [[String: Any]] else { return [] }
        var result: [SavedVideo] = []
        for entry in list {
            guard let id = entry["id"] as? String, MediaRules.youTubeID("https://youtu.be/\(id)") == id else { continue }
            let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result.append(SavedVideo(id: id, title: title.isEmpty ? "YouTube kaydı · \(id)" : title, channel: ""))
        }
        return result
    }
    private func updateMessage(_ meta: [String: Any]) {
        let rows = meta["rows"] as? Int ?? 0
        let fromData = meta["fromData"] as? Int ?? 0
        let fromFetch = meta["fromFetch"] as? Int ?? 0
        let status = meta["status"] as? Int ?? 0
        let html = meta["html"] as? Int ?? 0
        let pageTitle = (meta["title"] as? String) ?? ""
        self.pageTitle = pageTitle
        report = ["Sayfa: " + pageTitle,
                  "Adres: " + ((meta["url"] as? String) ?? ""),
                  "Liste kimliği: " + ((meta["list"] as? String) ?? "-"),
                  "Satır: \(rows) · Sayfa verisi: \(fromData) · Liste isteği: \(fromFetch)",
                  "İstek durumu: \(status) · HTML: \(html) bayt · Bulunan: \(videos.count)"]
            .joined(separator: "\n")
        if videos.isEmpty {
            message = "Liste açık ama kayıt okunamadı. “Aşağı kaydır ve oku” düğmesini dene; olmazsa tanılama satırlarını paylaş."
        } else if stableTicks >= 2 {
            message = "\(videos.count) kayıt algılandı. KontYT’ye alabilirsin; daha fazlası için sayfayı kaydır."
        } else {
            message = "\(videos.count) kayıt algılandı; sayfa yükleniyor olabilir."
        }
    }
    func readLoadedList() {
        guard !harvesting else { return }
        guard isPlaylistContext() else {
            message = "Önce oynatma listesi sayfasını aç. Liste dışındaki sayfalar okunmaz."
            return
        }
        harvest(offer: true)
    }
    /// Manual "scroll down and read" for pages that load the next rows only when scrolled.
    func scrollAndRead() {
        settled = false
        scrollRounds = max(scrollRounds, 0)
        webView.evaluateJavaScript("window.scrollTo({top: document.documentElement.scrollHeight, behavior: 'smooth'}); 'ok'") { _, _ in }
        Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.harvest(offer: true) }
        }
    }
    var offerTitle: String {
        let name = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Liste algılandı" }
        return "Liste algılandı · " + String(name.prefix(60))
    }
    func clearWebData() {
        webView.stopLoading(); videos = []; offerShown = false
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: Date.distantPast) { [weak self] in
            Task { @MainActor in
                self?.message = "Uygulama içi tarayıcının oturum ve web verileri silindi. Safari oturumu etkilenmez."
                self?.openTarget()
            }
        }
    }
}
private struct BrowserSurface: UIViewRepresentable {
    let model: YouTubeBrowserModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
struct YouTubeBrowserView: View {
    @StateObject private var model: YouTubeBrowserModel
    @Environment(\.dismiss) private var dismiss
    let onImport: ([SavedVideo], String) -> Void
    init(url: URL, onImport: @escaping ([SavedVideo], String) -> Void) {
        _model = StateObject(wrappedValue: YouTubeBrowserModel(url: url)); self.onImport = onImport
    }
    @State private var address = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                disclaimer
                addressRow
                controlRow
                modePicker
                Text(model.currentAddress).font(.caption2).lineLimit(1).padding(.horizontal)
                diagnosticsBox
                if model.loading || model.reading { ProgressView() }
                BrowserSurface(model: model)
                detectionRow
                autoRow
                importRow
            }
            .navigationTitle("Tarayıcı")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Kapat") { model.stopAutoDetect(); model.webView.stopLoading(); dismiss() } }
            .alert(model.offerTitle, isPresented: $model.showOffer) {
                Button("KontYT’ye al (\(model.offerCount))") { hand(model.videos, offerNote) }
                Button("Biraz bekle", role: .cancel) {}
            } message: {
                Text("Bu listede \(model.offerCount) kayıt bulundu. Müzik/video seçimiyle indirme listesine aktarılsın mı?")
            }
        }.onDisappear { model.stopAutoDetect(); model.webView.stopLoading() }
    }
    private var offerNote: String {
        "Tarayıcıda otomatik algılanan \(model.offerCount) kayıt; en çok 500. Listenin tamamı olmayabilir."
    }
    private func hand(_ videos: [SavedVideo], _ note: String) {
        onImport(videos, note)
        model.stopAutoDetect()
        model.webView.stopLoading()
        dismiss()
    }
    private var disclaimer: some View {
        Text("Serbest gezinme: herhangi bir HTTPS adresi ya da arama yazabilirsin. Onayı sayfada kendin ver; Google uygulama içi girişi engelleyebilir. Liste yalnız YouTube'da otomatik algılanır; tarayıcı çerezleri indirme motoruna aktarılmaz.")
            .font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
    }
    /// Any address, or a few words to search YouTube. Same logged-in web view throughout.
    private var addressRow: some View {
        HStack(spacing: 6) {
            TextField("Adres ya da arama", text: $address)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL).submitLabel(.go).font(.caption)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.open(address: address) }
            Button("Git") { model.open(address: address) }.font(.caption)
        }
        .padding(.horizontal)
        .onChange(of: model.currentAddress) { value in if !value.isEmpty { address = value } }
    }
    private var controlRow: some View {
        HStack(spacing: 14) {
            Button { model.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!model.canGoBack).accessibilityLabel("Geri")
            Button { model.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!model.canGoForward).accessibilityLabel("İleri")
            Button { model.reloadPage() } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("Yenile")
            Spacer()
            Button("Listeye dön") { model.openTarget() }
            PasteButton(payloadType: String.self) { values in
                if let text = values.first { model.open(address: text) }
            }.labelStyle(.iconOnly).accessibilityLabel("Panodaki bağlantıyı bu tarayıcıda aç")
            Menu("Oturum") { Button("Tarayıcı verilerini sil", role: .destructive) { model.clearWebData() } }
            Link("Safari", destination: model.target)
        }.padding(.horizontal)
    }
    private var modePicker: some View {
        Picker("Sayfa görünümü", selection: Binding(get: { model.desktop }, set: { model.setDesktop($0) })) {
            Text("Mobil").tag(false)
            Text("Masaüstü").tag(true)
        }.pickerStyle(.segmented).padding(.horizontal)
    }
    private var diagnosticsBox: some View {
        DisclosureGroup("Sayfa tanılama") {
            ScrollView {
                Text(model.report + "\n\n" + model.diagnostics).font(.caption2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 130)
            HStack {
                Button("Yenile") { model.inspectPage(); model.readLoadedList() }.font(.caption)
                Spacer()
                Button("Aşağı kaydır ve oku") { model.scrollAndRead() }.font(.caption)
            }
        }.font(.caption).padding(.horizontal)
    }
    private var detectionRow: some View {
        HStack(spacing: 6) {
            Image(systemName: model.videos.isEmpty ? "hourglass" : "checkmark.circle.fill")
                .foregroundStyle(model.videos.isEmpty ? Color.secondary : Color.mint)
            Text(model.message).font(.caption)
        }.padding(.horizontal)
    }
    private var autoRow: some View {
        HStack {
            Toggle("Otomatik algıla", isOn: Binding(get: { model.autoDetect }, set: { model.setAutoDetect($0) }))
                .labelsHidden().font(.caption)
            Text("Otomatik algıla").font(.caption2)
            Spacer()
            Button("Yeniden oku") { model.readLoadedList() }.font(.caption).disabled(model.reading || model.loading)
        }.padding(.horizontal)
    }
    private var importRow: some View {
        HStack {
            Button("KontYT’ye al (\(model.videos.count))") { hand(model.videos, offerNote) }
            .buttonStyle(.borderedProminent).tint(.mint)
            .disabled(model.videos.isEmpty)
        }.padding(.horizontal).padding(.bottom, 8)
    }
}
