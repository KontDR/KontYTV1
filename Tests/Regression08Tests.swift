import XCTest
@testable import KontYT

final class Regression08Tests: XCTestCase {
    func testResignedAppGroupIsMatchedButUnrelatedGroupsAreNot() {
        let groups = AppGroupResolver.candidates(configured: "group.com.example.kontyt", altGroups: ["group.unrelated", "group.com.example.kontyt.ABC123", "group.com.example.kontyt.ABC123"], profileGroups: ["group.com.example.kontyt.XYZ789"])
        XCTAssertEqual(groups, ["group.com.example.kontyt", "group.com.example.kontyt.ABC123", "group.com.example.kontyt.XYZ789"])
    }
    func testEmptyAppGroupSuffixRejected() {
        XCTAssertEqual(AppGroupResolver.candidates(configured: "group.test", altGroups: ["group.test.", "group.testing.ABC"], profileGroups: []), ["group.test"])
    }
    func testContentRangeValidation() {
        XCTAssertEqual(HTTPContentRange("bytes 0-7/16")?.total, 16)
        XCTAssertEqual(HTTPContentRange("bytes 8-15/16")?.start, 8)
        XCTAssertNil(HTTPContentRange("bytes 0-16/16"))
        XCTAssertNil(HTTPContentRange("bytes 10-1/16"))
        XCTAssertNil(HTTPContentRange("bytes 0-10/*"))
        XCTAssertNil(HTTPContentRange("anything"))
    }
    func testChunkAndBackgroundRangeHeaders() {
        XCTAssertEqual(TransferRange.header(offset: 0, total: nil), "bytes=0-8388607")
        XCTAssertEqual(TransferRange.header(offset: 8, total: 16), "bytes=8-15")
        XCTAssertEqual(TransferRange.header(offset: 8, total: 16, openEnded: true), "bytes=8-")
        XCTAssertNil(TransferRange.header(offset: 16, total: 16))
        XCTAssertNil(TransferRange.header(offset: -1, total: 16))
    }
    func testFileAssemblyRejectsDuplicateOrOutOfOrderData() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("one"), second = folder.appendingPathComponent("two"), output = folder.appendingPathComponent("output")
        try Data("abc".utf8).write(to: first); try Data("def".utf8).write(to: second)
        try TransferRange.append(first, to: output, expectedOffset: 0)
        XCTAssertEqual(try DiskFile.size(output), 3)
        XCTAssertThrowsError(try TransferRange.append(first, to: output, expectedOffset: 0))
        XCTAssertEqual(try Data(contentsOf: output), Data("abc".utf8))
        try TransferRange.append(second, to: output, expectedOffset: 3)
        XCTAssertEqual(try Data(contentsOf: output), Data("abcdef".utf8))
    }
    func testDefaultFastFormatSelectionAndAudio() {
        let url = URL(string: "https://r.googlevideo.com/file")!
        var combined = YouTubeMediaFormat(id: 18, url: url, label: "360p", ext: "mp4", audioOnly: false); combined.height = 360
        var adaptive = YouTubeMediaFormat(id: 136, url: url, label: "720p", ext: "mp4", audioOnly: false, companionAudioURL: url); adaptive.height = 720
        var audio = YouTubeMediaFormat(id: 140, url: url, label: "M4A", ext: "m4a", audioOnly: true); audio.bitrate = 128000
        XCTAssertEqual(FormatSelection.best([adaptive, combined, audio], audioOnly: false, maxHeight: 720, preferCombined: true)?.id, 18)
        XCTAssertEqual(FormatSelection.best([adaptive, combined, audio], audioOnly: false, maxHeight: 720, preferCombined: false)?.id, 136)
        XCTAssertEqual(FormatSelection.best([adaptive, combined, audio], audioOnly: true, maxHeight: 720, preferCombined: true)?.id, 140)
    }
    func testEmptyMediaIsRejectedSpecifically() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data().write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        do { _ = try await MediaInspector.inspect(file); XCTFail("Empty media accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("boş")) }
    }
    func testHTMLDisguisedAsMP4IsNotImported() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("<!DOCTYPE html><html>access denied</html>".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do { _ = try await MediaInspector.inspect(file); XCTFail("HTML accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTML")) }
    }
    func testMalformedContentRangeSeparatorsAreRejected() {
        for value in ["bytes 0--7/16", "bytes 0-7//16", "bytes 0-7/16/", "bytes -0-7/16"] {
            XCTAssertNil(HTTPContentRange(value), value)
        }
    }
    func testAssemblyCannotAppendFileToItself() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try TransferRange.append(file, to: file, expectedOffset: 3))
        XCTAssertEqual(try Data(contentsOf: file), Data("abc".utf8))
    }
    @MainActor func testResolveEnqueueRollsBackOnPersistenceFailure() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let flow = ImportFlow(stateURL: blocker.appendingPathComponent("jobs.json"), automaticallyResolve: false)
        XCTAssertFalse(flow.enqueue([SavedVideo(id: "abcdefghijk", title: "Test", channel: "")]))
        XCTAssertTrue(flow.jobs.isEmpty)
        XCTAssertEqual(flow.event, 0)
        XCTAssertNotNil(flow.message)
    }
    @MainActor func testResolveQueuePersistsAndSeparatesAudioFromVideo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("jobs.json")
        let video = SavedVideo(id: "abcdefghijk", title: "Test", channel: "")
        let flow = ImportFlow(stateURL: url, automaticallyResolve: false)
        XCTAssertTrue(flow.enqueue([video], audioOnly: false))
        XCTAssertTrue(flow.enqueue([video], audioOnly: false))
        XCTAssertEqual(flow.jobs.count, 1)
        XCTAssertTrue(flow.enqueue([video], audioOnly: true))
        XCTAssertEqual(flow.jobs.count, 2)
        let restored = ImportFlow(stateURL: url, automaticallyResolve: false)
        XCTAssertEqual(restored.jobs.count, 2)
        XCTAssertEqual(Set(restored.jobs.map(\.audioOnly)), [false, true])
    }

    func testLiveSizeAfterWriteAndTruncateWithPrimedURLCache() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try url.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertEqual(try DiskFile.size(url), 0)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("abcdef".utf8)); try handle.synchronize()
        XCTAssertEqual(try DiskFile.size(url), 6)
        try handle.truncate(atOffset: 2); try handle.synchronize()
        XCTAssertEqual(try DiskFile.size(url), 2)
    }
    func testOffMainCopyDoesNotSeeCachedEmptySize() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source"), output = folder.appendingPathComponent("output")
        let data = Data(repeating: 42, count: 1024 * 1024 + 17)
        try data.write(to: source); try Data().write(to: output)
        _ = try output.resourceValues(forKeys: [.fileSizeKey])
        try await TransferRange.appendOffMain(source, to: output, expectedOffset: 0)
        XCTAssertEqual(try DiskFile.size(output), Int64(data.count))
        XCTAssertEqual(try Data(contentsOf: output), data)
        XCTAssertThrowsError(try TransferRange.append(source, to: output, expectedOffset: 0))
        XCTAssertEqual(try Data(contentsOf: output), data)
    }
    func testMissingFileSizeIsErrorNotZero() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try DiskFile.size(missing))
    }

}
