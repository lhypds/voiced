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

    /// Appends samples in the -1...1 range, clipping anything outside it.
    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        let pcm = samples.map { Int16((max(-1, min(1, $0)) * Float(Int16.max)).rounded()).littleEndian }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        dataBytes += UInt32(data.count)
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
