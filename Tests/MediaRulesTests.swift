import XCTest
@testable import KontYT

final class MediaRulesTests: XCTestCase {
    func testSupportedYouTubeLinks() {
        let id = "dQw4w9WgXcQ"
        for link in ["https://youtu.be/\(id)", "https://www.youtube.com/watch?v=\(id)&t=12", "https://youtube.com/shorts/\(id)", "https://m.youtube.com/live/\(id)", "https://youtube.com/embed/\(id)"] {
            XCTAssertEqual(MediaRules.youTubeID(link), id, link)
        }
    }
    func testInvalidYouTubeLinks() {
        for link in ["https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ", "https://evilyoutube.com/watch?v=dQw4w9WgXcQ", "file:///watch?v=dQw4w9WgXcQ", "https://youtube.com/watch?v=short", "not a url"] {
            XCTAssertNil(MediaRules.youTubeID(link), link)
        }
    }
    func testSeekBounds() {
        XCTAssertEqual(MediaRules.boundedSeek(-10, duration: 100), 0)
        XCTAssertEqual(MediaRules.boundedSeek(120, duration: 100), 100)
        XCTAssertEqual(MediaRules.boundedSeek(25, duration: 100), 25)
        XCTAssertNil(MediaRules.boundedSeek(.nan, duration: 100))
        XCTAssertNil(MediaRules.boundedSeek(.infinity, duration: 100))
    }
    func testCollectionRoundTrip() throws {
        var state = CollectionState()
        let id = UUID()
        state.favorites.insert(id)
        state.playlists = [MediaPlaylist(name: "Test", itemIDs: [id])]
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(CollectionState.self, from: data)
        XCTAssertEqual(restored.favorites, state.favorites)
        XCTAssertEqual(restored.playlists.first?.itemIDs, [id])
    }
    func testBackupRoundTrip() throws {
        let backup = CollectionBackup(collections: CollectionState(), bookmarks: [PlaybackBookmark(itemID: UUID(), seconds: 12, title: "Test")])
        let result = try JSONDecoder().decode(CollectionBackup.self, from: JSONEncoder().encode(backup))
        XCTAssertEqual(result.schemaVersion, 1)
        XCTAssertEqual(result.bookmarks.first?.seconds, 12)
    }
}
