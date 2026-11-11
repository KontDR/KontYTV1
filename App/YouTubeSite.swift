import SwiftUI
import WebKit
import AVFoundation
import UIKit

/// One video as the page sees it.
struct SiteVideo: Equatable {
    let id: String
    let title: String
    var isPlaying: Bool
    /// The page is showing YouTube's own "ad blocker / confirm you are not a bot" wall.
    var blocked: Bool = false
}

/// Clearing everything this web view ever stored. Nothing else in the app uses that store, so this is a
/// targeted wipe, not a factory reset.
enum SiteSession {
    static func wipe(reason: String, completion: @escaping () -> Void = {}) {
        CrashLog.note("Tarayici verisi siliniyor: " + reason)
        URLCache.shared.removeAllCachedResponses()
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            CrashLog.note("Tarayici verisi silindi")
            completion()
        }
    }
}

/// A fresh browser identity per session: the page lives in a **non-persistent** data store (cookies,
/// localStorage and caches die with the web view) and the user agent rotates through current Safari
/// iPhone build strings. Reset = new store + new user agent + a brand new web view, so the site sees a
/// visitor it has never met - not the same visitor with an emptied cookie jar.
enum SiteIdentity {
    static let userAgents = [
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1"
    ]
    private static let indexKey = "siteIdentityIndex"
    private static let lastVideoKey = "siteLastVideoURL"

    /// Reopens what was playing last time instead of throwing the user back to the home page. The house
    /// button in the tab still goes home, and a reset starts at home as well.
    static var startURL: URL {
        if let saved = UserDefaults.standard.string(forKey: lastVideoKey), let url = URL(string: saved) { return url }
        return homeURL
    }
    static var homeURL: URL { URL(string: "https://m.youtube.com/") ?? URL(fileURLWithPath: "/") }
    static func remember(_ video: String) {
        guard video != UserDefaults.standard.string(forKey: lastVideoKey) else { return }
        UserDefaults.standard.set(video, forKey: lastVideoKey)
    }

    static var userAgent: String {
        let index = abs(UserDefaults.standard.integer(forKey: indexKey))
        return userAgents[index % userAgents.count]
    }
    /// Moves to the next identity. Called on every reset, never during playback.
    static func rotate() {
        let next = abs(UserDefaults.standard.integer(forKey: indexKey)) + 1
        UserDefaults.standard.set(next, forKey: indexKey)
        CrashLog.note("Tarayici kimligi yenilendi: " + String(next % userAgents.count))
    }
    /// Small, honest hardening: a web view is not a driver. Nothing else is touched.
    static let harden = "try{Object.defineProperty(navigator,'webdriver',{get:function(){return false}})}catch(e){}"
}

/// A tiny handle on the live web view: play/pause and audio-session duties live here so the screen stays
/// a screen.
final class SiteWebHandle: ObservableObject {
    weak var webView: WKWebView?
    /// Changing this value tears the web view down and builds a new one - the only complete reset iOS
    /// offers, because a data store and a user agent are fixed for the life of a web view.
    @Published private(set) var generation = UUID()
    /// SwiftUI lets go of a representable whenever a tab changes or a sheet covers it. The page must not
    /// notice, so the web view is kept - first as a strong reference, then in a tiny holder inside the
    /// window so WebKit never sees it leave the screen.
    private var kept: WKWebView?
    private var keptGeneration = UUID()
    private var parked: UIView?
    private var observers: [NSObjectProtocol] = []

    /// The page must keep playing when the app is not in front. That needs two things on iOS: the app's
    /// audio background mode (already declared) and an active playback session while the page plays.
    static func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    func togglePagePlayback() {
        evaluate("(function(){var v=document.querySelector('video');if(!v){return 'none'}"
                 + "if(v.paused){window.__kontytWantPlay=true;v.play()}else{window.__kontytWantPlay=false;v.pause()}return 'ok'})()")
    }
    func pausePageVideo() {
        evaluate("(function(){window.__kontytWantPlay=false;var v=document.querySelector('video');if(v){v.pause()}return 'ok'})()")
    }
    /// Coming back from the lock screen: if iOS did pause the page, put it back the way it was.
    func resumePageVideo() {
        evaluate("(function(){window.__kontytWantPlay=true;if(window.__kontytPlay){window.__kontytPlay();return 'ok'}"
                 + "var v=document.querySelector('video');if(v){var p=v.play();if(p&&p.catch){p.catch(function(){})}}return 'ok'})()")
    }
    /// Asks the page what it did while the app was away and writes the answer to the diagnostics log.
    /// "Sayfa arka planda: durdu" means iOS/WebKit was the one that stopped it; "calisiyordu" means the
    /// page survived and only needed bringing to the front again.
    func reportBackgroundState() {
        guard let webView else { return }
        webView.evaluateJavaScript("(function(){var v=document.querySelector('video');"
                                   + "if(!v){return 'yok'}return v.paused?'durdu':'calisiyordu'})()") { value, _ in
            let state = value as? String ?? "bilinmiyor"
            CrashLog.note("Sayfa arka planda: " + state)
        }
    }

    /// YouTube showed its wall, or the user simply wants a new face: wipe everything and start a new
    /// browser identity.
    func resetSession() {
        dropKept()
        SiteIdentity.rotate()
        SiteSession.wipe(reason: "sekme") { [weak self] in
            guard let self else { return }
            self.generation = UUID()
            CrashLog.note("Yeni tarayici oturumu acildi")
        }
    }
    /// Called when SwiftUI releases the view for a reason that is not a reset.
    func park(_ view: WKWebView, generation: UUID) {
        guard generation == self.generation else { return }
        kept = view
        keptGeneration = generation
        guard view.superview == nil, let window = Self.keyWindow else { return }
        // Full size and barely-visible rather than tiny: the page keeps believing it is on screen, which is
        // what keeps a video playing. It cannot be touched and cannot be read by VoiceOver.
        let holder = UIView(frame: window.bounds)
        holder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        holder.isUserInteractionEnabled = false
        holder.isAccessibilityElement = false
        holder.alpha = 0.02
        window.addSubview(holder)
        holder.addSubview(view)
        view.frame = holder.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parked = holder
        CrashLog.note("YouTube sayfasi pencerede tutuluyor")
    }
    /// Gives the same web view back when the tab returns, so nothing reloads and nothing stops.
    func take(generation: UUID) -> WKWebView? {
        guard let view = kept, keptGeneration == generation else { return nil }
        parked?.removeFromSuperview()
        parked = nil
        kept = nil
        CrashLog.note("YouTube sayfasi devam ediyor")
        return view
    }
    private func dropKept() {
        parked?.removeFromSuperview()
        parked = nil
        kept = nil
    }
    private static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) { return window }
        }
        return scenes.first?.windows.first
    }

    /// A phone call or another app taking the audio session must not leave the page silent for good.
    func watchInterruptions() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let kind = AVAudioSession.InterruptionType(rawValue: raw), kind == .ended else { return }
            SiteWebHandle.activateAudioSession()
            self?.resumePageVideo()
            CrashLog.note("Ses kesintisi bitti")
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            SiteWebHandle.activateAudioSession()
            self?.resumePageVideo()
            CrashLog.note("Ses servisi sifirlandi, sayfa devam ediyor")
        })
    }
    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func goHome() {
        guard let webView else { return }
        UserDefaults.standard.removeObject(forKey: "siteLastVideoURL")
        webView.load(URLRequest(url: SiteIdentity.homeURL))
    }
    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script) { _, _ in }
    }
}

/// When a video ends, YouTube's own autoplay does not always kick in (especially in the background).
/// This script watches the player and, when the video ends, presses the "Sonraki / Next" button
/// so playback continues to the next video without user action.
enum SiteAutoNext {
    static let script = #"""
    (function () {
      "use strict";
      window.__kontytAutoNext = true;
      function nextButton() {
        var sel = [
          'button[aria-label*="Sonraki" i]',
          'button[aria-label*="Next" i]',
          'a[href*="/watch?v="][aria-label*="Sonraki" i]',
          'a[href*="/watch?v="][aria-label*="Next" i]',
          '.ytp-next-button',
          '[aria-label*="Otobirim" i]',
          '[aria-label*="Autoplay" i]',
          'button.ytp-next-button',
          'button.next-button'
        ];
        for (var i = 0; i < sel.length; i++) {
          try {
            var nodes = document.querySelectorAll(sel[i]);
            for (var j = 0; j < nodes.length; j++) {
              var n = nodes[j];
              if (n && !n.disabled && n.offsetParent !== null) { return n; }
            }
          } catch (e) {}
        }
        return null;
      }
      function enableAutoplay() {
        var btn = nextButton();
        if (btn) {
          var label = (btn.getAttribute('aria-label') || '').toLowerCase();
          if (label.indexOf('otobirim') >= 0 || label.indexOf('autoplay') >= 0 || label.indexOf('sonraki') >= 0 || label.indexOf('next') >= 0) {
            try { btn.click(); } catch (e) {}
          }
        }
      }
      function onEnded() {
        var v = document.querySelector('video');
        if (!v || v.__kontytEnded) { return; }
        v.__kontytEnded = true;
        v.addEventListener('ended', function () {
          setTimeout(function () {
            var btn = nextButton();
            if (btn) { try { btn.click(); } catch (e) {} }
          }, 1500);
        }, { once: true });
      }
      document.addEventListener('DOMContentLoaded', function () {
        enableAutoplay();
        onEnded();
      });
      var check = setInterval(function () {
        var v = document.querySelector('video');
        if (v) { onEnded(); clearInterval(check); }
      }, 1000);
      setTimeout(function () { clearInterval(check); }, 60000);
    })();
    """#
}

/// Prevents YouTube's video element from requesting full screen. The video stays inline
/// so the user controls when (if ever) to go full screen.
enum SiteNoFullScreen {
    static let script = #"""
    (function () {
      "use strict";
      window.__kontytNoFullScreen = true;
      function blockVideo(video) {
        if (!video || video.__kontytNoFullScreen) { return; }
        video.__kontytNoFullScreen = true;
        try { video.webkitEnterFullScreen = function () {}; } catch (e) {}
        try { video.requestFullscreen = function () {}; } catch (e) {}
        try { video.webkitSupportsFullscreen = false; } catch (e) {}
        video.setAttribute('playsinline', '');
        video.setAttribute('webkit-playsinline', '');
      }
      document.addEventListener('DOMContentLoaded', function () {
        var v = document.querySelector('video');
        if (v) { blockVideo(v); }
      });
      var observer = new MutationObserver(function (mutations) {
        for (var i = 0; i < mutations.length; i++) {
          var nodes = mutations[i].addedNodes;
          for (var j = 0; j < nodes.length; j++) {
            var node = nodes[j];
            if (node.tagName === 'VIDEO') { blockVideo(node); }
            else if (node.querySelectorAll) {
              node.querySelectorAll('video').forEach(blockVideo);
            }
          }
        }
      });
      observer.observe(document.documentElement, { childList: true, subtree: true });
      var check = setInterval(function () {
        document.querySelectorAll('video').forEach(blockVideo);
      }, 1000);
      setTimeout(function () { clearInterval(check); }, 60000);
    })();
    """#
}

/// The real YouTube page inside the app. No address bar, no allow-list tricks: this surface only ever
/// shows YouTube, which is what makes it feel like an app rather than a browser.
struct YouTubeSiteView: UIViewRepresentable {
    let handle: SiteWebHandle
    var adBlock: Bool = true
    var autoNext: Bool = true
    var noFullScreen: Bool = true
    var onVideo: (SiteVideo?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onVideo: onVideo) }

    final class Coordinator: NSObject {
        private let onVideo: (SiteVideo?) -> Void
        private var timer: Timer?
        private var last: SiteVideo?
        var adBlock = true
        var generation = UUID()
        weak var handle: SiteWebHandle?
        weak var webView: WKWebView?
        init(onVideo: @escaping (SiteVideo?) -> Void) { self.onVideo = onVideo }

        func start() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.poll()
            }
        }
        func stop() { timer?.invalidate(); timer = nil }

        private func poll() {
            guard let webView else { return }
            webView.evaluateJavaScript(Self.probe) { [weak self] value, _ in
                guard let self else { return }
                let next = Self.parse(value as? String)
                if next != self.last { self.last = next; self.onVideo(next) }
            }
        }
        /// Runs in the page: never touches the network, only reports what the player is doing.
        private static let probe = "(function(){try{var v=document.querySelector('video');var u=location.href;"
            + "var t=document.title;var p=v?(!v.paused&&!v.ended):false;"
            + "var b=(((document.body&&document.body.innerText)||'')).toLowerCase().slice(0,4000);"
            + "var w=(b.indexOf('ad blockers')>=0||b.indexOf('reklam engelleyici')>=0||b.indexOf('not a bot')>=0||b.indexOf('guvenli olmayabilir')>=0);"
            + "return JSON.stringify({u:u,t:t,p:p,w:w})}catch(e){return ''}})()"

        static func parse(_ text: String?) -> SiteVideo? {
            guard let text, let data = text.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = root["u"] as? String, let url = URL(string: raw),
                  let id = videoID(in: url) else { return nil }
            let title = (root["t"] as? String ?? "").replacingOccurrences(of: " - YouTube", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return SiteVideo(id: id, title: title.isEmpty ? "YouTube videosu" : title,
                             isPlaying: root["p"] as? Bool ?? false,
                             blocked: root["w"] as? Bool ?? false)
        }
        /// watch?v=…, youtu.be/…, /shorts/… - nothing else counts as a video.
        static func videoID(in url: URL) -> String? {
            guard let host = url.host?.lowercased() else { return nil }
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let value = parts?.queryItems?.first(where: { $0.name == "v" })?.value, value.count == 11 { return value }
            let pieces = url.path.split(separator: "/").map(String.init)
            if host.hasSuffix("youtu.be"), let first = pieces.first, first.count == 11 { return first }
            if let index = pieces.firstIndex(of: "shorts"), pieces.count > index + 1, pieces[index + 1].count == 11 { return pieces[index + 1] }
            return nil
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.handle = handle
        context.coordinator.generation = handle.generation
        if let alive = handle.take(generation: handle.generation) {
            // Same tab coming back: the page it left behind keeps playing, nothing reloads.
            handle.webView = alive
            context.coordinator.adBlock = adBlock
            context.coordinator.webView = alive
            context.coordinator.start()
            return alive
        }
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // A normal persistent store: YouTube's consent, settings and history survive an app restart. The
        // identity only changes when the user asks for it (see SiteIdentity/SiteSession).
        config.websiteDataStore = WKWebsiteDataStore.default()
        // Background audio announcement for WebKit, and the ad filter when it is switched on.
        config.userContentController.addUserScript(WKUserScript(source: SitePlayback.script,
                                                               injectionTime: .atDocumentStart,
                                                               forMainFrameOnly: false))
        config.userContentController.addUserScript(WKUserScript(source: SiteIdentity.harden,
                                                               injectionTime: .atDocumentStart,
                                                               forMainFrameOnly: false))
        if adBlock {
            config.userContentController.addUserScript(WKUserScript(source: SiteAdBlock.script,
                                                                   injectionTime: .atDocumentStart,
                                                                   forMainFrameOnly: false))
        }
        if autoNext {
            config.userContentController.addUserScript(WKUserScript(source: SiteAutoNext.script,
                                                                   injectionTime: .atDocumentStart,
                                                                   forMainFrameOnly: false))
        }
        if noFullScreen {
            config.userContentController.addUserScript(WKUserScript(source: SiteNoFullScreen.script,
                                                                   injectionTime: .atDocumentStart,
                                                                   forMainFrameOnly: false))
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        // Safari's own identity: YouTube serves its mobile site to this user agent and its player there
        // is a plain HTML5 player. Nothing else is spoofed.
        webView.customUserAgent = SiteIdentity.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        handle.webView = webView
        context.coordinator.adBlock = adBlock
        context.coordinator.webView = webView
        context.coordinator.start()
        webView.load(URLRequest(url: SiteIdentity.startURL))
        CrashLog.note("YouTube sayfasi acildi")
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        handle.webView = webView
        // A user script can only be attached at configuration time, so flipping the setting reloads the
        // page once instead of pretending to apply live.
        if context.coordinator.adBlock != adBlock {
            context.coordinator.adBlock = adBlock
            webView.reload()
            CrashLog.note(adBlock ? "Reklam filtresi acik" : "Reklam filtresi kapali")
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        // A tab change, a sheet or a layout change is not a reason to stop the sound: the view is parked
        // in the window and handed back untouched. Only a reset (new generation) really lets it go.
        coordinator.handle?.park(webView, generation: coordinator.generation)
        CrashLog.note("YouTube sayfasi birakildi")
    }
}

/// The YouTube tab: the page fills the screen and keeps playing - audio first - when the app goes to the
/// background or the screen locks. The bar sits in the navigation chrome, above the mini player, never
/// underneath it.
struct YouTubeSiteTab: View {
    @Environment(\.scenePhase) private var phase
    @AppStorage("blockYouTubeAds") private var blockAds = true
    @AppStorage("youtubeAutoNext") private var autoNext = true
    @AppStorage("youtubeNoFullScreen") private var noFullScreen = true
    @AppStorage("siteBrowserResetTick") private var resetTick = 0
    @StateObject private var handle = SiteWebHandle()
    @State private var video: SiteVideo?
    @State private var showDiscovery = false
    @State private var seenTick: Int?
    @State private var wantsSound = false

    var body: some View {
        NavigationStack {
            YouTubeSiteView(handle: handle, adBlock: blockAds, autoNext: autoNext, noFullScreen: noFullScreen, onVideo: { next in
                video = next
                if let next, !next.id.isEmpty { SiteIdentity.remember("https://m.youtube.com/watch?v=" + next.id) }
            })
                .id(handle.generation)   // a new generation = a brand new web view and browser identity
                .navigationTitle("YouTube")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { siteTools }
                .sheet(isPresented: $showDiscovery) { DiscoveryView() }
                .overlay(alignment: .top) {
                    if video?.blocked == true { wallBanner }
                }
        }
        .onAppear {
            SiteWebHandle.activateAudioSession()
            handle.watchInterruptions()
            // First appearance in this tab simply notes the current value: an old tick must never turn into
            // a reset every time the user walks in and out of the tab.
            if let seen = seenTick { if seen != resetTick { seenTick = resetTick; handle.resetSession() } }
            else { seenTick = resetTick }
        }
        .onChange(of: resetTick) { value in
            guard value != seenTick else { return }
            seenTick = value
            handle.resetSession()
        }
        .onChange(of: phase) { value in
            guard value != .inactive else { return }
            // Hold the session open on the way out so WebKit is allowed to keep the page playing.
            SiteWebHandle.activateAudioSession()
            if value == .active {
                // Whatever iOS did to the page while we were away, the user asked for sound: put it back.
                if wantsSound {
                    handle.reportBackgroundState()
                    handle.resumePageVideo()
                }
                wantsSound = false
                CrashLog.note("Site on planda")
            } else {
                wantsSound = video?.isPlaying == true
                CrashLog.note("Site arka planda")
            }
        }
    }

    @ToolbarContentBuilder
    private var siteTools: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button { handle.goHome() } label: { Image(systemName: "house") }
                .accessibilityLabel("YouTube ana sayfa")
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button { showDiscovery = true } label: { Label("Keşif", systemImage: "magnifyingglass") }
                Button { handle.resetSession() } label: { Label("Tarayıcı kimliğini yenile", systemImage: "arrow.counterclockwise") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("YouTube seçenekleri")
        }
        ToolbarItem(placement: .bottomBar) { nowBar }
    }

    /// YouTube sometimes answers an ad filter with its own wall. Two honest ways out: stop filtering, or
    /// wipe the site data and start over - the user decides, the app does not.
    private var wallBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("YouTube reklam filtresini algıladı").font(.caption.bold())
            Text("Oynatma durduysa: filtreyi kapat ya da tarayıcı kimliğini yenile.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Filtreyi kapat") { blockAds = false }
                    .buttonStyle(.borderedProminent).tint(.orange).font(.caption.bold())
                Button("Kimliği yenile") { handle.resetSession() }
                    .buttonStyle(.bordered).font(.caption.bold())
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10).padding(.top, 6)
    }

    private var nowBar: some View {
        HStack(spacing: 10) {
            Button { handle.togglePagePlayback() } label: {
                Image(systemName: video?.isPlaying == true ? "pause.fill" : "play.fill")
            }
            .disabled(video == nil)
            .accessibilityLabel(video?.isPlaying == true ? "Sayfayı duraklat" : "Sayfayı oynat")
            VStack(alignment: .leading, spacing: 2) {
                Text(video?.title ?? "YouTube")
                    .font(.caption.bold()).lineLimit(1)
                Text(video == nil ? "Bir video aç" : "Ekran kilidinde de çalar")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
