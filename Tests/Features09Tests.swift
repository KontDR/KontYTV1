import XCTest
@testable import KontYT

final class Features09Tests: XCTestCase {
    func testModernPlaylistCardsAndSidebarIsolation() throws {
        let fixture = #"{"contents":{"items":[{"lockupViewModel":{"contentId":"Qwfl2M67xCI","contentType":"LOCKUP_CONTENT_TYPE_VIDEO","metadata":{"lockupMetadataViewModel":{"title":{"content":"Mabel Matiz - Umrumdışı"},"metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":[{"text":{"content":"mabelmatiz"}}]}]}}}}}},{"lockupViewModel":{"contentId":"abcdefghijk","contentType":"LOCKUP_CONTENT_TYPE_PLAYLIST"}}]},"sidebar":{"lockupViewModel":{"contentId":"dQw4w9WgXcQ","contentType":"LOCKUP_CONTENT_TYPE_VIDEO"}}}"#
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        let batch = YouTubeHTML.videos(in: root, playlistOnly: true)
        XCTAssertEqual(batch.videos.map(\.id), ["Qwfl2M67xCI"])
        XCTAssertEqual(batch.videos.first?.title, "Mabel Matiz - Umrumdışı")
        XCTAssertEqual(batch.videos.first?.channel, "mabelmatiz")
    }
    func testModernContinuationViewModel() throws {
        let fixture = #"{"contents":[{"continuationItemViewModel":{"continuationCommand":{"innertubeCommand":{"continuationCommand":{"token":"page-two","request":"CONTINUATION_REQUEST_TYPE_BROWSE"}}}}}]}"#
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        XCTAssertEqual(YouTubeHTML.continuationToken(in: root), "page-two")
        XCTAssertTrue(YouTubeHTML.videos(in: root, playlistOnly: true).hasMore)
    }
    func testRateLimitDistinguishedFromLogin() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://www.youtube.com/playlist")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "123"]))
        XCTAssertEqual(YouTubeHTTP.retrySeconds(response), 123)
        XCTAssertThrowsError(try YouTubeHTTP.validate(response)) { error in
            guard case YouTubeWebError.rateLimited(let delay) = error else { return XCTFail("Wrong status mapping") }
            XCTAssertEqual(delay, 123)
        }
    }
    func testForbiddenAndConsentRemainDifferent() throws {
        let forbidden = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://www.youtube.com/playlist")!, statusCode: 403, httpVersion: nil, headerFields: nil))
        let consent = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://consent.youtube.com/m")!, statusCode: 200, httpVersion: nil, headerFields: nil))
        XCTAssertThrowsError(try YouTubeHTTP.validate(forbidden)) { error in
            guard case YouTubeWebError.forbidden = error else { return XCTFail("Wrong forbidden mapping") }
        }
        XCTAssertThrowsError(try YouTubeHTTP.validate(consent)) { error in
            guard case YouTubeWebError.consent = error else { return XCTFail("Wrong consent mapping") }
        }
    }
    func testLRCMultipleTimestampsAndOffset() {
        let lines = LRCParser.parse("[ar:Test]\n[offset:500]\n[00:01.50][00:03.000]Aynı satır\n[00:02.00]İkinci")
        XCTAssertEqual(lines.map(\.text), ["Aynı satır", "İkinci", "Aynı satır"])
        XCTAssertEqual(lines.map(\.seconds), [1, 1.5, 2.5])
        XCTAssertEqual(Set(lines.map(\.id)).count, 3)
    }
    func testLRCInvalidSecondsAndPlainText() {
        XCTAssertTrue(LRCParser.parse("plain text\n[00:99.00]invalid\n[ar:Name]").isEmpty)
    }
    func testSongGuessDoesNotInventArtistFromTitleOnly() {
        let guess = SongIdentity.guess("Mabel Matiz - Umrumdışı (Official Video)")
        XCTAssertEqual(guess.artist, "Mabel Matiz"); XCTAssertEqual(guess.title, "Umrumdışı")
        XCTAssertEqual(SongIdentity.guess("Umrumdışı").artist, "")
    }
    func testLyricsConfidenceRequiresArtistTitleAndDuration() {
        let record = LyricsRecord(id: 1, trackName: "Song", artistName: "Artist", albumName: "", duration: 180, instrumental: false, plainLyrics: nil, syncedLyrics: nil)
        XCTAssertTrue(SongIdentity.confident(record, artist: "Artist", title: "Song", duration: 182))
        XCTAssertFalse(SongIdentity.confident(record, artist: "", title: "Song", duration: 180))
        XCTAssertFalse(SongIdentity.confident(record, artist: "Artist", title: "Song", duration: 220))
        XCTAssertFalse(SongIdentity.confident(record, artist: "Other", title: "Song", duration: 180))
    }
    @MainActor func testResolveRecordCanBeRemovedWithoutRestartingWorker() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("jobs.json")
        var job = ResolveJob(video: SavedVideo(id: "abcdefghijk", title: "Test", channel: ""), audioOnly: true, maxHeight: 720, preferCombined: true)
        job.status = "Hata"; job.error = "Test failure"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode([job]).write(to: path)
        let flow = ImportFlow(stateURL: path, automaticallyResolve: false)
        flow.remove(job.id)
        XCTAssertTrue(flow.jobs.isEmpty)
        XCTAssertTrue(ImportFlow(stateURL: path, automaticallyResolve: false).jobs.isEmpty)
    }
    func testGainIsBoundedAndRejectsNonFinite() {
        XCTAssertEqual(AudioBoost.gain(-1), 0)
        XCTAssertEqual(AudioBoost.gain(3), 3)
        XCTAssertEqual(AudioBoost.gain(99), 6)
        XCTAssertEqual(AudioBoost.gain(.nan), 0)
        XCTAssertEqual(AudioBoost.gain(.infinity), 0)
    }
    func testOldArchiveMetadataMigration() throws {
        let id = UUID()
        let raw = "{\"id\":\"\(id.uuidString)\",\"name\":\"Old\",\"filename\":\"old.m4a\",\"isVideo\":false}"
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(raw.utf8))
        XCTAssertNil(item.artworkFilename); XCTAssertNil(item.sourceVideoID); XCTAssertNil(item.channel)
    }
    func testTrackDetailsRoundTrip() throws {
        let details = TrackDetails(videoID: "Qwfl2M67xCI", title: "Song", channel: "Channel")
        let restored = try JSONDecoder().decode(TrackDetails.self, from: JSONEncoder().encode(details))
        XCTAssertEqual(restored.videoID, details.videoID); XCTAssertEqual(restored.channel, details.channel)
    }
    func testContinuationActionsWinOverEmptyOrUnrelatedContents() throws {
        let fixture = #"{"contents":{},"onResponseReceivedActions":[{"appendContinuationItemsAction":{"continuationItems":[{"lockupViewModel":{"contentId":"abcdefghijk","contentType":"LOCKUP_CONTENT_TYPE_VIDEO","metadata":{"lockupMetadataViewModel":{"title":{"content":"Next page"}}}}}]}}],"sidebar":{"lockupViewModel":{"contentId":"dQw4w9WgXcQ","contentType":"LOCKUP_CONTENT_TYPE_VIDEO"}}}"#
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        XCTAssertEqual(YouTubeHTML.videos(in: root, playlistOnly: true).videos.map(\.id), ["abcdefghijk"])
    }

    func testBoostSpaceEstimateHasExplicitStableUnits() {
        XCTAssertEqual(AudioBoost.requiredSpace(sourceBytes: 100, duration: 10), 108697600.0)
        XCTAssertEqual(AudioBoost.requiredSpace(sourceBytes: 0, duration: .nan), 104857600.0)
        XCTAssertEqual(AudioBoost.requiredSpace(sourceBytes: -1, duration: -1), 104857600.0)
    }

    func testBrowserNavigationIsLimitedToOfficialHTTPSHosts() {
        XCTAssertTrue(YouTubeBrowserPolicy.allowed(URL(string: "https://www.youtube.com/playlist?list=PLtest")!))
        XCTAssertTrue(YouTubeBrowserPolicy.allowed(URL(string: "https://consent.youtube.com/m")!))
        XCTAssertTrue(YouTubeBrowserPolicy.allowed(URL(string: "https://accounts.google.com/ServiceLogin")!))
        for raw in ["https://youtube.com.evil.test/", "https://accounts.google.com.evil.test/", "http://www.youtube.com/", "https://user:secret@youtube.com/", "file:///tmp/test"] {
            XCTAssertFalse(YouTubeBrowserPolicy.allowed(URL(string: raw)!), raw)
        }
    }
    func testBrowserCanonicalPlaylistDoesNotNeedVideoOrAccount() throws {
        let input = URL(string: "https://www.youtube.com/watch?v=Qwfl2M67xCI&list=PLDIoUOhQQPlVr3qepMVRsDe4T8vNQsvno")!
        let target = try XCTUnwrap(YouTubeBrowserPolicy.target(input))
        XCTAssertEqual(target.path, "/playlist")
        XCTAssertEqual(YouTubeBrowserPolicy.playlistID(target), "PLDIoUOhQQPlVr3qepMVRsDe4T8vNQsvno")
        XCTAssertNil(URLComponents(url: target, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" }))
    }
    func testBrowserRejectsInvalidListAndForeignHost() {
        XCTAssertNil(YouTubeBrowserPolicy.target(URL(string: "https://youtube.com/watch?v=abcdefghijk")!))
        XCTAssertNil(YouTubeBrowserPolicy.target(URL(string: "https://evil.test/?list=PLtest")!))
        XCTAssertNil(YouTubeBrowserPolicy.target(URL(string: "https://youtube.com/playlist?list=PL%27bad")!))
    }

    func testLiveGainRangeAndNormalBypass() {
        XCTAssertEqual(LiveGainMath.bounded(-5), 1)
        XCTAssertEqual(LiveGainMath.bounded(3), 2)
        XCTAssertEqual(LiveGainMath.bounded(.nan), 1)
        XCTAssertEqual(LiveGainMath.sample(0.99, gain: 1), 0.99)
    }
    func testLiveGainActuallyRaisesQuietSignal() {
        XCTAssertEqual(LiveGainMath.sample(0.1, gain: 1.5), 0.15, accuracy: 0.00001)
        XCTAssertEqual(LiveGainMath.sample(-0.1, gain: 2), -0.2, accuracy: 0.00001)
    }
    func testLiveGainSoftLimitsPeaksAndClearsInvalidSamples() {
        let positive = LiveGainMath.sample(0.8, gain: 2)
        XCTAssertGreaterThan(positive, 0.8)
        XCTAssertLessThanOrEqual(positive, 1)
        XCTAssertEqual(LiveGainMath.sample(-0.8, gain: 2), -positive, accuracy: 0.00001)
        XCTAssertEqual(LiveGainMath.sample(.nan, gain: 2), 0)
    }

    func testPitchRatioIsBoundedAndMonotonic() {
        XCTAssertEqual(LiveGainMath.pitchRatio(0), 1, accuracy: 0.0001)
        XCTAssertEqual(LiveGainMath.pitchRatio(6), 1.41421, accuracy: 0.0002)
        XCTAssertEqual(LiveGainMath.pitchRatio(-6), 0.70711, accuracy: 0.0002)
        XCTAssertEqual(LiveGainMath.pitchBounded(99), 6)
        XCTAssertEqual(LiveGainMath.pitchBounded(-99), -6)
        XCTAssertEqual(LiveGainMath.pitchBounded(.nan), 0)
    }
    func testPitchSlopeDirectionMatchesShifterDelayRamp() {
        XCTAssertEqual(LiveGainMath.pitchSlope(0), 0, accuracy: 0.00001)
        // Lower pitch slows the read pointer (negative ramp), higher pitch speeds it up.
        XCTAssertLessThan(LiveGainMath.pitchSlope(-6), 0)
        XCTAssertGreaterThan(LiveGainMath.pitchSlope(6), 0)
        XCTAssertGreaterThan(LiveGainMath.pitchSlope(3), LiveGainMath.pitchSlope(1))
    }
    func testReverbMixStaysInSafeRange() {
        XCTAssertEqual(LiveGainMath.reverbBounded(-1), 0)
        XCTAssertEqual(LiveGainMath.reverbBounded(0.25), 0.25, accuracy: 0.00001)
        XCTAssertEqual(LiveGainMath.reverbBounded(9), 0.6)
        XCTAssertEqual(LiveGainMath.reverbBounded(Float.nan), 0)
        XCTAssertEqual(LiveGainMath.reverbBounded(Float.infinity), 0)
    }
    func testPageSignalClassificationCoversRealFailureModes() {
        XCTAssertEqual(YouTubePageSignal.detect("<a href=\"https://consent.youtube.com/m\">"), .consent)
        XCTAssertEqual(YouTubePageSignal.detect("Our systems have detected unusual traffic"), .botCheck)
        XCTAssertEqual(YouTubePageSignal.detect("This playlist is private"), .privateList)
        XCTAssertEqual(YouTubePageSignal.detect("This playlist does not exist"), .removed)
        XCTAssertEqual(YouTubePageSignal.detect("members-only content"), .membersOnly)
        XCTAssertEqual(YouTubePageSignal.detect("<html>normal</html>"), .unknown)
    }
    func testAnonymousPlaylistRequestCarriesConsentCookies() {
        let url = URL(string: "https://www.youtube.com/playlist?list=PLDIoUOhQQPlVr3qepMVRsDe4T8vNQsvno")!
        let desktop = YouTubeWebClient.pageRequest(url: url)
        XCTAssertEqual(desktop.value(forHTTPHeaderField: "Cookie")?.contains("SOCS=CAI"), true)
        XCTAssertEqual(desktop.value(forHTTPHeaderField: "User-Agent"), YouTubeWebClient.desktopUserAgent)
        let mobile = YouTubeWebClient.pageRequest(url: url, mobile: true)
        XCTAssertEqual(mobile.value(forHTTPHeaderField: "User-Agent"), YouTubeWebClient.mobileUserAgent)
    }
    func testFetchDiagnosticsSummaryStaysCompact() {
        let value = YouTubeFetchDiagnostics(target: "PLx", attempt: "mobil", httpStatus: 200, bytes: 2048, hadInitialData: true, hadPlayerResponse: false, cards: 0, signal: "unknown")
        XCTAssertTrue(value.summary.contains("mobil"))
        XCTAssertTrue(value.summary.contains("kart 0"))
        XCTAssertLessThan(value.summary.count, 120)
    }

    func testPlaylistFetchDiagnosticsShape() {
        let value = YouTubeFetchDiagnostics(target: "PLx", attempt: "masaüstü", httpStatus: 200, bytes: 4096, hadInitialData: true, hadPlayerResponse: false, cards: 12, signal: "unknown")
        XCTAssertTrue(value.summary.contains("kart 12"))
        XCTAssertTrue(value.summary.contains("masaüstü"))
        XCTAssertEqual(YouTubePageSignal.detect("https://consent.youtube.com/m"), .consent)
    }
    func testResumeOptionIsOptIn() {
        UserDefaults.standard.removeObject(forKey: "resumePlayback")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "resumePlayback"), "start from the beginning by default")
        UserDefaults.standard.set(true, forKey: "resumePlayback")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "resumePlayback"))
        UserDefaults.standard.removeObject(forKey: "resumePlayback")
    }

    func testBrowserStartsMobileAndCanBuildDesktopTarget() throws {
        let input = try XCTUnwrap(URL(string: "https://www.youtube.com/playlist?list=PLDIoUOhQQPlVr3qepMVRsDe4T8vNQsvno"))
        let mobile = try XCTUnwrap(YouTubeBrowserPolicy.target(input))
        let desktop = try XCTUnwrap(YouTubeBrowserPolicy.target(input, desktop: true))
        XCTAssertEqual(mobile.host, "m.youtube.com")
        XCTAssertEqual(desktop.host, "www.youtube.com")
        XCTAssertEqual(YouTubeBrowserPolicy.playlistID(mobile), YouTubeBrowserPolicy.playlistID(desktop))
        XCTAssertTrue(YouTubeBrowserPolicy.allowed(mobile))
    }

}
