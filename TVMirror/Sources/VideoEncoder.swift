import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 via VideoToolbox in low-latency mode: no B-frames, each frame comes out right away.
final class VideoEncoder {
    struct Output {
        let avcc: Data
        let keyframe: Bool
        let index: Int64
        let encodeMs: Double
    }

    let width: Int
    let height: Int
    let fps: Int
    var onOutput: ((Output) -> Void)?
    private(set) var sps = Data()
    private(set) var pps = Data()
    private(set) var lowLatency = false
    private var session: VTCompressionSession?

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { tr("could not start the H.264 encoder (code \(status))", "не удалось запустить кодер H.264 (код \(status))") }
    }

    /// Clear the Constrained High marking (constraint_set4/5) from the SPS — for old decoders.
    private let plainSPS: Bool
    /// Write the frame rate into the SPS (VUI timing) — otherwise the TV player may show 30 instead of 60.
    private let fpsInSPS: Bool

    init(width: Int, height: Int, fps: Int, bitrate: Int, lowLatency wantLowLatency: Bool = true,
         profile: String = "auto", ltr: Bool = false, plainSPS: Bool = false, fpsInSPS: Bool = true) throws {
        self.plainSPS = plainSPS
        self.fpsInSPS = fpsInSPS
        self.width = width
        self.height = height
        self.fps = fps
        var s: VTCompressionSession?
        let lowLatencySpec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var st: OSStatus = -1
        if wantLowLatency {
            st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                            codecType: kCMVideoCodecType_H264, encoderSpecification: lowLatencySpec,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        }
        lowLatency = st == noErr && s != nil
        if !lowLatency {
            st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        }
        guard st == noErr, let session = s else { throw Failure(status: st) }
        self.session = session

        func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus { VTSessionSetProperty(session, key: key, value: value) }
        _ = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        switch profile {
        case "main": _ = set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        case "baseline": _ = set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
        case "high": _ = set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        default:
            if !(lowLatency && set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel) == noErr) {
                _ = set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            }
        }
        _ = set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // In low-latency mode VideoToolbox uses long-term reference frames (LTR, MMCO) by default.
        // The hardware decoder of a 2017 Samsung fails on such a stream with MEDIA_ERR_DECODE — turn them off.
        if lowLatency { _ = set(kVTCompressionPropertyKey_EnableLTR, ltr ? kCFBooleanTrue : kCFBooleanFalse) }
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 2) as CFNumber)
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2.0 as CFNumber)
        _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        _ = set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        _ = set(kVTCompressionPropertyKey_DataRateLimits, [bitrate * 3 / 2 / 8, 1] as CFArray)
        _ = set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        _ = set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        _ = set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        _ = set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
        log("H.264 encoder: \(width)×\(height) @\(fps), \(bitrate / 1000) kbit/s, low-latency: \(lowLatency ? "yes" : "no"), LTR: \(lowLatency && ltr ? "yes" : "no"), profile: \(profile)\(plainSPS ? ", plain SPS" : "")")
    }

    func encode(_ pb: CVPixelBuffer, index: Int64, forceKeyframe: Bool) {
        guard let session else { return }
        let pts = CMTime(value: index, timescale: CMTimeScale(fps))
        let props: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let submitted = now()
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts,
                                        duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, flags, sb in
            guard let self, status == noErr, let sb, !flags.contains(.frameDropped) else { return }
            self.handle(sb, index: index, submitted: submitted)
        }
    }

    private func handle(_ sb: CMSampleBuffer, index: Int64, submitted: Double) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let key = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        if key, let fd = CMSampleBufferGetFormatDescription(sb) { readParameterSets(fd) }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        let len = CMBlockBufferGetDataLength(bb)
        var data = Data(count: len)
        let st = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: raw.baseAddress!)
        }
        guard st == noErr else { return }
        onOutput?(Output(avcc: data, keyframe: key, index: index, encodeMs: (now() - submitted) * 1000))
    }

    private func readParameterSets(_ fd: CMFormatDescription) {
        var count = 0
        var nalLen: Int32 = 0
        for i in 0..<2 {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                  parameterSetSizeOut: &size, parameterSetCountOut: &count,
                                                                  nalUnitHeaderLengthOut: &nalLen) == noErr, let ptr {
                var d = Data(bytes: ptr, count: size)
                if i == 0 && plainSPS && d.count > 2 { d[d.startIndex + 2] &= ~0x0C }
                if i == 0 && fpsInSPS {
                    if let t = SPSTiming.addTiming(d, fps: fps) {
                        if sps.isEmpty { log("SPS: frame rate \(fps) fps written into the H.264 header (VUI timing)") }
                        d = t
                    } else if sps.isEmpty {
                        log("SPS: could not write the frame rate — unfamiliar SPS layout, passing it through as is")
                    }
                }
                if i == 0 { sps = d } else { pps = d }
            }
        }
    }

    func invalidate() {
        guard let session else { return }
        self.session = nil
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }
}
