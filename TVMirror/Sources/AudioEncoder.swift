import AudioToolbox
import CoreMedia
import Foundation

/// AAC-LC 48 kHz stereo. Keeps the audio track continuous: gaps (system silence — ScreenCaptureKit then
/// sends no buffers) are filled with zeros, otherwise the TV's MSE player stalls waiting for audio.
/// All methods are called on `queue`.
final class AudioEncoder {
    static let rate = 48000
    let queue = DispatchQueue(label: "tvmirror.audio", qos: .userInteractive)
    let bitrate: Int
    /// An AAC packet and its time in samples since the start of the stream.
    var onPacket: ((Data, Int64) -> Void)?

    private var conv: AudioConverterRef?
    private var leading: Int64 = 2112
    private var maxPacket = 2048
    private var fifo: [Float] = []
    private var origin: Int64?
    private var written: Int64 = 0
    private var packets: Int64 = 0
    private let chunk = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
    fileprivate var chunkPending = false
    private(set) var lastRealAudio = 0.0

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { tr("could not start the AAC encoder (code \(status))", "не удалось запустить AAC-кодер (код \(status))") }
    }

    init(bitrate: Int) throws {
        self.bitrate = bitrate
        var inFmt = AudioStreamBasicDescription(
            mSampleRate: Double(Self.rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        var outFmt = AudioStreamBasicDescription(
            mSampleRate: Double(Self.rate), mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue), mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var c: AudioConverterRef?
        let st = AudioConverterNew(&inFmt, &outFmt, &c)
        guard st == noErr, let c else { throw Failure(status: st) }
        conv = c
        var br = UInt32(bitrate)
        AudioConverterSetProperty(c, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &br)
        var prime = AudioConverterPrimeInfo()
        var size = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        if AudioConverterGetProperty(c, kAudioConverterPrimeInfo, &size, &prime) == noErr {
            leading = Int64(prime.leadingFrames)
        }
        var mp: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioConverterGetProperty(c, kAudioConverterPropertyMaximumOutputPacketSize, &size, &mp) == noErr, mp > 0 {
            maxPacket = Int(mp)
        }
    }

    deinit {
        if let conv { AudioConverterDispose(conv) }
        chunk.deallocate()
    }

    // summary for the log
    private var statBuffers = 0, statResyncs = 0, statSilence = 0, statT = 0.0
    private var smoothed = 0.0      // smoothed offset "where audio should land" − "where we write", samples

    /// Stereo samples (interleaved L/R); `pos` is where they belong on the timeline (samples since the start).
    ///
    /// ScreenCaptureKit's audio clock slowly drifts from the video clock. Previously every offset over 20 ms
    /// was fixed by inserting silence or dropping a chunk — that caused crackling. Now a small offset is evened
    /// out by an inaudible speed adjustment (up to ±0.5%), and a hard resync happens only above 200 ms.
    func push(_ samples: [Float], at pos: Int64, real: Bool = true) {
        var input = samples
        var frames = input.count / 2
        guard frames > 0 else { return }
        var p = pos
        if real { lastRealAudio = now() }
        if origin == nil {
            if p < 0 {
                let drop = Int(min(-p, Int64(frames)))
                input.removeFirst(drop * 2); frames -= drop; p = 0
            }
            origin = p
            written = p
            smoothed = 0
        }
        let diff = p - written
        statBuffers += 1
        if diff > 9600 {
            // big gap (audio was missing, the output device switched) — pad with silence
            log(String(format: "audio: resync, %.0f ms gap — inserting silence", Double(diff) / 48))
            appendSilence(Int(diff))
            statResyncs += 1; statSilence += Int(diff)
            smoothed = 0
        } else if diff < -9600 {
            // audio arrived far "in the past" — drop the overlap once and carry on
            let drop = Int(min(-diff, Int64(frames)))
            log(String(format: "audio: resync, audio %.0f ms late — skipping %d samples", Double(-diff) / 48, drop))
            input.removeFirst(drop * 2); frames -= drop
            statResyncs += 1
            smoothed = 0
        } else {
            smoothed = smoothed * 0.9 + Double(diff) * 0.1
            // behind (diff > 0) — stretch slightly; ahead — squeeze slightly
            let k = max(-0.005, min(0.005, smoothed / 96000))
            if abs(k) > 0.0002, frames > 1 {
                input = resampleStereo(input, rate: 1 + k)
                frames = input.count / 2
            }
        }
        if frames > 0 {
            fifo.append(contentsOf: input)
            written += Int64(frames)
        }
        drain()
        let t = now()
        if t - statT > 10 {
            if statT > 0 {
                log(String(format: "audio: %d buffers in 10 s, offset %.1f ms, resyncs %d, silence inserted %.0f ms",
                           statBuffers, smoothed / 48, statResyncs, Double(statSilence) / 48))
            }
            statT = t; statBuffers = 0; statResyncs = 0; statSilence = 0
        }
    }

    /// Called from a timer: if no real audio comes in, keep the track filled with silence right up to "now".
    func fill(nowPos: Int64) {
        guard now() - lastRealAudio > 0.12 else { return }
        if origin == nil {
            origin = max(0, nowPos - 2400)
            written = origin!
        }
        let target = nowPos - 2400
        if target - written > 960 {
            statSilence += Int(target - written)
            appendSilence(Int(target - written))
            drain()
        }
    }

    private func appendSilence(_ n: Int) {
        guard n > 0 else { return }
        fifo.append(contentsOf: repeatElement(Float(0), count: n * 2))
        written += Int64(n)
    }

    private func drain() {
        while fifo.count >= 2048 {
            fifo.withUnsafeBufferPointer { src in chunk.update(from: src.baseAddress!, count: 2048) }
            fifo.removeFirst(2048)
            chunkPending = true
            encodeChunk()
        }
    }

    private func encodeChunk() {
        guard let conv, let origin else { return }
        var out = [UInt8](repeating: 0, count: maxPacket)
        var desc = AudioStreamPacketDescription()
        var n: UInt32 = 1
        var produced = 0
        let st: OSStatus = out.withUnsafeMutableBytes { raw in
            var abl = AudioBufferList(mNumberBuffers: 1,
                                      mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count),
                                                            mData: raw.baseAddress))
            let r = AudioConverterFillComplexBuffer(conv, audioInputProc, Unmanaged.passUnretained(self).toOpaque(),
                                                    &n, &abl, &desc)
            produced = Int(abl.mBuffers.mDataByteSize)
            return r
        }
        chunkPending = false
        guard st == noErr || st == audioNoMoreData, n > 0, produced > 0 else { return }
        let pts = origin + packets * 1024 - leading
        packets += 1
        if pts >= 0 { onPacket?(Data(out[0..<produced]), pts) }
    }

    fileprivate func provide(_ count: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard chunkPending else { count.pointee = 0; return audioNoMoreData }
        chunkPending = false
        count.pointee = 1024
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mNumberChannels = 2
        data.pointee.mBuffers.mDataByteSize = 1024 * 8
        data.pointee.mBuffers.mData = UnsafeMutableRawPointer(chunk)
        return noErr
    }
}

private let audioNoMoreData: OSStatus = 0x6E6D_6F72 // 'nmor'

private let audioInputProc: AudioConverterComplexInputDataProc = { _, count, data, _, user in
    Unmanaged<AudioEncoder>.fromOpaque(user!).takeUnretainedValue().provide(count, data)
}

private var lastAudioFormat = ""

/// Interleaved stereo Float32 48 kHz from a ScreenCaptureKit audio buffer — from any PCM format
/// (float/int, any channel count, any sample rate). Previously anything but Float32 was silently dropped:
/// if the format changed after switching the audio output on the Mac, audio disappeared for good.
func stereoFloats(from sb: CMSampleBuffer) -> [Float]? {
    guard let fd = CMSampleBufferGetFormatDescription(sb),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
    let frames = CMSampleBufferGetNumSamples(sb)
    let ch = Int(asbd.mChannelsPerFrame)
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let bits = Int(asbd.mBitsPerChannel)
    let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let fmt = "\(isFloat ? "float" : "int")\(bits) \(ch) ch \(Int(asbd.mSampleRate)) Hz\(nonInterleaved ? " planar" : "")"
    if fmt != lastAudioFormat { log("audio: capture format \(fmt)"); lastAudioFormat = fmt }
    guard frames > 0, ch > 0, (isFloat && bits == 32) || (!isFloat && (bits == 16 || bits == 32)) else { return nil }
    var needed = 0
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &needed, bufferListOut: nil,
                                                            bufferListSize: 0, blockBufferAllocator: nil,
                                                            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
    guard needed > 0 else { return nil }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
    defer { raw.deallocate() }
    let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    var block: CMBlockBuffer?
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: needed, blockBufferAllocator: nil,
        blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        blockBufferOut: &block) == noErr else { return nil }
    let list = UnsafeMutableAudioBufferListPointer(abl)
    // sample of channel c in frame i, as Float
    func sample(_ i: Int, _ c: Int) -> Float {
        let (bufIdx, idx) = nonInterleaved ? (min(c, list.count - 1), i) : (0, i * ch + c)
        guard let d = list[bufIdx].mData else { return 0 }
        if isFloat { return d.assumingMemoryBound(to: Float.self)[idx] }
        if bits == 16 { return Float(d.assumingMemoryBound(to: Int16.self)[idx]) / 32768 }
        return Float(d.assumingMemoryBound(to: Int32.self)[idx]) / 2147483648
    }
    var out = [Float](repeating: 0, count: frames * 2)
    let rc = ch > 1 ? 1 : 0
    for i in 0..<frames { out[2 * i] = sample(i, 0); out[2 * i + 1] = sample(i, rc) }
    if Int(asbd.mSampleRate) != AudioEncoder.rate, asbd.mSampleRate > 0 {
        out = resampleStereo(out, rate: Double(AudioEncoder.rate) / asbd.mSampleRate)
    }
    return out
}
