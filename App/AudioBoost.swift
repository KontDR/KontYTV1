import AVFoundation
import AudioToolbox

// Produces a NEW local audio file. Never raises the device's hardware volume ceiling.
enum AudioBoost {
    static func gain(_ requested: Float) -> Float { requested.isFinite ? min(6, max(0, requested)) : 0 }
    static func requiredSpace(sourceBytes: Int64, duration: Double) -> Double {
        let seconds: Double = duration.isFinite ? max(0.0, duration) : 0.0
        let compressedAllowance: Double = Double(max(Int64(0), sourceBytes)) * 4.0
        let pcmBytesPerSecond: Double = 384000.0 // 48 kHz, stereo, Float32
        let pcmAllowance: Double = seconds * pcmBytesPerSecond
        let workingAllowance: Double = max(compressedAllowance, pcmAllowance)
        let safetyReserve: Double = 104857600.0
        return workingAllowance + safetyReserve
    }
    static func render(source: URL, output: URL, decibels: Float) throws {
        let input = try AVAudioFile(forReading: source)
        guard input.length > 0 else { throw YouTubeMediaError.unavailable("Ses kaynağı boş.") }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), equalizer = AVAudioUnitEQ(numberOfBands: 0)
        equalizer.globalGain = gain(decibels)
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(player); engine.attach(equalizer); engine.attach(limiter)
        let format = input.processingFormat
        engine.connect(player, to: equalizer, format: format)
        engine.connect(equalizer, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let file = try AVAudioFile(forWriting: output, settings: engine.manualRenderingFormat.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else { throw CocoaError(.fileWriteUnknown) }
        player.scheduleFile(input, at: nil)
        engine.prepare(); try engine.start(); player.play()
        defer { player.stop(); engine.stop() }
        var stalls = 0
        while engine.manualRenderingSampleTime < input.length {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(engine.manualRenderingMaximumFrameCount), input.length - engine.manualRenderingSampleTime))
            let status = try engine.renderOffline(frames, to: buffer)
            switch status {
            case .success:
                guard buffer.frameLength > 0 else { throw CocoaError(.fileWriteUnknown) }
                try file.write(from: buffer); stalls = 0
            case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                stalls += 1
                if stalls > 100 { throw YouTubeMediaError.unavailable("Çevrimdışı ses işleme ilerleyemedi. Orijinal korundu.") }
                Thread.sleep(forTimeInterval: 0.002)
            case .error: throw YouTubeMediaError.unavailable("Çevrimdışı ses motoru işleme hatası verdi. Orijinal korundu.")
            @unknown default: throw CocoaError(.fileWriteUnknown)
            }
        }
    }
    static func renderOffMain(source: URL, output: URL, decibels: Float) async throws {
        let task = Task.detached(priority: .utility) { try render(source: source, output: output, decibels: decibels) }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
