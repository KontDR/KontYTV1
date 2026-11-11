import XCTest
import AVFoundation
@testable import KontYT

final class MediaProcessorTests: XCTestCase {
    private func makeSilentCAF(at url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200))
        buffer.frameLength = 88200
        buffer.floatChannelData![0].initialize(repeating: 0, count: 88200)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    private func makeVideo(at url: URL) async throws {
        try await VideoFixtureWriter.write(to: url)
    }
    @MainActor func testLocalAudioExportAndMerge() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let caf = folder.appendingPathComponent("source.caf"), m4a = folder.appendingPathComponent("audio.m4a")
        let video = folder.appendingPathComponent("video.mp4"), merged = folder.appendingPathComponent("merged.mp4")
        try makeSilentCAF(at: caf)
        try await MediaProcessor.extractAudio(from: caf, to: m4a)
        try await makeVideo(at: video)
        try await MediaProcessor.merge(video: video, audio: m4a, output: merged)
        let asset = AVURLAsset(url: merged)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1); XCTAssertEqual(audioTracks.count, 1)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 1)
        let track = try XCTUnwrap(videoTracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 320); XCTAssertEqual(size.height, 240)
        // Regression: an opaque .incoming staging name must not cause a false unsupported-media error.
        let incoming = folder.appendingPathComponent("payload.incoming")
        try FileManager.default.copyItem(at: merged, to: incoming)
        let library = Library(), identifier = UUID()
        try await library.add(incoming, suggestedName: "Fixture.mp4", identifier: identifier)
        let item = try XCTUnwrap(library.items.first(where: { $0.id == identifier }))
        XCTAssertEqual(item.isVideo, true)
        try await library.add(incoming, suggestedName: "Fixture.mp4", identifier: identifier)
        XCTAssertEqual(library.items.filter { $0.id == identifier }.count, 1)
        // Missing indexed file must be reconstructed, not silently skipped.
        try FileManager.default.removeItem(at: library.file(item))
        try await library.add(incoming, suggestedName: "Fixture.mp4", identifier: identifier)
        XCTAssertEqual(library.items.filter { $0.id == identifier }.count, 1)
        // Existing corrupt media must not be reported as successful idempotent import.
        try Data("<html>not media</html>".utf8).write(to: library.file(item))
        do {
            try await library.add(incoming, suggestedName: "Fixture.mp4", identifier: identifier)
            XCTFail("Corrupt existing archive accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("HTML")) }
        library.remove(item)
    }
    func testAudioBoostWritesNewPCMAndPreservesInput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tone.caf"), output = folder.appendingPathComponent("boost.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200))
        buffer.frameLength = 88200
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<88200 { samples[i] = Float(sin(Double(i) * 2 * Double.pi * 440 / 44100)) * 0.05 }
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        let original = try Data(contentsOf: source)
        try await AudioBoost.renderOffMain(source: source, output: output, decibels: 6)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let result = try AVAudioFile(forReading: output)
        let read = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: result.processingFormat, frameCapacity: AVAudioFrameCount(result.length)))
        try result.read(into: read)
        let channel = try XCTUnwrap(read.floatChannelData?[0])
        let peak = UnsafeBufferPointer(start: channel, count: Int(read.frameLength)).reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertGreaterThan(peak, 0.06)
        XCTAssertLessThanOrEqual(peak, 1)
        XCTAssertEqual(result.length, 88200)
    }

}
