import AVFoundation

/// Plays a record's audio file through the system output from a chosen moment, until it is
/// stopped or the file ends.
@MainActor
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    /// Called once playback has reached the end of the file on its own; not when stopped.
    var onFinish: (() -> Void)?
    private var player: AVAudioPlayer?

    var isPlaying: Bool { player?.isPlaying ?? false }
    /// The file being played, or nil while nothing plays.
    var fileURL: URL? { player?.url }
    /// Seconds into the file, or nil while nothing plays.
    var currentTime: TimeInterval? { player?.currentTime }

    /// Starts playing `url` at `time` seconds, in place of whatever was playing. A time past
    /// the end plays nothing and reports a finish at once.
    func play(_ url: URL, from time: TimeInterval) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.currentTime = max(0, time)
        guard time < player.duration, player.play() else {
            throw PlaybackFailed()
        }
        self.player = player
    }

    func stop() {
        player?.stop()
        player = nil
    }

    struct PlaybackFailed: LocalizedError {
        var errorDescription: String? { "The audio could not be played." }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playbackEnded() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.playbackEnded() }
    }

    /// Lets go of the player once it has stopped on its own; a stop from `stop()` has already
    /// dropped it, and a newer player started since is left alone.
    private func playbackEnded() {
        guard let player, !player.isPlaying else { return }
        self.player = nil
        onFinish?()
    }
}
