import Foundation

/// Saves the raw audio of a recording session as `<unix time>.wav` inside the record's directory,
/// either in a new file or appended to the record's existing one.
///
/// The file holds exactly what the recognizer heard, as 16 kHz mono 16-bit PCM, so a session can be
/// replayed with `VoicedSimulate`. Saving never gets in the way of recognition: a write that fails is
/// dropped and the session goes on.
final class SessionRecorder: @unchecked Sendable {
    static let sampleRate = 16_000

    let fileURL: URL
    /// Seconds of audio the file held before this session; where this session starts in it.
    let startOffset: TimeInterval
    private let lock = NSLock()
    private var writer: WAVWriter?
    private var sampleCount = 0
    /// A file created for this session is removed again when it captured nothing; a file continued
    /// from an earlier session is kept either way.
    private let createdFile: Bool

    /// Creates the directory if needed and opens the audio file, named after the start time in whole
    /// seconds since 1970. Returns nil when that fails; the audio is then simply not saved.
    init?(directory: URL, startedAt: Date) {
        let fileURL = Self.unusedFile(startedAt: startedAt, in: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            writer = try WAVWriter(url: fileURL, sampleRate: Self.sampleRate)
        } catch {
            return nil
        }
        self.fileURL = fileURL
        startOffset = 0
        createdFile = true
    }

    /// Continues the record's existing audio file, so the new session follows the earlier audio in
    /// the same file. Returns nil when the file is missing or not one this recorder wrote.
    init?(appendingTo fileName: String, in directory: URL) {
        let fileURL = directory.appendingPathComponent(fileName)
        let writer: WAVWriter
        do {
            writer = try WAVWriter(appendingTo: fileURL, sampleRate: Self.sampleRate)
        } catch {
            return nil
        }
        self.writer = writer
        self.fileURL = fileURL
        startOffset = TimeInterval(writer.dataBytes) / TimeInterval(WAVWriter.bitsPerSample / 8) / TimeInterval(Self.sampleRate)
        createdFile = false
    }

    var fileName: String { fileURL.lastPathComponent }

    /// Samples written so far.
    var writtenSampleCount: Int {
        lock.withLock { sampleCount }
    }

    /// Appends audio to the file. Safe to call from any thread.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.withLock {
            guard let writer else { return }
            do {
                try writer.append(samples)
                sampleCount += samples.count
            } catch {
                writer.close()
                self.writer = nil
            }
        }
    }

    /// Closes the file. Returns false when this session captured no audio; a file created for the
    /// session is then removed, a continued file is left as it was.
    @discardableResult
    func finish() -> Bool {
        lock.withLock {
            writer?.close()
            writer = nil
            guard sampleCount > 0 else {
                if createdFile {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                return false
            }
            return true
        }
    }

    /// Two sessions started within the same second get `<time>.wav` and `<time>-2.wav`.
    private static func unusedFile(startedAt: Date, in directory: URL) -> URL {
        let name = TranscriptRecord.directoryName(for: startedAt)
        var candidate = directory.appendingPathComponent(name).appendingPathExtension("wav")
        var attempt = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            attempt += 1
            candidate = directory.appendingPathComponent("\(name)-\(attempt)").appendingPathExtension("wav")
        }
        return candidate
    }
}
