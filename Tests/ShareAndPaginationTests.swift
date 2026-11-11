import XCTest
@testable import KontYT

final class ShareAndPaginationTests: XCTestCase {
    func testSharedTextContainsYouTubeLink() {
        XCTAssertEqual(SharedInbox.extract("Bak: https://youtu.be/dQw4w9WgXcQ?t=2")?.host, "youtu.be")
    }
    func testShareHostValidation() {
        XCTAssertFalse(SharedInbox.accepted(URL(string: "https://youtube.com.evil.test/watch?v=abcdefghijk")!))
        XCTAssertFalse(SharedInbox.accepted(URL(string: "file:///youtube.com")!))
        XCTAssertFalse(SharedInbox.accepted(URL(string: "https://user:secret@youtube.com/watch?v=abcdefghijk")!))
        XCTAssertTrue(SharedInbox.accepted(URL(string: "https://www.youtube.com/playlist?list=PLtest")!))
    }
    func testContinuationExtraction() throws {
        let json = #"{"contents":[{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"next-page-token"}}}}]}"#
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertEqual(YouTubeHTML.continuationToken(in: root), "next-page-token")
    }
    func testYTConfigurationExtraction() {
        let html = #"<script>ytcfg.set({"INNERTUBE_CONTEXT":{"client":{"clientName":"WEB"}}});</script>"#
        let config = YouTubeHTML.assignedObject(in: html, markers: ["ytcfg.set("])
        XCTAssertNotNil(config?["INNERTUBE_CONTEXT"])
    }
    func testConfigurationSkipsEarlyNonObjectCalls() {
        let html = #"ytcfg.set('EMERGENCY_BASE_URL', '/error'); ytcfg.set({"flag":true}); ytcfg.set({"INNERTUBE_CONTEXT":{"client":{}}});"#
        let config = YouTubeHTML.assignedObject(in: html, markers: ["ytcfg.set("], requiredKey: "INNERTUBE_CONTEXT")
        XCTAssertNotNil(config?["INNERTUBE_CONTEXT"])
    }
    func testOldDownloadJobMigration() throws {
        let id = UUID()
        let raw = "{\"id\":\"\(id.uuidString)\",\"url\":\"https://example.org/file.mp4\",\"name\":\"Test\",\"status\":\"Hata\",\"received\":0,\"expected\":0}"
        let job = try JSONDecoder().decode(DownloadJob.self, from: Data(raw.utf8))
        XCTAssertNil(job.companionAudioURL)
        XCTAssertNil(job.sourceVideoID)
        XCTAssertEqual(job.id, id)
    }
}
