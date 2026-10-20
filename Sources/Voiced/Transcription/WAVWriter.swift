import Foundation

/// Streams 16-bit PCM samples into a WAV file.
///
/// The RIFF and data sizes in the header are patched after every append, so the file is complete and
/// playable at all times, even if the process dies in the middle of a session.
final class WAVWriter {
    static let bitsPerSample = 16
    private static let headerSize: UInt32 = 44

    let url: URL
    private let handle: FileHandle
    private(set) var dataBytes: UInt32 = 0

    init(url: URL, sampleRate: Int, channels: Int = 1) throws {
        self.url = url
        try Data().write(to: url)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, channels: channels, dataBytes: 0))
    }

    /// Reopens a file this writer produced earlier, so later samples continue after the existing audio.
    /// Fails when the file is not a 16-bit PCM WAV with the given sample rate and channel count. The
    /// data size is taken from the file length rather than the header, so a file left behind by a
    /// crash before the header was patched is still picked up in full.
    init(appendingTo url: URL, sampleRate: Int, channels: Int = 1) throws {
        self.url = url
        handle = try FileHandle(forUpdating: url)
        let header = try handle.read(upToCount: Int(Self.headerSize)) ?? Data()
        let expected = Self.header(sampleRate: sampleRate, channels: channels, dataBytes: 0)
        // Everything but the two size fields must match what this writer would have written.
        guard header.count == expected.count,
              header[0..<4] == expected[0..<4], header[8..<40] == expected[8..<40]
        else {
            try? handle.close()
            throw FormatMismatch()
        }
        let length = try handle.seekToEnd()
        dataBytes = UInt32(clamping: length - UInt64(Self.headerSize))
        try patchSizes()
    }

    struct FormatMismatch: Error {}

    /// Appends samples in the -1...1 range, clipping anything outside it.
    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        let pcm = samples.map { Int16((max(-1, min(1, $0)) * Float(Int16.max)).rounded()).littleEndian }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        dataBytes += UInt32(data.count)
        try patchSizes()
    }

    private func patchSizes() throws {
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.littleEndian(Self.headerSize - 8 + dataBytes))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Self.littleEndian(dataBytes))
    }

    func close() {
        try? handle.synchronize()
        try? handle.close()
    }

    private static func header(sampleRate: Int, channels: Int, dataBytes: UInt32) -> Data {
        let blockAlign = UInt16(channels * bitsPerSample / 8)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian(headerSize - 8 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian(UInt32(16)))
        data.append(littleEndian(UInt16(1))) // PCM
        data.append(littleEndian(UInt16(channels)))
        data.append(littleEndian(UInt32(sampleRate)))
        data.append(littleEndian(UInt32(sampleRate) * UInt32(blockAlign)))
        data.append(littleEndian(blockAlign))
        data.append(littleEndian(UInt16(bitsPerSample)))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian(dataBytes))
        return data
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
