"""Source guards for the R14 revision: popup queue/bookmarks, live effects, playlist fallback.

These are text-level checks. They catch regressions such as re-introducing chained sheets,
dropping the consent cookies, or falling back to per-row publishing during bulk enqueue.
They do not replace an Xcode build or a device test.
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def read(name):
    return (ROOT / name).read_text()


class PlayerUIPopupChecks(unittest.TestCase):
    def test_queue_uses_one_item_driven_sheet(self):
        view = read('App/NowPlayingView.swift')
        self.assertIn('.sheet(item: $activeSheet)', view, 'player must use one item-driven sheet slot')
        self.assertEqual(view.count('.sheet('), 2, 'only the item sheet and the effects sheet may exist')
        self.assertNotIn('showQueue', view, 'queue must not be driven by a second chained sheet')
        self.assertIn('case lyrics, queue', view)
        self.assertIn('presentationDetents([.medium, .large])', view)

    def test_queue_opens_as_a_popup_and_can_be_reordered(self):
        view = read('App/NowPlayingView.swift')
        self.assertNotIn('DisclosureGroup("Sıradakiler', view, 'queue must not expand inline under the player')
        self.assertIn('activeSheet = .queue', view)
        self.assertIn('library.moveQueue(', view)
        self.assertIn('library.removeFromQueue(', view)
        library = read('App/KontYTApp.swift')
        for symbol in ['func moveQueue(', 'func moveQueueItem(', 'func removeFromQueue(']:
            self.assertIn(symbol, library)

    def test_bookmark_ui_is_removed(self):
        # Requested removal: no bookmark button or sheet anywhere in the player.
        view = read('App/NowPlayingView.swift')
        for symbol in ['bookmark.badge.plus', 'library.addBookmark()', 'case .bookmarks', 'bookmarkSheet',
                       'Yer imi ekle', 'Yer imleri']:
            self.assertNotIn(symbol, view, symbol + ' must be gone from the player')

    def test_effects_sheet_exposes_live_controls_only(self):
        view = read('App/NowPlayingView.swift')
        for control in ['setLiveGain', 'setLiveReverb', 'setLivePitch', 'resetLiveEffects', 'setRate']:
            self.assertIn(control, view, control + ' missing from the effects sheet')
        self.assertIn('Yavaşlat · perde korunur', view)


class LiveEffectEngineChecks(unittest.TestCase):
    def test_engine_keeps_realtime_rules(self):
        engine = read('App/LiveAudioGain.swift')
        prepare = engine[engine.index('prepare: {'):engine.index('unprepare: {')]
        process = engine[engine.index('process: {'):]
        for forbidden in ['String(', 'print(', 'Data(', 'try ', 'Data(contentsOf']:
            self.assertNotIn(forbidden, process, 'process callback must stay allocation and log free')
        self.assertIn('EffectEngine(sampleRate:', prepare, 'buffers must be allocated during prepare')
        self.assertIn('UnsafeMutableAudioBufferListPointer', process)
        self.assertIn('isNeutral', process, 'neutral settings must bypass the DSP')
        self.assertIn('NSLock', engine)

    def test_tap_shares_one_settings_object_with_the_ui(self):
        engine = read('App/LiveAudioGain.swift')
        self.assertIn('EffectTapContext(value: value)', engine)
        self.assertNotIn('guard let storage = MTAudioProcessingTapGetStorage', engine)
        self.assertIn('MTAudioProcessingTapGetStorage(tap)', engine)

    def test_reverb_and_pitch_are_real_dsp_not_labels(self):
        engine = read('App/LiveAudioGain.swift')
        for symbol in ['CombFilter', 'AllpassFilter', 'PitchChannel', 'pitchSlope', 'Hann']:
            self.assertIn(symbol, engine, symbol + ' missing from the DSP engine')
        # Offline boost must survive the live effects rewrite.
        self.assertIn('boostAudio', read('App/KontYTApp.swift'))
        self.assertIn('dB artırılmış M4A', read('App/NowPlayingView.swift'))


class PlaylistFallbackChecks(unittest.TestCase):
    def test_playlist_tries_desktop_then_mobile_with_consent_cookies(self):
        client = read('App/YouTubeWebClient.swift')
        self.assertIn('"https://www.youtube.com/playlist?list=', client)
        self.assertIn('"https://m.youtube.com/playlist?list=', client)
        self.assertIn('SOCS=CAI', client)
        self.assertIn('CONSENT=YES', client)
        self.assertEqual(client.count('mobileUserAgent'), 2, 'defined once and used by the shared request builder')

    def test_failure_reasons_are_actionable(self):
        client = read('App/YouTubeWebClient.swift')
        self.assertIn('case needsBrowser', client)
        self.assertIn('case loginRequired', client)
        self.assertIn('Yüklenenleri oku', client)
        self.assertIn('YouTubeDiagnosticsLog.record', client)
        self.assertIn('Teşhis:', client)

    def test_watch_page_uses_the_same_request_shaping(self):
        media = read('App/YouTubeMedia.swift')
        self.assertIn('YouTubeWebClient.pageRequest(url: watchURL)', media)
        self.assertIn('YouTubePageSignal.detect(html)', media)


class BulkResponsivenessChecks(unittest.TestCase):
    def test_bulk_enqueue_publishes_once(self):
        flow = read('App/ImportFlow.swift')
        self.assertIn('jobs.append(contentsOf: added)', flow)
        self.assertNotIn('jobs.append(ResolveJob(', flow)
        self.assertIn('added.reserveCapacity(videos.count)', flow)

    def test_download_list_is_bounded_while_transfers_run(self):
        downloads = read('App/Downloads.swift')
        self.assertIn('rowLimit', downloads)
        self.assertIn('visibleTransfers', downloads)
        self.assertIn('visibleResolveJobs', downloads)
        self.assertIn('showFinishedTransfers', downloads)

    def test_progress_updates_stay_throttled(self):
        downloads = read('App/Downloads.swift')
        self.assertIn('progressUpdates', downloads)
        self.assertIn('tick.timeIntervalSince(last) < 0.5', downloads)


if __name__ == '__main__':
    unittest.main(verbosity=2)


class R15RevisionChecks(unittest.TestCase):
    def test_resume_is_opt_in(self):
        app = read('App/KontYTApp.swift')
        self.assertIn('forKey: "resumePlayback"', app)
        self.assertIn('guard resumeEnabled else', app)
        self.assertIn('storedPosition(item)', app)
        settings = read('App/StudioViews.swift')
        self.assertIn('Kaldığı yerden devam et', settings)
        self.assertIn('Kayıtlı konumları temizle', settings)

    def test_apple_music_guide_is_gone(self):
        settings = read('App/StudioViews.swift')
        self.assertNotIn('Apple Müzik’e aktarım', settings)
        self.assertNotIn('bilgisayarına aktar', settings)

    def test_wifi_receiver_survives_settings_navigation(self):
        wifi = read('App/WiFiUpload.swift')
        self.assertIn('static let shared', wifi)
        self.assertIn('func setForeground', wifi)
        self.assertIn('private init()', wifi)
        self.assertNotIn('.onDisappear { server.stop() }', wifi)
        root = read('App/StudioViews.swift')
        self.assertIn('WiFiUploadServer.shared.setForeground(true)', root)
        self.assertIn('WiFiUploadServer.shared.setForeground(false)', root)

    def test_browser_auto_detects_playlist_entries(self):
        browser = read('App/YouTubeBrowser.swift')
        self.assertIn('func autoCollect()', browser)
        self.assertIn('Timer.scheduledTimer(withTimeInterval: 2.5', browser)
        self.assertIn('func followPlaylistPage()', browser)
        self.assertIn('private(set) var playlistID', browser)
        self.assertNotIn('Button("Yüklenenleri oku")', browser)

    def test_playlist_failure_hands_over_to_browser(self):
        studio = read('App/StudioViews.swift')
        self.assertIn('autoBrowserFallback', studio)
        self.assertIn('autoBrowserTried.insert', studio)
        self.assertIn('browserRequest = BrowserRequest(url: url)', studio)

    def test_effects_are_smoothed_for_quality(self):
        engine = read('App/LiveAudioGain.swift')
        self.assertIn('beginBlock(values:', engine)
        self.assertIn('smoothedPitchMix', engine)
        self.assertIn('Catmull-Rom', engine)
        # R19 reworked the reverb: eight combs + four allpasses, a pre-delay, a low cut and a
        # constant-loudness dry/wet law so a wet mix can no longer clip.
        self.assertIn('1_116, 1_188, 1_277, 1_356, 1_422, 1_491, 1_557, 1_617', engine)
        self.assertIn('[556, 441, 341, 225]', engine)
        self.assertIn('let delay = Int(0.018 * sampleRate)', engine)
        self.assertIn('lowCutCoefficient', engine)
        self.assertIn('value * (1 - reverb * 0.5) + wet * reverb', engine)
        self.assertIn('LiveGainMath.softLimit', engine)
        self.assertNotIn('wetStore', engine)
        self.assertIn('func clear()', engine)

    def test_multiple_playlists_and_multi_select(self):
        collections = read('App/Collections.swift')
        for symbol in ['func add(_ items: [UUID], to playlist: UUID)', 'func createPlaylist(named', 'func toggleFavorite', 'struct AddToPlaylistSheet']:
            self.assertIn(symbol, collections)
        archive = read('App/KontYTApp.swift')
        for symbol in ['selectMode', 'activeSheet = .addToList', 'library.removeMany', 'func playNext', 'func addToQueue']:
            self.assertIn(symbol, archive)
