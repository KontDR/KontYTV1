import AVFoundation
import AudioToolbox
import MediaToolbox
import Darwin
import Foundation

// Live, in-place audio effects for local AVPlayerItems.
//
// Chain: pitch (granular two-head delay shifter) -> reverb (Schroeder comb/allpass)
//        -> gain with soft knee limiting.
//
// Real-time rules followed here:
//  * every buffer is allocated in `prepare`, never in `process`
//  * `process` takes one lock, no allocation, no file/network I/O, no logging
//  * neutral settings bypass the DSP entirely so plain playback stays untouched
//  * unsupported PCM formats fall back to untouched playback with a visible status
enum LiveGainMath {
    static func bounded(_ factor: Float) -> Float { factor.isFinite ? min(2, max(1, factor)) : 1 }
    static func reverbBounded(_ mix: Float) -> Float { mix.isFinite ? min(0.6, max(0, mix)) : 0 }
    static func pitchBounded(_ semitones: Float) -> Float { semitones.isFinite ? min(6, max(-6, semitones)) : 0 }
    static func pitchRatio(_ semitones: Float) -> Float { powf(2, pitchBounded(semitones) / 12) }
    /// Delay growth per output sample needed for the requested ratio.
    static func pitchSlope(_ semitones: Float) -> Float { 1 - 1 / pitchRatio(semitones) }
    /// Keeps a reverb-heavy mix inside full scale instead of letting it clip.
    @inline(__always) static func softLimit(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        let magnitude = abs(value)
        if magnitude <= 0.9 { return value }
        let limited = 0.9 + 0.1 * tanhf((magnitude - 0.9) / 0.1)
        return value < 0 ? -limited : limited
    }
    @inline(__always) static func sample(_ input: Float, gain: Float) -> Float {
        guard input.isFinite else { return 0 }
        if gain <= 1 { return input }
        let value: Float = input * gain
        let magnitude: Float = abs(value)
        if magnitude <= 0.85 { return value }
        let limited: Float = 0.85 + 0.15 * tanhf((magnitude - 0.85) / 0.15)
        return value < 0 ? -limited : limited
    }
}

struct LiveEffectValues {
    var gain: Float = 1
    var reverb: Float = 0
    var pitch: Float = 0
    var slope: Float = 0
    var pitchActive: Bool { abs(pitch) > 0.01 }
    var reverbActive: Bool { reverb > 0.001 }
    var gainActive: Bool { gain > 1.0001 }
    var isNeutral: Bool { !pitchActive && !reverbActive && !gainActive }
}

private final class EffectValue {
    private let lock = NSLock()
    private var values = LiveEffectValues()
    func set(gain: Float? = nil, reverb: Float? = nil, pitch: Float? = nil) {
        lock.lock()
        if let gain { values.gain = LiveGainMath.bounded(gain) }
        if let reverb { values.reverb = LiveGainMath.reverbBounded(reverb) }
        if let pitch {
            let bounded = LiveGainMath.pitchBounded(pitch)
            values.pitch = abs(bounded) < 0.05 ? 0 : bounded
            values.slope = LiveGainMath.pitchSlope(values.pitch)
        }
        lock.unlock()
    }
    func snapshot() -> LiveEffectValues { lock.lock(); defer { lock.unlock() }; return values }
}

// MARK: - Reverb (per channel)

private struct CombFilter {
    private var buffer: [Float]
    private var index = 0
    private var store: Float = 0
    /// 0.80 with eight combs gives a smooth ~1.4 s tail; higher values smear transients.
    private let feedback: Float = 0.8
    private let damping: Float = 0.45
    init(size: Int) { buffer = [Float](repeating: 0, count: max(1, size)) }
    mutating func clear() { for i in buffer.indices { buffer[i] = 0 }; store = 0; index = 0 }
    mutating func process(_ input: Float) -> Float {
        let output = buffer[index]
        store = output * (1 - damping) + store * damping
        buffer[index] = input + store * feedback
        index += 1
        if index >= buffer.count { index = 0 }
        return output
    }
}

private struct AllpassFilter {
    private var buffer: [Float]
    private var index = 0
    private let gain: Float = 0.5
    init(size: Int) { buffer = [Float](repeating: 0, count: max(1, size)) }
    mutating func clear() { for i in buffer.indices { buffer[i] = 0 }; index = 0 }
    mutating func process(_ input: Float) -> Float {
        let delayed = buffer[index]
        let output = -input + delayed
        buffer[index] = input + delayed * gain
        index += 1
        if index >= buffer.count { index = 0 }
        return output
    }
}

/// Freeverb-style reverb, but with the level law fixed.
///
/// The previous version summed four combs and added the wet signal on top of a barely
/// reduced dry signal, so the output regularly exceeded 1.0 and clipped - that is the
/// "distortion" heard when the reverb slider moved. This version uses eight combs and four
/// allpasses (smoother tail), a pre-delay and a low cut so bass does not muddy the tail,
/// and a constant-loudness dry/wet law (dry 1 - 0.5*mix, wet 0.5*mix).
private final class ReverbChannel {
    private var combs: [CombFilter]
    private var allpasses: [AllpassFilter]
    private var preDelay: [Float]
    private var preIndex = 0
    private var lowCutStore: Float = 0
    private var highCutState: Float = 0
    private let lowCutCoefficient: Float
    private let inputGain: Float = 0.1
    init(sampleRate: Double, offset: Int) {
        let scale = max(0.25, min(4, sampleRate / 44_100))
        // Freeverb tunings; the right channel is spread by offset samples so the tail is stereo.
        combs = [1_116, 1_188, 1_277, 1_356, 1_422, 1_491, 1_557, 1_617].map { tuning in
            CombFilter(size: Int(Double(tuning + offset) * scale))
        }
        allpasses = [556, 441, 341, 225].map { tuning in
            AllpassFilter(size: Int(Double(tuning + offset) * scale))
        }
        let delay = Int(0.018 * sampleRate)
        preDelay = [Float](repeating: 0, count: max(8, delay))
        lowCutCoefficient = Float(exp(-2 * Double.pi * 180 / sampleRate))
    }
    func process(_ input: Float) -> Float {
        // One-pole high pass keeps low frequencies out of the tail (no mud, no boom).
        lowCutStore = input - lowCutStore * lowCutCoefficient
        highCutState = lowCutStore * 0.92 + highCutState * 0.08
        let delayed = preDelay[preIndex]
        preDelay[preIndex] = highCutState
        preIndex += 1
        if preIndex >= preDelay.count { preIndex = 0 }
        let feed = delayed * inputGain
        var sum: Float = 0
        for index in combs.indices { sum += combs[index].process(feed) }
        sum *= 0.125
        for index in allpasses.indices { sum = allpasses[index].process(sum) }
        return sum
    }
    func clear() {
        for index in combs.indices { combs[index].clear() }
        for index in allpasses.indices { allpasses[index].clear() }
        for index in preDelay.indices { preDelay[index] = 0 }
        preIndex = 0; lowCutStore = 0; highCutState = 0
    }
}

// MARK: - Pitch (two-head delay-line shifter with Hann crossfade)

private final class PitchChannel {
    private static let window = 2_048
    private static let ringSize = 4_096
    // Precomputed Hann window; touched once on the prepare thread.
    private static let weights: [Float] = (0..<window).map { index in
        0.5 - 0.5 * cosf(2 * Float.pi * Float(index) / Float(window))
    }
    private var buffer = [Float](repeating: 0, count: ringSize)
    private var writeIndex = 0
    private var phase: Float = 0
    private let baseDelay: Float = 1_024
    static func warmUp() { _ = weights }
    func process(_ input: Float, slope: Float) -> Float {
        buffer[writeIndex] = input
        let weights = PitchChannel.weights
        let windowLength = Float(PitchChannel.window)
        var output: Float = 0
        for head in 0..<2 {
            var position = phase + (head == 1 ? 0.5 : 0)
            if position >= 1 { position -= 1 }
            let delay = baseDelay + position * windowLength * slope
            let whole = Int(delay)
            let fraction = delay - Float(whole)
            // Four-point Catmull-Rom interpolation: audibly cleaner than linear on bright material.
            var newer = writeIndex - whole + 1
            if newer < 0 { newer += PitchChannel.ringSize }
            var current = writeIndex - whole
            if current < 0 { current += PitchChannel.ringSize }
            var older = current - 1
            if older < 0 { older += PitchChannel.ringSize }
            var oldest = current - 2
            if oldest < 0 { oldest += PitchChannel.ringSize }
            let y0 = buffer[newer], y1 = buffer[current], y2 = buffer[older], y3 = buffer[oldest]
            let c1 = 0.5 * (y2 - y0)
            let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
            let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
            let sample = ((c3 * fraction + c2) * fraction + c1) * fraction + y1
            let weight = weights[Int(position * windowLength) & (PitchChannel.window - 1)]
            output += sample * weight
        }
        writeIndex += 1
        if writeIndex >= PitchChannel.ringSize { writeIndex = 0 }
        phase += 1 / windowLength
        if phase >= 1 { phase -= 1 }
        return output
    }
}

// MARK: - Engine

private final class EffectEngine {
    let sampleRate: Double
    let channels: Int
    private var reverbs: [ReverbChannel]
    private var pitches: [PitchChannel]
    // Block-rate parameter ramps. Dragging a slider used to jump the gain/feedback in one
    // sample, which is audible as clicks and zipper noise; now every change is spread over
    // the block that carries it.
    private var smoothedGain: Float = 1
    private var smoothedReverb: Float = 0
    private var smoothedSlope: Float = 0
    private var smoothedPitchMix: Float = 0
    private var gainStart: Float = 1, gainStep: Float = 0
    private var reverbStart: Float = 0, reverbStep: Float = 0
    private var slopeStart: Float = 0, slopeStep: Float = 0
    private var pitchStart: Float = 0, pitchStep: Float = 0
    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = max(1, min(8, channels))
        reverbs = (0..<self.channels).map { index in ReverbChannel(sampleRate: sampleRate, offset: index == 0 ? 0 : 23) }
        pitches = (0..<self.channels).map { _ in PitchChannel() }
        PitchChannel.warmUp()
    }
    func beginBlock(values: LiveEffectValues, frames: Int) {
        let count = Float(max(1, frames))
        if smoothedReverb > 0.001, values.reverb <= 0.001 {
            // Reverb switched off: drop the stale tail so a later re-enable cannot burst.
            for channel in reverbs { channel.clear() }
        }
        gainStart = smoothedGain; gainStep = (values.gain - smoothedGain) / count; smoothedGain = values.gain
        reverbStart = smoothedReverb; reverbStep = (values.reverb - smoothedReverb) / count; smoothedReverb = values.reverb
        slopeStart = smoothedSlope; slopeStep = (values.slope - smoothedSlope) / count; smoothedSlope = values.slope
        // The shifter output is time-shifted, so engaging/disengaging it must be crossfaded
        // instead of switched; otherwise every toggle produces a click.
        let targetMix: Float = values.pitchActive ? 1 : 0
        pitchStart = smoothedPitchMix; pitchStep = (targetMix - smoothedPitchMix) / count; smoothedPitchMix = targetMix
    }
    var isIdle: Bool {
        smoothedGain <= 1.0001 && abs(gainStep) < 0.00001 && smoothedReverb <= 0.001 && abs(reverbStep) < 0.00001
            && smoothedPitchMix <= 0.001 && abs(pitchStep) < 0.00001 && abs(smoothedSlope) < 0.0005
    }
    @inline(__always) private func sample(_ input: Float, channel: Int, offset: Float) -> Float {
        guard input.isFinite else { return 0 }
        let index = min(max(0, channel), channels - 1)
        let gain = gainStart + gainStep * offset
        let reverb = reverbStart + reverbStep * offset
        let slope = slopeStart + slopeStep * offset
        let pitchMix = pitchStart + pitchStep * offset
        var value = input
        if pitchMix > 0.001 {
            let shifted = pitches[index].process(value, slope: slope)
            value = value * (1 - pitchMix) + shifted * pitchMix
        }
        if reverb > 0.001 {
            let wet = reverbs[index].process(value)
            value = LiveGainMath.softLimit(value * (1 - reverb * 0.5) + wet * reverb)
        }
        if gain > 1.0001 { value = LiveGainMath.sample(value, gain: gain) }
        return value
    }
    /// Non-interleaved layout: one channel per AudioBuffer.
    func processPlanar(_ data: UnsafeMutablePointer<Float>, frames: Int, channel: Int) {
        for index in 0..<frames { data[index] = sample(data[index], channel: channel, offset: Float(index)) }
    }
    /// Interleaved layout: all channels inside one AudioBuffer.
    func processInterleaved(_ data: UnsafeMutablePointer<Float>, frames: Int, channels count: Int) {
        let width = max(1, count)
        for frame in 0..<frames {
            let base = frame * width
            let offset = Float(frame)
            for channel in 0..<width { data[base + channel] = sample(data[base + channel], channel: channel, offset: offset) }
        }
    }
}

// MARK: - Tap

private final class EffectTapContext {
    // The tap must read the same settings object the UI writes to, otherwise live changes
    // would never reach already-created audio taps.
    let value: EffectValue
    private let lock = NSLock()
    private var formatSupported: Bool?
    private var engine: EffectEngine?
    init(value: EffectValue) { self.value = value }
    func setSupported(_ flag: Bool) { lock.lock(); formatSupported = flag; lock.unlock() }
    func supported() -> Bool? { lock.lock(); defer { lock.unlock() }; return formatSupported }
    func setEngine(_ value: EffectEngine?) { lock.lock(); engine = value; lock.unlock() }
    func currentEngine() -> EffectEngine? { lock.lock(); defer { lock.unlock() }; return engine }
}

// Only the PCM output of local AVPlayerItems is processed. No alternate playback clock,
// no file rewriting: nothing here changes the media on disk.
// Context ownership: init retains the client state into tap storage, finalize releases it.
// The caller owns the state while creating the tap, including a failed Create.
final class LiveAudioGain {
    private let value = EffectValue()
    private var current: EffectTapContext?
    private(set) var gainFactor: Float = 1
    private(set) var reverbMix: Float = 0
    private(set) var pitchSemitones: Float = 0
    func set(_ factor: Float) { gainFactor = LiveGainMath.bounded(factor); value.set(gain: gainFactor) }
    func setReverb(_ mix: Float) { reverbMix = LiveGainMath.reverbBounded(mix); value.set(reverb: reverbMix) }
    func setPitch(_ semitones: Float) {
        pitchSemitones = abs(LiveGainMath.pitchBounded(semitones)) < 0.05 ? 0 : LiveGainMath.pitchBounded(semitones)
        value.set(pitch: pitchSemitones)
    }
    func resetAll() { set(1); setReverb(0); setPitch(0) }
    func resetStatus() { current = nil }
    private var activeSummary: String {
        var parts: [String] = []
        if gainFactor > 1.0001 { parts.append("ses %\(Int((gainFactor * 100).rounded()))") }
        if reverbMix > 0.001 { parts.append("yankı %\(Int((reverbMix * 100).rounded()))") }
        if abs(pitchSemitones) >= 0.05 { parts.append(String(format: "ton %+.1f yarım perde", pitchSemitones)) }
        return parts.isEmpty ? "efekt kapalı · normal oynatma" : parts.joined(separator: " · ")
    }
    var status: String {
        guard let current else { return "Uyumlu yerel ses izi bekleniyor" }
        guard let supported = current.supported() else { return "Ses işleme hazırlanıyor" }
        return supported
            ? "Canlı efekt etkin · " + activeSummary
            : "Bu ses biçiminde canlı efekt desteklenmedi; normal oynatma sürüyor"
    }
    func attach(to item: AVPlayerItem, track: AVAssetTrack) throws {
        let context = EffectTapContext(value: value)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: pointer,
            init: { _, clientInfo, storage in
                guard let clientInfo else { return }
                let state = Unmanaged<EffectTapContext>.fromOpaque(clientInfo).takeUnretainedValue()
                storage.pointee = Unmanaged.passRetained(state).toOpaque()
            },
            finalize: { tap in
                Unmanaged<EffectTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let state = Unmanaged<EffectTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let description = format.pointee
                let pcm = description.mFormatID == kAudioFormatLinearPCM
                let floating = (description.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                let littleEndian = (description.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0
                let sized = description.mBitsPerChannel == 32
                let usable = pcm && floating && littleEndian && sized
                state.setSupported(usable)
                guard usable else { state.setEngine(nil); return }
                let rate = description.mSampleRate > 8_000 ? description.mSampleRate : 44_100
                let channels = Int(max(1, min(8, description.mChannelsPerFrame)))
                // Allocation happens here, on the preparation thread, never in `process`.
                state.setEngine(EffectEngine(sampleRate: rate, channels: channels))
            },
            unprepare: { tap in
                let state = Unmanaged<EffectTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.setEngine(nil)
            },
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                framesOut.pointee = 0
                flagsOut.pointee = 0
                let result = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut)
                guard result == noErr else { return }
                guard framesOut.pointee > 0 else { return }
                let state = Unmanaged<EffectTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard state.supported() == true, let engine = state.currentEngine() else { return }
                let values = state.value.snapshot()
                let frameCount = Int(framesOut.pointee)
                engine.beginBlock(values: values, frames: frameCount)
                guard !values.isNeutral || !engine.isIdle else { return }
                let list = UnsafeMutableAudioBufferListPointer(buffers)
                if list.count > 1 {
                    // Non-interleaved: buffer N is channel N.
                    for (index, buffer) in list.enumerated() {
                        guard let data = buffer.mData else { continue }
                        let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                        let count = min(available, frameCount * Int(max(1, buffer.mNumberChannels)))
                        engine.processPlanar(data.assumingMemoryBound(to: Float.self), frames: count, channel: index)
                    }
                } else if let buffer = list.first, let data = buffer.mData {
                    let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let channels = Int(max(1, buffer.mNumberChannels))
                    let count = min(available, frameCount * channels)
                    engine.processInterleaved(data.assumingMemoryBound(to: Float.self), frames: count / channels, channels: channels)
                }
            }
        )
        var result: Unmanaged<MTAudioProcessingTap>?
        let code = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &result)
        guard code == noErr, let result else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Canlı efekt işleyici kurulamadı (\(code)); normal oynatma devam eder."])
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = result.takeRetainedValue()
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        current = context
    }
}
