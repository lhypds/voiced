import VoicedCore

extension InputCapture: AudioCapturing {}

extension MicrophoneAudioSource {
    convenience init(profile: NoiseProfile?, mute: InputMute? = nil) {
        self.init(capture: InputCapture(), profile: profile, mute: mute)
    }
}
