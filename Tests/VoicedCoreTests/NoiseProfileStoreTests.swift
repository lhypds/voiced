import XCTest
@testable import VoicedCore

final class NoiseProfileStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicedTests.NoiseProfile.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testProfileRoundTripsThroughTheFile() throws {
        let url = directory.appendingPathComponent("noise-profile.json")
        let profile = try XCTUnwrap(NoiseProfile(noise: (0..<4096).map { Float($0 % 7) / 100 }))

        try profile.save(to: url)
        XCTAssertEqual(NoiseProfile.load(from: url), profile)
    }

    func testMissingOrInvalidFileGivesNoProfile() throws {
        let url = directory.appendingPathComponent("noise-profile.json")
        XCTAssertNil(NoiseProfile.load(from: url))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"magnitudes\": [1, 2]}".utf8).write(to: url)
        XCTAssertNil(NoiseProfile.load(from: url))
    }
}
