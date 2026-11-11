"""Playback is where the app used to close on its own. These checks keep the three known instant-kill
paths shut: clearing an AVPlayerViewController while PiP is live, a non-finite number handed to
MediaPlayer, and a zero-sized artwork image."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def read(name):
    return (ROOT / name).read_text(encoding='utf-8')


class PlaybackGuardrails(unittest.TestCase):
    def test_picture_in_picture_is_unhooked_before_the_player_is_cleared(self):
        surface = read('App/PlayerSurface.swift')
        body = surface.split('static func dismantleUIViewController', 1)[1]
        # AVPlayerViewController has no isPictureInPictureActive / stopPictureInPicture on iOS 16
        # (CI: "value of type 'AVPlayerViewController' has no member ..."), so the teardown withdraws
        # the flags and the delegate first and only then drops the player.
        self.assertNotIn('controller.isPictureInPictureActive', surface)
        self.assertNotIn('controller.stopPictureInPicture()', surface)
        self.assertLess(body.index('allowsPictureInPicturePlayback = false'), body.index('controller.player = nil'))
        self.assertLess(body.index('controller.delegate = nil'), body.index('controller.player = nil'))
        self.assertIn('coordinator.pipActive', surface)
        self.assertIn('playerViewControllerDidStartPictureInPicture', surface)

    def test_media_player_only_receives_finite_numbers(self):
        library = read('App/KontYTApp.swift')
        self.assertIn('private func safeNumber(_ value: Double) -> NSNumber', library)
        info = library.split('func updateNowPlaying()', 1)[1].split('func remove(', 1)[0]
        self.assertIn('safeNumber(', info)
        self.assertNotIn('MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed', info)
        self.assertNotIn('MPMediaItemPropertyPlaybackDuration: duration', info)
        self.assertIn('image.size.width >= 1', info, 'a zero-sized artwork image is not accepted')

    def test_track_duration_is_sanitised_before_it_reaches_the_bridge(self):
        library = read('App/KontYTApp.swift')
        self.assertIn('duration = (item.duration?.isFinite == true) ? max(0, item.duration ?? 0) : 0', library)

    def test_playback_and_tab_changes_leave_breadcrumbs(self):
        library = read('App/KontYTApp.swift')
        for note in ['Calma basladi', 'Devam', 'Duraklatildi', 'Ses devam ettiriliyor']:
            self.assertIn('CrashLog.note("' + note, library)
        root = read('App/StudioViews.swift')
        self.assertIn('CrashLog.note("Sekme "', root)
        self.assertIn('.onChange(of: tab)', root)


if __name__ == '__main__':
    unittest.main()
