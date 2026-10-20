import Foundation

/// Saves the measured noise profile as JSON so noise reduction survives a relaunch.
extension NoiseProfile {
    private struct Stored: Codable {
        var magnitudes: [Double]
    }

    /// The profile saved at `url`, or nil when there is none or it does not match the current bin count.
    static func load(from url: URL) -> NoiseProfile? {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return NoiseProfile(stored: stored.magnitudes)
    }

    func save(to url: URL) throws {
        let data = try JSONEncoder().encode(Stored(magnitudes: stored))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
