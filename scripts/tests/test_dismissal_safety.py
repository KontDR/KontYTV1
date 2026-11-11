"""The reported crash: a music video plays, the player sheet is swiped down, the process disappears with
no signal line in the log - so the app itself did nothing it could catch. What the app *can* do is stop
the risky work on that path: no picture-in-picture controller to unwind, no audio/Now Playing work inside
the AVKit teardown, no reaction to the half-second `.inactive` phase a sheet animation produces."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def read(name):
    return (ROOT / name).read_text(encoding='utf-8')


class PlayerTeardown(unittest.TestCase):
    def test_picture_in_picture_is_opt_in_only(self):
        surface = read('App/PlayerSurface.swift')
        self.assertIn('var allowsPiP: Bool = false', surface, 'the setting must default to off')
        self.assertIn('apply(pictureInPicture: allowsPiP, to: controller)', surface)
        self.assertIn('controller.allowsPictureInPicturePlayback = pictureInPicture', surface)
        self.assertNotIn('allowsPictureInPicturePlayback = true', surface)
        self.assertNotIn('AutomaticallyFromInline = true', surface)
        self.assertIn('@AppStorage("pictureInPicture") private var pipEnabled = false', read('App/NowPlayingView.swift'))
        self.assertIn('@AppStorage("pictureInPicture") private var pictureInPicture = false', read('App/StudioViews.swift'))
        self.assertIn('Toggle("Resim içinde resim (PiP)", isOn: $pictureInPicture)', read('App/StudioViews.swift'))
        self.assertIn('Toggle(isOn: $pipEnabled)', read('App/NowPlayingView.swift'))

    def test_a_live_pip_keeps_the_player_attached(self):
        surface = read('App/PlayerSurface.swift')
        body = surface.split('static func dismantleUIViewController', 1)[1]
        self.assertIn('let pipWasLive = coordinator.pipActive', body)
        self.assertIn('if !pipWasLive { controller.player = nil }', body,
                      'clearing the player while the floating window is live is what AVKit aborts on')
        self.assertNotIn('controller.isPictureInPictureActive', surface)

    def test_teardown_is_breadcrumbed_at_every_step(self):
        surface = read('App/PlayerSurface.swift')
        body = surface.split('static func dismantleUIViewController', 1)[1]
        steps = ['Oynatici sokuluyor', 'Temsilci birakildi', 'Oynatici kapandi']
        positions = []
        for step in steps:
            self.assertIn(step, body, 'teardown must leave a breadcrumb: ' + step)
            positions.append(body.index(step))
        self.assertEqual(positions, sorted(positions), 'breadcrumbs must follow the teardown order')
        self.assertLess(body.index('controller.delegate = nil'), body.index('controller.player = nil'))
        self.assertLess(body.index('Temsilci birakildi'), body.index('controller.player = nil'))

    def test_audio_kick_runs_after_the_teardown(self):
        surface = read('App/PlayerSurface.swift')
        body = surface.split('static func dismantleUIViewController', 1)[1]
        self.assertIn('DispatchQueue.main.async { coordinator.onStopped() }', body)
        self.assertNotIn('\n        coordinator.onStopped()', body,
                         'the audio kick must not run inside the AVKit teardown')


class ExplicitSelf(unittest.TestCase):
    """A class property touched inside an escaping closure needs `self.` - CI caught exactly this in
    PlayerSurface (line 36: "requires explicit use of 'self'")."""

    def test_coordinator_closures_use_self(self):
        surface = read('App/PlayerSurface.swift')
        self.assertIn('DispatchQueue.main.async { self.onStopped() }', surface)
        self.assertNotIn('DispatchQueue.main.async { onStopped() }', surface)


class SessionKick(unittest.TestCase):
    def test_kick_is_throttled_and_skips_a_running_player(self):
        library = read('App/KontYTApp.swift')
        body = library.split('func ensureAudioContinues()', 1)[1].split('func releaseCachesQuietly', 1)[0]
        self.assertIn('lastAudioKick', body)
        self.assertIn('guard now.timeIntervalSince(lastAudioKick) > 0.5 else { return }', body)
        self.assertIn('player.rate != 0', body)
        activation = body.index('setActive(true)')
        self.assertGreater(activation, body.index('if !wasPlaying'), 'reactivation only when really needed')

    def test_caches_are_released_on_the_way_to_the_background(self):
        library = read('App/KontYTApp.swift')
        self.assertIn('func releaseCachesQuietly()', library)
        root = read('App/StudioViews.swift')
        self.assertIn('library.releaseCachesQuietly()', root)


class SheetPhase(unittest.TestCase):
    def test_the_inactive_phase_is_ignored(self):
        root = read('App/StudioViews.swift')
        body = root.split('private func handleScenePhase', 1)[1][:900]
        self.assertIn('guard value != .inactive else { CrashLog.note("Gecis"); return }', body)
        guard = body.index('guard value != .inactive')
        self.assertLess(guard, body.index('if value == .active'),
                        'the inactive guard must come before any foreground work')

    def test_the_picture_is_never_detached_automatically(self):
        # Detaching on dismissal looked like a crash fix and turned out to switch video off for good:
        # `videoDetached` stayed true until the next track started, so the picture never came back.
        player = read('App/NowPlayingView.swift')
        self.assertNotIn('onDisappear { library.detachVideoSurface() }', player)
        body = player.split('var body: some View', 1)[1].split('private var header', 1)[0]
        self.assertNotIn('detachVideoSurface', body, 'opening and closing the player must not drop the picture')
        # It survives as an explicit choice in the menu, right next to "Videoyu göster".
        self.assertIn('Label("Videoyu kapat, ses devam etsin"', player)
        self.assertIn('Button { audioOnly = false; library.detachVideoSurface() }', player)
        self.assertIn('@Published var videoDetached = false', read('App/KontYTApp.swift'))

    def test_fullscreen_picture_exists(self):
        player = read('App/NowPlayingView.swift')
        self.assertIn('.fullScreenCover(isPresented: $fullscreen)', player)
        self.assertIn('struct FullscreenPlayer', player)
        self.assertIn('allowsPiP: pipEnabled', player)
        self.assertIn('onStopped: { library.ensureAudioContinues() }', player)
        # Only one AVPlayerViewController may own the player at a time.
        visual = player.split('private var visual', 1)[1].split('private var titleBlock', 1)[0]
        self.assertIn('if fullscreen {', visual)
        self.assertLess(visual.index('if fullscreen {'), visual.index('PlayerSurface(player: library.player'))
        self.assertIn('arrow.up.left.and.arrow.down.right', player)


class VideoStaysOn(unittest.TestCase):
    """`videoDetached` may only be set on purpose: a new track (according to the setting), the menu
    button, or nothing else. Any other assignment means video disappears without the user asking."""

    def test_video_detach_has_exactly_three_writers(self):
        library = read('App/KontYTApp.swift')
        writers = [line.strip() for line in library.splitlines()
                   if 'videoDetached =' in line and '@Published' not in line]
        self.assertEqual(2, len(writers), writers + ['only resetVideoDetach and detachVideoSurface may write'])
        joined = ' '.join(writers)
        self.assertIn('item.isVideo && audioOnlyVideos', joined)
        self.assertIn('func detachVideoSurface()', library)
        player = read('App/NowPlayingView.swift')
        self.assertIn('library.videoDetached = false', player, 'the user must be able to bring the picture back')
        self.assertNotIn('library.videoDetached = true', player)

    def test_the_player_sheet_body_does_not_mutate_video_state(self):
        player = read('App/NowPlayingView.swift')
        body = player.split('var body: some View', 1)[1].split('private var header', 1)[0]
        self.assertNotIn('videoDetached', body)


class FullscreenTransport(unittest.TestCase):
    def test_previous_and_next_are_available_while_watching(self):
        player = read('App/NowPlayingView.swift')
        full = player.split('struct FullscreenPlayer', 1)[1]
        self.assertIn('library.previous()', full)
        self.assertIn('library.next()', full)
        self.assertIn('library.playing ? library.pause() : library.resume()', full)
        self.assertIn('accessibilityLabel("Sonraki")', full)
        self.assertIn('accessibilityLabel("Önceki")', full)
        # The inline player keeps its own transport too.
        inline = player.split('private var transport', 1)[1].split('private var quickActions', 1)[0]
        self.assertIn('library.next()', inline)
        self.assertIn('library.previous()', inline)


class RelaunchContext(unittest.TestCase):
    def test_the_log_names_the_line_the_previous_run_ended_with(self):
        crash = read('App/CrashLog.swift')
        self.assertIn('Onceki oturumun son satiri: ', crash)
        self.assertLess(crash.index('let previous = tail(1)'), crash.index('note("KontYT acildi")'))


class RemoteSkipRemoved(unittest.TestCase):
    def test_no_fifteen_second_skip_buttons(self):
        library = read('App/KontYTApp.swift')
        self.assertNotIn('skipForwardCommand.isEnabled = true', library)
        self.assertNotIn('MPSkipIntervalCommandEvent', library)
        self.assertNotIn('preferredIntervals = [15]', library)
        self.assertIn('nextTrackCommand.isEnabled = true', library)
        self.assertIn('previousTrackCommand.isEnabled = true', library)


if __name__ == '__main__':
    unittest.main()
