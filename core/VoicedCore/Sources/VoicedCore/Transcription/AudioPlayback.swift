import AVFoundation

/// Plays a record's audio file through the system output from a chosen moment, until it is
/// stopped or the file ends.
@MainActor
public final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    /// Called once playback has reached the end of the file on its own; not when stopped.
    public var onFinish: (() -> Void)?
    private var player: AVAudioPlayer?
    /// Stops the player at the end time given to `play`, if any.
    private var endWatch: Task<Void, Never>?

    public var isPlaying: Bool { player?.isPlaying ?? false }
    /// The file being played, or nil while nothing plays.
    public var fileURL: URL? { player?.url }
    /// Seconds into the file, or nil while nothing plays.
    public var currentTime: TimeInterval? { player?.currentTime }

    /// Starts playing `url` at `time` seconds, in place of whatever was playing, until `end`
    /// seconds or the end of the file, then reports a finish. A time past the end plays nothing
    /// and reports a finish at once.
    public func play(_ url: URL, from time: TimeInterval, until end: TimeInterval? = nil) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.currentTime = max(0, time)
        guard time < player.duration, player.play() else {
            throw PlaybackFailed()
        }
        self.player = player
        if let end, end < player.duration {
            endWatch = Task { [weak self, weak player] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, let self, let player, self.player === player else { return }
                    if player.currentTime >= end {
                        player.stop()
                        self.playbackEnded()
                        return
                    }
                }
            }
        }
    }

    public func stop() {
        endWatch?.cancel()
        endWatch = nil
        player?.stop()
        player = nil
    }

    public struct PlaybackFailed: LocalizedError {
        public var errorDescription: String? { "The audio could not be played." }
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playbackEnded() }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.playbackEnded() }
    }

    /// Lets go of the player once it has stopped on its own; a stop from `stop()` has already
    /// dropped it, and a newer player started since is left alone.
    private func playbackEnded() {
        guard let player, !player.isPlaying else { return }
        endWatch?.cancel()
        endWatch = nil
        self.player = nil
        onFinish?()
    }
}
