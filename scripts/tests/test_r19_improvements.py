from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def read(name: str) -> str:
    return (ROOT / name).read_text()


class SelectionBarPlacement(unittest.TestCase):
    def test_selection_bar_is_not_under_the_mini_player(self):
        """The bottom bar was covered by the now-playing mini player, so taps never landed.

        It now lives above the list, inside the tab content, which the mini player cannot cover.
        """
        view = read('App/KontYTApp.swift')
        self.assertNotIn('.safeAreaInset(edge: .bottom) { selectionBar }', view)
        self.assertIn('if selectMode { selectionBar }', view)
        bar = view.split('struct LibrarySelectionBar: View {', 1)[1].split('struct LibraryView: View {', 1)[0]
        for symbol in ['onAddToList', 'onFavorite', 'onQueue', 'onToggleAll', 'onDelete', '"Bitir"']:
            self.assertIn(symbol, bar)
        # the strip must sit above the archive list, not below it
        body = view.split('struct LibraryView: View {', 1)[1]
        self.assertLess(body.index('if selectMode { selectionBar }'), body.index('archiveList'))


class Thumbnails(unittest.TestCase):
    def test_archive_thumbnails_are_local_and_youtube_rows_are_remote(self):
        store = read('App/Thumbnails.swift')
        self.assertIn('enum ThumbnailStore', store)
        self.assertIn('AVAssetImageGenerator', store)
        self.assertIn('Documents', store.replace('documentDirectory', 'Documents'))
        self.assertIn('static func clear()', store)
        self.assertNotIn('URLSession', store, 'archive thumbnails must not need the network')
        self.assertIn('i.ytimg.com', store)
        row = read('App/KontYTApp.swift')
        self.assertIn('MediaThumbnail(item: item)', row)
        discovery = read('App/StudioViews.swift')
        self.assertIn('RemoteThumbnail(videoID: video.id)', discovery)


class FadesAndVideoDetach(unittest.TestCase):
    def test_transition_fade_is_wired_and_off_switch_exists(self):
        library = read('App/KontYTApp.swift')
        for symbol in ['var transitionFade: Double', 'func updateFade(', 'func startFadeIn()',
                       'player.volume = Float(max(0.02, remaining / fade))', 'startFadeIn()']:
            self.assertIn(symbol, library)
        settings = read('App/StudioViews.swift')
        self.assertIn('@AppStorage("transitionFade")', settings)
        self.assertIn('TransitionPicker(fade: $transitionFade)', settings)

    def test_closing_the_video_keeps_the_audio(self):
        library = read('App/KontYTApp.swift')
        self.assertIn('@Published var videoDetached', library)
        self.assertIn('func detachVideoSurface()', library)
        self.assertIn('func ensureAudioContinues()', library)
        # A deliberate pause must be respected by the picture-in-picture teardown.
        self.assertIn('private var userPaused = false', library)
        body = library.split('func ensureAudioContinues()', 1)[1][:900]
        self.assertIn('guard current != nil, !userPaused else { return }', body)
        # The kick is throttled and skipped when the player is already running: three of these in one
        # second were the last thing the log showed before the process disappeared.
        self.assertIn('guard now.timeIntervalSince(lastAudioKick) > 0.5 else { return }', body)
        self.assertIn('let wasPlaying = playing && player.rate != 0', body)
        self.assertIn('player.playImmediately(atRate: rate)', body)
        player = read('App/NowPlayingView.swift')
        self.assertIn('&& !library.videoDetached', player)
        self.assertIn('library.detachVideoSurface()', player)
        surface = read('App/PlayerSurface.swift')
        self.assertIn('static func dismantleUIViewController', surface)
        self.assertIn('playerViewControllerDidStopPictureInPicture', surface)
        self.assertIn('PlayerSurface(player: library.player, allowsPiP: pipEnabled,', player)
        self.assertIn('onStopped: { library.ensureAudioContinues() }', player)
        root = read('App/StudioViews.swift')
        self.assertIn('library.ensureAudioContinues()', root, 'foregrounding must resume a track that PiP paused')


class ReverbLevelLaw(unittest.TestCase):
    def test_wet_mix_cannot_clip(self):
        engine = read('App/LiveAudioGain.swift')
        # dry 1 - 0.5*mix plus wet 0.5*mix keeps peak level bounded, and a soft limiter backs it up.
        self.assertIn('(1 - reverb * 0.5) + wet * reverb', engine)
        self.assertIn('LiveGainMath.softLimit', engine)
        self.assertIn('0.9 + 0.1 * tanhf', engine)
        self.assertIn('sum *= 0.125', engine)
        self.assertIn('combs = [1_116, 1_188, 1_277, 1_356, 1_422, 1_491, 1_557, 1_617]', engine)


class RemoteControls(unittest.TestCase):
    """Control Centre buttons stopped responding: the command set was minimal and could be
    dropped after an interruption. Every command is now installed explicitly and re-armed."""

    def test_every_remote_command_is_installed_and_rearmable(self):
        library = read('App/KontYTApp.swift')
        self.assertIn('func installRemoteCommands()', library)
        for command in ['playCommand', 'pauseCommand', 'togglePlayPauseCommand', 'nextTrackCommand',
                        'previousTrackCommand', 'stopCommand', 'changePlaybackPositionCommand']:
            self.assertIn(command, library, command + ' missing from the remote command set')
            self.assertIn(command + '.isEnabled = true', library, command + ' is never enabled')
        # The +/- 15 s buttons are gone on purpose: the lock screen shows previous/next instead.
        self.assertNotIn('skipForwardCommand.isEnabled = true', library)
        self.assertNotIn('skipBackwardCommand.isEnabled = true', library)
        self.assertIn('skipForwardCommand.preferredIntervals = []', library)
        self.assertNotIn('preferredIntervals = [15]', library)
        self.assertIn('removeTarget(nil)', library)
        # Re-armed when the app comes back to the foreground.
        self.assertIn('library.installRemoteCommands()', read('App/StudioViews.swift'))

    def test_now_playing_payload_keeps_the_buttons_alive(self):
        library = read('App/KontYTApp.swift')
        for key in ['MPNowPlayingInfoPropertyMediaType', 'MPNowPlayingInfoPropertyPlaybackQueueCount',
                    'MPNowPlayingInfoPropertyPlaybackQueueIndex', 'MPNowPlayingInfoPropertyDefaultPlaybackRate',
                    'MPNowPlayingInfoPropertyElapsedPlaybackTime', 'MPMediaItemPropertyPlaybackDuration']:
            self.assertIn(key, library, key + ' missing from the now playing info')


class AudioVideoPlaybackChoice(unittest.TestCase):
    def test_video_can_be_set_to_sound_only_for_every_track(self):
        library = read('App/KontYTApp.swift')
        self.assertIn('var audioOnlyVideos: Bool', library)
        self.assertIn('videoDetached = item.isVideo && audioOnlyVideos', library)
        settings = read('App/StudioViews.swift')
        self.assertIn('@AppStorage("audioOnlyVideos") private var audioOnlyVideos = false', settings)
        self.assertIn('Toggle("Video dosyalarını yalnızca ses olarak oynat"', settings)
        player = read('App/NowPlayingView.swift')
        self.assertIn('Videoyu göster', player)
