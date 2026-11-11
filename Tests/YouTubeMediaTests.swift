import XCTest
@testable import KontYT

final class YouTubeMediaTests: XCTestCase {
    func testDirectMuxedFormat() throws {
        let root: [String: Any] = ["playabilityStatus": ["status": "OK"], "streamingData": ["formats": [["itag": 18, "url": "https://r1.googlevideo.com/videoplayback?x=1", "mimeType": "video/mp4; codecs=\"avc1, mp4a\"", "qualityLabel": "360p"]]]]
        let result = try YouTubeMediaParser.parse(root)
        XCTAssertEqual(result.formats.first?.ext, "mp4")
        XCTAssertEqual(result.formats.first?.audioOnly, false)
    }
    func testAdaptiveVideoGetsAudioCompanion() throws {
        let root: [String: Any] = ["streamingData": ["adaptiveFormats": [
            ["itag": 140, "url": "https://r1.googlevideo.com/a", "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"", "bitrate": 128000],
            ["itag": 137, "url": "https://r1.googlevideo.com/v", "mimeType": "video/mp4; codecs=\"avc1.640028\""]]]]
        let result = try YouTubeMediaParser.parse(root)
        XCTAssertEqual(result.formats.count, 2)
        XCTAssertEqual(result.formats.first(where: { $0.audioOnly })?.ext, "m4a")
        XCTAssertNotNil(result.formats.first(where: { !$0.audioOnly })?.companionAudioURL)
    }
    func testCipherDoesNotPretendToBeDownloadable() {
        let root: [String: Any] = ["streamingData": ["formats": [["itag": 18, "signatureCipher": "s=encrypted", "mimeType": "video/mp4; codecs=\"avc1.640028\""]]]]
        XCTAssertThrowsError(try YouTubeMediaParser.parse(root))
    }
    func testHostRestriction() {
        let root: [String: Any] = ["streamingData": ["formats": [["itag": 18, "url": "https://googlevideo.com.evil.example/file", "mimeType": "video/mp4; codecs=\"avc1.640028\""]]]]
        XCTAssertThrowsError(try YouTubeMediaParser.parse(root))
    }
    func testRestrictedPlayback() {
        XCTAssertThrowsError(try YouTubeMediaParser.parse(["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "Sign in"]]))
    }
    func testDirectParserKeepsSelectionMetadata() throws {
        let root: [String: Any] = ["streamingData": ["formats": [[
            "itag": 18, "url": "https://r1.googlevideo.com/v", "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"",
            "height": 360, "bitrate": 500000, "contentLength": "12345"
        ]]]]
        let result = try YouTubeMediaParser.parse(root)
        let format = try XCTUnwrap(result.formats.first)
        XCTAssertEqual(format.height, 360)
        XCTAssertEqual(format.bitrate, 500000)
        XCTAssertEqual(format.contentLength, 12345)
    }

}
