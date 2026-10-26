import VoicedCore

extension InputLevelMonitor {
    nonisolated convenience init() { self.init(makeCapture: { InputCapture() }) }
}
