import SwiftUI
import AVKit

struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    /// Picture-in-picture is opt-in (Ayarlar › Resim içinde resim). Off means AVKit never builds a PiP
    /// controller at all, which is the state the app ships in; on means the player shows its own PiP
    /// button and floating video starts when the app goes to the background.
    var allowsPiP: Bool = false
    /// Called when the picture goes away (PiP closed or the view torn down) so the audio can
    /// keep running. Playback must never stop just because the video window was dismissed.
    var onStopped: () -> Void = {}

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let onStopped: () -> Void
        /// AVKit owns the picture-in-picture controller on iOS 16+, so the app only tracks whether it
        /// was live; there is no public "stop" call on AVPlayerViewController itself.
        var pipActive = false
        init(onStopped: @escaping () -> Void) { self.onStopped = onStopped }

        func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            pipActive = true
            CrashLog.note("PiP basladi")
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            CrashLog.note("PiP kapatiliyor, oynatici geri geliyor")
            NotificationCenter.default.post(name: .kontytShowPlayer, object: nil)
            completionHandler(true)
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            pipActive = false
            CrashLog.note("PiP bitti")
            DispatchQueue.main.async { self.onStopped() }
        }

        func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) {
            onStopped()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onStopped: onStopped) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
        controller.player = player
        apply(pictureInPicture: allowsPiP, to: controller)
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        // Flipping the setting while the player is open takes effect immediately.
        apply(pictureInPicture: allowsPiP, to: controller)
    }

    private func apply(pictureInPicture: Bool, to controller: AVPlayerViewController) {
        controller.allowsPictureInPicturePlayback = pictureInPicture
        controller.canStartPictureInPictureAutomaticallyFromInline = pictureInPicture
    }

    /// Detaching the player here means a torn-down video view cannot pause playback:
    /// closing the picture keeps the sound running.
    /// Order matters: unhook picture-in-picture *before* the player goes away. Clearing `player`
    /// while PiP is live is what AVKit aborts on, and this teardown runs whenever the player sheet is
    /// dismissed - which is exactly when tabs change during playback.
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        // Every step is breadcrumbed: if the process ever dies in here, the log names the line.
        CrashLog.note("Oynatici sokuluyor")
        // AVPlayerViewController has no isPictureInPictureActive on iOS 16: our delegate is the source.
        let pipWasLive = coordinator.pipActive
        controller.allowsPictureInPicturePlayback = false
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.delegate = nil
        CrashLog.note("Temsilci birakildi")
        // Clearing `player` while a floating window is still live is what AVKit aborts on. When PiP is
        // up we leave the player attached and let the controller go away with it; our own Library owns
        // playback, so the sound and the floating picture both survive.
        if !pipWasLive { controller.player = nil }
        coordinator.pipActive = false
        CrashLog.note(pipWasLive ? "Oynatici kapandi (PiP acikti, oynatici korundu)" : "Oynatici kapandi")
        // The audio kick must not run inside the teardown: touching the session and the player while
        // AVKit is still unwinding is what used to end the process. Next runloop is soon enough.
        DispatchQueue.main.async { coordinator.onStopped() }
    }
}
