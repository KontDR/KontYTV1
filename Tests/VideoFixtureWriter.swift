import AVFoundation
import Foundation

// Test-only producer. All mutable state and writer operations run on one queue.
// Backpressure is handled by AVAssetWriterInput, not a polling loop on an async test.
final class VideoFixtureWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "KontYT.tests.video-fixture")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var continuation: CheckedContinuation<Void, Error>?
    private var frameIndex = 0
    private var finalizing = false
    private let frameCount = 60

    private init(url: URL) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 240,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 200000, AVVideoAllowFrameReorderingKey: false]
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 240,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
    }
    static func write(to url: URL) async throws {
        try Task.checkCancellation()
        let producer = try VideoFixtureWriter(url: url)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                producer.queue.async { producer.start(continuation) }
            }
        }, onCancel: {
            producer.queue.async { producer.cancel() }
        })
    }
    private var cancelled = false
    private func cancel() {
        cancelled = true
        complete(CancellationError())
    }
    private func start(_ value: CheckedContinuation<Void, Error>) {
        continuation = value
        if cancelled { complete(CancellationError()); return }
        guard writer.startWriting() else { complete(diagnostic("startWriting")); return }
        writer.startSession(atSourceTime: .zero)
        queue.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.continuation != nil else { return }
            self.complete(self.diagnostic("120-second fixture timeout"))
        }
        input.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feed() }
    }
    private func feed() {
        guard continuation != nil, !finalizing else { return }
        while input.isReadyForMoreMediaData {
            if frameIndex == frameCount {
                finalizing = true
                writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 30))
                input.markAsFinished()
                writer.finishWriting {
                    self.queue.async {
                        if self.writer.status == .completed { self.complete(nil) }
                        else { self.complete(self.diagnostic("finishWriting")) }
                    }
                }
                return
            }
            guard writer.status == .writing else { complete(diagnostic("encoder stopped")); return }
            guard let pool = adaptor.pixelBufferPool else { complete(diagnostic("missing pixel buffer pool")); return }
            var pixel: CVPixelBuffer?
            let result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixel)
            guard result == kCVReturnSuccess, let pixel else { complete(diagnostic("pixel buffer status \(result)")); return }
            let locked = CVPixelBufferLockBaseAddress(pixel, [])
            guard locked == kCVReturnSuccess else { complete(diagnostic("pixel lock status \(locked)")); return }
            if let address = CVPixelBufferGetBaseAddress(pixel) { memset(address, 0, CVPixelBufferGetDataSize(pixel)) }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frameIndex), timescale: 30)) else {
                complete(diagnostic("append")); return
            }
            frameIndex += 1
        }
    }
    private func diagnostic(_ stage: String) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: "Video fixture failed at \(stage); frame=\(frameIndex)/\(frameCount); writerStatus=\(writer.status.rawValue); encoder=\(writer.error?.localizedDescription ?? "none")"]
        if let error = writer.error { info[NSUnderlyingErrorKey] = error }
        return NSError(domain: "KontYT.VideoFixture", code: 1, userInfo: info)
    }
    private func complete(_ error: Error?) {
        guard let value = continuation else { return }
        continuation = nil
        if let error {
            if writer.status == .writing { writer.cancelWriting() }
            value.resume(throwing: error)
        } else { value.resume() }
    }
}
