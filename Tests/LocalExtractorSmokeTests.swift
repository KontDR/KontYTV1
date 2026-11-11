import XCTest
@testable import KontYT

final class LocalExtractorSmokeTests: XCTestCase {
    func testOptInPublicVideoExtraction() async throws {
        guard let id = ProcessInfo.processInfo.environment["KONTYT_SMOKE_VIDEO_ID"], !id.isEmpty else {
            throw XCTSkip("Canlı test için indirme hakkın olan video kimliğini ve açık izni workflow'da belirt. Varsayılan testler ağa çıkmaz.")
        }
        XCTAssertNotNil(MediaRules.youTubeID("https://youtu.be/\(id)"))
        let result = try await YouTubeWebClient.shared.mediaOptions(for: id)
        XCTAssertFalse(result.formats.isEmpty)
        // Extraction only: no media payload is downloaded by this test.
    }
}
