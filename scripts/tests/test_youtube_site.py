"""The YouTube tab: the real page, and one button that hands the sound to the native player so it keeps
playing with the screen locked. These checks keep the two promises honest - YouTube only, and the
hand-off really goes through the archive pipeline instead of pretending."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SITE = ROOT / 'App/YouTubeSite.swift'
FORBIDDEN = ['callAsyncJavaScript', 'evaluateJavaScript(_:in:in:)', 'WKContentWorld', 'takeSnapshot', 'createPDF']


def read(name):
    return (ROOT / name).read_text(encoding='utf-8')


class SiteSurface(unittest.TestCase):
    def test_the_tab_shows_only_youtube(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('https://m.youtube.com/', site)
        self.assertNotIn('http://', site, 'never fall back to plain HTTP')
        # No address bar: this is not a browser, it is the YouTube screen.
        self.assertNotIn('TextField', site)

    def test_inline_playback_is_configured(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('config.allowsInlineMediaPlayback = true', site)
        self.assertIn('config.mediaTypesRequiringUserActionForPlayback = []', site)
        self.assertIn('config.defaultWebpagePreferences.allowsContentJavaScript = true', site)

    def test_no_webkits_swift_overlay(self):
        site = SITE.read_text(encoding='utf-8')
        hits = [token for token in FORBIDDEN if token in site]
        self.assertEqual([], hits, 'these autolink libswiftWebKit and break launches on iOS 18.4+')
        self.assertIn('evaluateJavaScript(', site)

    def test_the_page_is_polled_not_rewritten(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true)', site)
        self.assertIn('querySelector(\'video\')', site)
        self.assertIn('self?.poll()', site, 'the timer closure must not capture bare properties')
        self.assertNotIn('document.write', site)

    def test_video_identifiers(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('$0.name == "v"', site, 'watch?v=')
        self.assertIn('hasSuffix("youtu.be")', site, 'short links')
        self.assertIn('firstIndex(of: "shorts")', site, 'shorts')
        for marker in ['value.count == 11', 'first.count == 11', 'pieces[index + 1].count == 11']:
            self.assertIn(marker, site, 'YouTube ids are exactly 11 characters')

    def test_a_tab_change_parks_the_page_and_a_reset_lets_it_go(self):
        site = SITE.read_text(encoding='utf-8')
        body = site.split('static func dismantleUIView', 1)[1]
        self.assertIn('coordinator.stop()', body)
        self.assertIn('coordinator.handle?.park(webView, generation: coordinator.generation)', body)
        self.assertNotIn('v.pause()', body, 'letting go of the view must never pause the page')
        self.assertNotIn('stopLoading()', body)
        self.assertIn('CrashLog.note(', body)
        self.assertIn('func park(_ view: WKWebView, generation: UUID)', site)
        self.assertIn('func take(generation: UUID) -> WKWebView?', site)
        self.assertIn('dropKept()', site)


class BackgroundSurvival(unittest.TestCase):
    """Every way the page can be taken off screen - tab change, sheet, lock, home - must leave the sound
    running. These checks pin the mechanisms, not the outcome (which needs a device)."""

    def test_the_web_view_is_handed_back_instead_of_rebuilt(self):
        site = SITE.read_text(encoding='utf-8')
        make = site.split('func makeUIView', 1)[1].split('let config = WKWebViewConfiguration()', 1)[0]
        self.assertIn('if let alive = handle.take(generation: handle.generation)', make)
        self.assertIn('context.coordinator.start()', make)
        self.assertNotIn('webView.load(', make, 'a returning tab must not reload the page')

    def test_the_parked_view_stays_believable_as_a_screen(self):
        site = SITE.read_text(encoding='utf-8')
        park = site.split('func park(_ view: WKWebView', 1)[1].split('func take(', 1)[0]
        self.assertIn('let holder = UIView(frame: window.bounds)', park)
        self.assertIn('holder.isUserInteractionEnabled = false', park)
        self.assertIn('window.addSubview(holder)', park)
        self.assertIn('CrashLog.note("YouTube sayfasi pencerede tutuluyor")', park)

    def test_the_page_never_tells_itself_it_is_hidden(self):
        script = (ROOT / 'App/SiteAdBlock.swift').read_text(encoding='utf-8')
        for pair in ['["hidden", false]', '["visibilityState", "visible"]', '["webkitHidden", false]']:
            self.assertIn(pair, script)
        self.assertIn('function pin(name, value)', script)
        self.assertIn('Object.defineProperty(document, name, { get: function () { return value; }', script)
        self.assertIn('if (window.__kontytWantPlay) { play(); }', script)
        self.assertIn('window.__kontytPlay = play;', script)

    def test_an_audio_interruption_is_recovered(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('AVAudioSession.interruptionNotification', site)
        self.assertIn('AVAudioSession.mediaServicesWereResetNotification', site)
        self.assertIn('AVAudioSession.InterruptionType(rawValue: raw)', site)
        self.assertIn(', kind == .ended else { return }', site)
        self.assertIn('handle.watchInterruptions()', site)
        self.assertIn('deinit {', site)

    def test_the_page_is_put_back_when_the_app_returns(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('@State private var wantsSound = false', site)
        self.assertIn('if wantsSound {', site)
        self.assertIn('handle.resumePageVideo()', site)
        self.assertIn('wantsSound = video?.isPlaying == true', site)

    def test_what_happened_while_away_is_written_down(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('func reportBackgroundState()', site)
        self.assertIn("return v.paused?'durdu':'calisiyordu'", site)
        self.assertIn('CrashLog.note("Sayfa arka planda: " + state)', site)
        self.assertIn('handle.reportBackgroundState()', site)

    def test_pause_and_play_remember_what_the_user_wanted(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('window.__kontytWantPlay=true;v.play()', site.replace(' ', ''))
        self.assertIn('window.__kontytWantPlay=false;v.pause()', site.replace(' ', ''))
        self.assertIn('window.__kontytWantPlay=true;if(window.__kontytPlay)', site.replace(' ', ''))


class BackgroundAudio(unittest.TestCase):
    """The page itself must keep playing - no download, no hand-off to the local player."""

    def test_no_download_handoff(self):
        site = SITE.read_text(encoding='utf-8')
        for gone in ['flow.enqueue', 'library.play(', 'SavedVideo(', 'Arka planda dinle', 'sourceVideoID']:
            self.assertNotIn(gone, site, 'the tab plays the page; it must not download or take over playback')

    def test_the_audio_session_is_held_while_the_page_plays(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('static func activateAudioSession()', site)
        self.assertIn('try? session.setCategory(.playback, mode: .default)', site)
        self.assertIn('try? session.setActive(true)', site)
        self.assertIn('SiteWebHandle.activateAudioSession()', site)
        self.assertIn('.onAppear {', site)
        body = site.split('.onChange(of: phase)', 1)[1][:400]
        self.assertIn('SiteWebHandle.activateAudioSession()', body)
        self.assertIn('guard value != .inactive else { return }', body)

    def test_the_page_is_told_it_may_keep_playing(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('SitePlayback.script', site)
        self.assertIn('injectionTime: .atDocumentStart', site)
        script = (ROOT / 'App/SiteAdBlock.swift').read_text(encoding='utf-8')
        self.assertIn('navigator.audioSession', script)
        self.assertIn('navigator.audioSession.type = "playback"', script)
        self.assertIn('"visibilitychange"', script)

    def test_coming_back_resumes_the_picture(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('func resumePageVideo()', site)
        self.assertIn('if wantsSound {', site)
        self.assertIn('handle.resumePageVideo()', site)
        self.assertIn('CrashLog.note("Site on planda")', site)
        self.assertIn('CrashLog.note("Site arka planda")', site)


class WallAndReset(unittest.TestCase):
    """If YouTube answers the ad filter with its own wall, the app must not fight it: it offers two
    honest exits and the user picks one."""

    def test_the_session_reset_only_touches_youtube_data(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('enum SiteSession', site)
        self.assertIn('WKWebsiteDataStore.default()', site)
        self.assertIn('removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)', site)
        self.assertIn('URLCache.shared.removeAllCachedResponses()', site)
        self.assertIn('CrashLog.note("Tarayici verisi siliniyor: " + reason)', site)
        self.assertIn('SiteSession.wipe(reason: "sekme")', site)
        self.assertIn('siteBrowserResetTick += 1', read('App/StudioViews.swift'))

    def test_the_wall_is_detected_from_the_page(self):
        site = SITE.read_text(encoding='utf-8')
        for phrase in ["'ad blockers'", "'reklam engelleyici'", "'not a bot'"]:
            self.assertIn(phrase, site, 'the wall is recognised by its own words')
        self.assertIn('blocked: root["w"] as? Bool ?? false', site)
        self.assertIn('var blocked: Bool = false', site)
        self.assertIn('slice(0,4000)', site, 'only a slice of the page text is inspected')

    def test_the_banner_offers_both_exits(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('if video?.blocked == true { wallBanner }', site)
        self.assertIn('Button("Filtreyi kapat") { blockAds = false }', site)
        self.assertIn('Button("Kimliği yenile") { handle.resetSession() }', site)
        self.assertIn('Oynatma durduysa: filtreyi kapat ya da tarayıcı kimliğini yenile.', site)
        self.assertIn('Label("Tarayıcı kimliğini yenile", systemImage: "arrow.counterclockwise")', site)


class FreshIdentity(unittest.TestCase):
    """A reset must hand YouTube a visitor it has never seen: new store, new user agent, new web view."""

    def test_the_store_persists_and_only_a_reset_wipes_it(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('config.websiteDataStore = WKWebsiteDataStore.default()', site)
        self.assertNotIn('nonPersistent()', site,
                         'a non-persistent store threw YouTube away on every restart')
        self.assertIn('SiteSession.wipe(reason: "sekme")', site)

    def test_the_tab_never_resets_itself_on_appearance(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('@State private var seenTick: Int?', site)
        self.assertIn('if let seen = seenTick { if seen != resetTick { seenTick = resetTick; handle.resetSession() } }', site)
        self.assertIn('else { seenTick = resetTick }', site)

    def test_the_last_video_comes_back(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('static var startURL: URL', site)
        self.assertIn('webView.load(URLRequest(url: SiteIdentity.startURL))', site)
        self.assertIn('SiteIdentity.remember("https://m.youtube.com/watch?v=" + next.id)', site)
        self.assertIn('UserDefaults.standard.removeObject(forKey: "siteLastVideoURL")', site)

    def test_the_user_agent_rotates(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('enum SiteIdentity', site)
        self.assertIn('static let userAgents = [', site)
        self.assertIn('Version/17.6 Mobile/15E148 Safari/604.1', site)
        self.assertIn('Version/18.1 Mobile/15E148 Safari/604.1', site)
        self.assertIn('webView.customUserAgent = SiteIdentity.userAgent', site)
        self.assertIn('UserDefaults.standard.set(next, forKey: indexKey)', site)
        self.assertIn('SiteIdentity.rotate()', site)
        self.assertIn('CrashLog.note("Tarayici kimligi yenilendi: "', site)

    def test_the_reset_rebuilds_the_web_view(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('@Published private(set) var generation = UUID()', site)
        self.assertIn('self.generation = UUID()', site)
        self.assertIn('.id(handle.generation)', site)
        self.assertIn('CrashLog.note("Yeni tarayici oturumu acildi")', site)

    def test_the_page_is_not_a_driver(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn("Object.defineProperty(navigator,'webdriver',{get:function(){return false}})", site)
        self.assertIn('injectionTime: .atDocumentStart,\n                                                               forMainFrameOnly: false))\n        if adBlock', site)

    def test_settings_can_ask_for_a_new_identity_from_another_tab(self):
        site = SITE.read_text(encoding='utf-8')
        settings = read('App/StudioViews.swift')
        self.assertIn('@AppStorage("siteBrowserResetTick") private var resetTick = 0', site)
        self.assertIn('@AppStorage("siteBrowserResetTick") private var siteBrowserResetTick = 0', settings)
        self.assertIn('.onChange(of: resetTick) { value in', site)
        self.assertIn('handle.resetSession()', site)

    def test_auto_next_keeps_playing_after_the_video_ends(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('enum SiteAutoNext', site)
        self.assertIn('window.__kontytAutoNext = true', site)
        self.assertIn("'ended'", site)
        self.assertIn("nextButton()", site)
        self.assertIn('@AppStorage("youtubeAutoNext") private var autoNext = true', site)
        self.assertIn('autoNext: autoNext', site)


class TabWiring(unittest.TestCase):
    def test_the_fifth_tab_is_the_site_and_discovery_stays_reachable(self):
        studio = read('App/StudioViews.swift')
        self.assertIn('YouTubeSiteTab()', studio)
        self.assertIn('YouTubeSiteTab().environmentObject(library)', studio)
        self.assertNotIn('DiscoveryView().modifier(GlobalMiniPlayer(onOpen: { showGlobalPlayer = true })).tag(3)', studio)
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('Label("Keşif", systemImage: "magnifyingglass")', site)
        self.assertIn('showDiscovery = true', site)
        self.assertIn('.sheet(isPresented: $showDiscovery) { DiscoveryView() }', site)
        # five tabs, no "More" overflow
        self.assertEqual(5, len(re.findall(r'\.tabItem \{', studio)))

    def test_the_site_tab_takes_the_audio_session_it_needs(self):
        site = SITE.read_text(encoding='utf-8')
        self.assertIn('import AVFoundation', site)


if __name__ == '__main__':
    unittest.main()
