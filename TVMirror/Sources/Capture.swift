import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Screen and system audio capture via ScreenCaptureKit (macOS 13+). Audio works without BlackHole.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "tvmirror.capture", qos: .userInteractive)

    struct NoDisplay: LocalizedError { var errorDescription: String? { tr("no display found to capture", "не найден экран для захвата") } }

    /// Output size keeping the screen's aspect ratio. MSE on a 2017 TV handles H.264 up to 1920×1080 at most.
    static func outputSize(for display: SCDisplay, height target: Int) -> (Int, Int) {
        let aspect = Double(display.width) / Double(max(display.height, 1))
        var h = target
        var w = Int((Double(h) * aspect / 2).rounded()) * 2
        if w > 1920 {
            w = 1920
            h = Int((1920 / aspect / 2).rounded()) * 2
        }
        return (w, h)
    }

    /// `waitFor` — wait until this particular display shows up (SCK doesn't see a new virtual monitor right away).
    static func display(id: CGDirectDisplayID?, waitFor: Double = 0) async throws -> SCDisplay {
        let deadline = now() + waitFor
        while waitFor > 0, let id {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let d = content.displays.first(where: { $0.displayID == id }) { return d }
            if now() > deadline { throw NoDisplay() }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if let id, let d = content.displays.first(where: { $0.displayID == id }) { return d }
        let main = CGMainDisplayID()
        guard let d = content.displays.first(where: { $0.displayID == main }) ?? content.displays.first else {
            throw NoDisplay()
        }
        return d
    }

    func start(display: SCDisplay, width: Int, height: Int, fps: Int, audioQueue: DispatchQueue?) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.queueDepth = 6
        if audioQueue != nil {
            cfg.capturesAudio = true
            cfg.sampleRate = AudioEncoder.rate
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true
        }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if let audioQueue { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        try await s.startCapture()
        stream = s
        log("capture: display \(display.displayID) \(display.width)×\(display.height) → \(width)×\(height), audio: \(audioQueue != nil ? "yes" : "no")")
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        s.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            onFrame?(pb)
        case .audio:
            onAudio?(sb)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("capture stopped by the system: \(error.localizedDescription)")
        onError?(error)
    }
}

/// Test picture and sound without screen access — for checking the pipeline.
/// Once a second: a flash in the corner + a 1 kHz beep (shows A/V offset); the bar at the bottom shows milliseconds.
/// Frame rate check on the TV: the left square changes brightness EVERY frame, the right one is a steady gray.
/// If the TV shows every frame, the left one blends into an even gray like the right one; if it drops every
/// second frame, it is visibly darker or lighter than the right one. Frames are drawn from the encoder's frame
/// number (`render`), so the Mac side never duplicates or skips one.
final class TestPattern {
    let width: Int, height: Int, fps: Int
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// true — the encoder requests frames via render(index:), no separate video timer needed.
    var driven = false
    var onAudio: (([Float], Double) -> Void)?
    private var videoTimer: DispatchSourceTimer?
    private var audioTimer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var start = 0.0
    private var audioFrames: Int64 = 0
    private let queue = DispatchQueue(label: "tvmirror.pattern", qos: .userInteractive)
    private static let driftPPM = Double(ProcessInfo.processInfo.environment["TVMIRROR_AUDIO_DRIFT_PPM"] ?? "") ?? 0

    init(width: Int, height: Int, fps: Int) {
        self.width = width; self.height = height; self.fps = fps
    }

    func run(audioQueue: DispatchQueue?) {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        start = now()
        if !driven {
            let vt = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            vt.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(1))
            vt.setEventHandler { [weak self] in
                guard let self else { return }
                if let pb = self.render(index: Int64((now() - self.start) * Double(self.fps))) { self.onFrame?(pb) }
            }
            vt.resume()
            videoTimer = vt
        }
        if let audioQueue {
            let at = DispatchSource.makeTimerSource(flags: .strict, queue: audioQueue)
            at.schedule(deadline: .now(), repeating: 0.01, leeway: .milliseconds(1))
            at.setEventHandler { [weak self] in self?.generateAudio() }
            at.resume()
            audioTimer = at
        }
    }

    func stop() {
        videoTimer?.cancel(); videoTimer = nil
        audioTimer?.cancel(); audioTimer = nil
    }

    /// Frame number `index` (time = index / fps).
    func render(index: Int64) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let t = Double(index) / Double(fps)
        let frac = t.truncatingRemainder(dividingBy: 1)
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for r in 0..<height { memset(y + r * ys, 40, width) }
        // once-a-second flash — only in the bottom-right corner, so it doesn't blind
        if frac < 0.1 {
            let s = height / 6
            for r in (height - height / 20 - s)..<(height - height / 20) { memset(y + r * ys + width - s, 235, s) }
        }
        // frame rate check: left square 60↔190 every frame, right one a steady 147
        // (147 is the same perceived brightness as the average of 60 and 190, gamma included)
        let q = height / 5, qy = height / 12, qx = width / 12
        let toggling: Int32 = index % 2 == 0 ? 60 : 190
        for r in qy..<(qy + q) {
            memset(y + r * ys + qx, toggling, q)
            memset(y + r * ys + qx + q + q / 2, 147, q)
        }
        // running bar at the top: exactly 1/120 of the width per frame
        let step = max(1, width / 120)
        let sx = Int(index % Int64(width / step)) * step
        for r in 0..<(qy / 2) { memset(y + r * ys + sx, 220, min(step * 2, width - sx)) }
        let bw = height / 5
        let bx = Int((t / 4).truncatingRemainder(dividingBy: 1) * Double(width - bw))
        let by = height / 2 - bw / 2
        for r in by..<(by + bw) { memset(y + r * ys + bx, 180, bw) }
        let barW = Int(frac * Double(width))
        for r in (height - height / 20)..<height { memset(y + r * ys, 200, barW) }
        for r in 0..<(height / 2) { memset(uv + r * uvs, 128, width) }
        for r in (by / 2)..<((by + bw) / 2) {           // orange square
            var p = uv + r * uvs + (bx & ~1)
            for _ in 0..<(bw / 2) { p[0] = 70; p[1] = 200; p += 2 }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    private func generateAudio() {
        let target = Int64((now() - start) * Double(AudioEncoder.rate))
        guard target > audioFrames else { return }
        let n = Int(target - audioFrames)
        var buf = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let tt = Double(audioFrames + Int64(i)) / Double(AudioEncoder.rate)
            if tt.truncatingRemainder(dividingBy: 1) < 0.1 {
                let v = Float(0.25 * sin(2 * Double.pi * 1000 * tt))
                buf[2 * i] = v; buf[2 * i + 1] = v
            }
        }
        // TVMIRROR_AUDIO_DRIFT_PPM — simulates the audio clock drifting relative to video (for testing sync)
        let host = start + Double(audioFrames) / Double(AudioEncoder.rate) * (1 + Self.driftPPM / 1e6)
        audioFrames = target
        onAudio?(buf, host)
    }
}
