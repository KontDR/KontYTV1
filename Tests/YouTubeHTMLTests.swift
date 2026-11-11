import XCTest
@testable import KontYT

final class YouTubeHTMLTests: XCTestCase {
    func testBalancedJSONWithBracesInString() {
        let html = #"<script>var ytInitialData = {"label":"brace } inside string","nested":{"ok":true}};</script>"#
        let value = YouTubeHTML.object(in: html, variable: "ytInitialData")
        XCTAssertEqual(value?["label"] as? String, "brace } inside string")
        XCTAssertNotNil(value?["nested"])
    }
    func testWindowAssignment() {
        let html = #"window["ytInitialData"]={"value":12};"#
        XCTAssertEqual(YouTubeHTML.object(in: html, variable: "ytInitialData")?["value"] as? Int, 12)
    }
    func testRendererDedupAndContinuation() throws {
        let fixture = #"{"contents":[{"videoRenderer":{"videoId":"dQw4w9WgXcQ","title":{"runs":[{"text":"Example"}]},"ownerText":{"simpleText":"Channel"}}},{"videoRenderer":{"videoId":"dQw4w9WgXcQ","title":{"simpleText":"Duplicate"}}},{"continuationItemRenderer":{}}]}"#
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        let batch = YouTubeHTML.videos(in: root)
        XCTAssertEqual(batch.videos.count, 1)
        XCTAssertEqual(batch.videos.first?.title, "Example")
        XCTAssertTrue(batch.hasMore)
    }
    func testPlaylistDoesNotIncludeRecommendations() throws {
        let fixture = #"{"contents":[{"videoRenderer":{"videoId":"dQw4w9WgXcQ"}},{"playlistVideoRenderer":{"videoId":"abcdefghijk","title":{"simpleText":"Playlist entry"}}}]}"#
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        XCTAssertEqual(YouTubeHTML.videos(in: root, playlistOnly: true).videos.map(\.id), ["abcdefghijk"])
    }
    func testMissingDataReturnsNil() {
        XCTAssertNil(YouTubeHTML.object(in: "<html>consent</html>", variable: "ytInitialData"))
    }
}
