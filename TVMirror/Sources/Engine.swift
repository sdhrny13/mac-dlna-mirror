import CoreMedia
import CoreVideo
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit

struct StreamConfig {
    var displayID: CGDirectDisplayID?
    var height = 1080
    var fps = 30
    var bitrate = 6_000_000
    var audio = true
    var testPattern = false
    // for diagnosing TV compatibility
    var width: Int?
    var lowLatency = true
    var profile = "auto"        // auto | high | main | baseline
    var ltr = false
    var plainSPS = false
    var fpsInSPS = true
    /// "Second display" mode: stream a new virtual monitor instead of mirroring the Mac screen.
    var extend = false

    static func bitrate(height: Int, fps: Int) -> Int {
        switch (height, fps) {
        case (...720, ...30): return 3_500_000
        case (...720, _): return 5_000_000
        case (_, ...30): return 6_000_000
        default: return 9_000_000
        }
    }
}

/// Capture → encoders → muxers → delivery to the server's clients.
/// Video runs at a constant frame rate: if the screen doesn't change, the last frame is repeated —
/// otherwise the TV player takes the pause for a dropout, starts buffering and latency grows.
final class Engine {
    let server: StreamServer
    private(set) var running = false
    private(set) var config = StreamConfig()
    private(set) var width = 0
    private(set) var height = 0
    var onStopped: ((String) -> Void)?

    private var capture: ScreenCapture?
    private var virtualDisplay: VirtualDisplay?
    private var pattern: TestPattern?
    private var video: VideoEncoder?
    private var audio: AudioEncoder?
    private var ts: TSMuxer?
    private var t0 = 0.0
    // Stream clock: media = clockMedia + (wall − clockWall) × rate. rate < 1 is the "catch-up":
    // the TV plays content slightly faster than real time and drains its extra buffer.
    private var clockWall = 0.0
    private var clockMedia = 0.0
    private var rate = 1.0
    private var frameTimer: DispatchSourceTimer?
    private var audioTimer: DispatchSourceTimer?
    private let encodeQueue = DispatchQueue(label: "tvmirror.encode", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var nextIndex: Int64 = -1
    private var forceKey = false
    private var lastForcedKey = 0.0
    private var lastPSI = 0.0
    private var pendingAudio: [(Data, Int64)] = []
    private var sleepAssertion: IOPMAssertionID = 0
    private var lastBadAudioLog = 0.0

    // stats for the last second
    private var statFrames = 0, statBytes = 0, statCaptured = 0, statEncodeMs = 0.0
    private(set) var fpsOut = 0.0, kbpsOut = 0.0, capturedFps = 0.0, encodeMs = 0.0
    private var statT = 0.0

    /// MPEG-TS timestamp offset from PCR: how much time the TV has to decode.
    private let tsDelay = 0.15

    init(server: StreamServer) {
        self.server = server
        server.engine = self
    }

    var mediaNow: Double {
        lock.lock(); defer { lock.unlock() }
        return running ? mediaLocked(now()) : 0
    }

    var playbackRate: Double { lock.lock(); defer { lock.unlock() }; return rate }

    private func mediaLocked(_ wall: Double) -> Double { clockMedia + (wall - clockWall) * rate }

    /// Stream time and current rate at moment `wall` (host time).
    func clock(at wall: Double) -> (Double, Double) {
        lock.lock(); defer { lock.unlock() }
        return (mediaLocked(wall), rate)
    }

    func setRate(_ r: Double) {
        lock.lock()
        guard running, abs(r - rate) > 0.001 else { lock.unlock(); return }
        let w = now()
        clockMedia = mediaLocked(w)
        clockWall = w
        rate = r
        lock.unlock()
        log(String(format: "stream rate %.2f", r))
    }

    func requestKeyframe() {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        if t - lastForcedKey > 0.3 { forceKey = true; lastForcedKey = t }
    }

    // MARK: start / stop

    func start(_ cfg: StreamConfig) async throws {
        guard !running else { return }
        config = cfg
        var displayID = cfg.displayID
        if cfg.extend && !cfg.testPattern {
            let vd = try await VirtualDisplay.create(width: 1920, height: 1080)
            virtualDisplay = vd
            displayID = vd.displayID
        }
        let display: SCDisplay?
        do {
            display = cfg.testPattern ? nil : try await ScreenCapture.display(id: displayID, waitFor: cfg.extend ? 4 : 0)
        } catch {
            releaseVirtualDisplay()
            throw error
        }
        if let display {
            (width, height) = ScreenCapture.outputSize(for: display, height: cfg.height)
        } else {
            height = cfg.height
            width = cfg.width ?? Int((Double(cfg.height) * 16 / 9 / 2).rounded()) * 2
        }

        let v = try VideoEncoder(width: width, height: height, fps: cfg.fps, bitrate: cfg.bitrate,
                                 lowLatency: cfg.lowLatency, profile: cfg.profile, ltr: cfg.ltr, plainSPS: cfg.plainSPS,
                                 fpsInSPS: cfg.fpsInSPS)
        v.onOutput = { [weak self] o in self?.videoOut(o) }
        var a: AudioEncoder?
        if cfg.audio {
            a = try AudioEncoder(bitrate: 160_000)
            a?.onPacket = { [weak self] d, pts in self?.audioOut(d, pts) }
        }
        begin(video: v, audio: a)
        if let display {
            let c = ScreenCapture()
            c.onFrame = { [weak self] pb in self?.setLatest(pb) }
            if let a {
                c.onAudio = { [weak self] sb in
                    guard let self else { return }
                    guard let s = stereoFloats(from: sb) else {
                        let t = now()
                        if t - self.lastBadAudioLog > 5 { self.lastBadAudioLog = t; log("audio: could not parse a capture buffer — skipping") }
                        return
                    }
                    self.pushAudio(s, wall: CMSampleBufferGetPresentationTimeStamp(sb).seconds, to: a)
                }
            }
            c.onError = { [weak self] e in
                DispatchQueue.main.async { self?.stop(reason: tr("screen capture was interrupted: \(e.localizedDescription)", "захват экрана прервался: \(e.localizedDescription)")) }
            }
            capture = c
            do {
                try await c.start(display: display, width: width, height: height, fps: cfg.fps, audioQueue: a?.queue)
            } catch {
                stop(reason: nil)
                throw error
            }
        } else {
            let p = TestPattern(width: width, height: height, fps: cfg.fps)
            p.driven = true   // frames are drawn from the encoder's frame number — no duplicates or skips
            if let a {
                p.onAudio = { [weak self] s, host in self?.pushAudio(s, wall: host, to: a) }
            }
            pattern = p
            p.run(audioQueue: a?.queue)
            log("test pattern \(width)×\(height) @\(cfg.fps)")
        }
        startTimers()
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), "TVMirror: streaming" as CFString,
                                    &sleepAssertion)
    }

    private func begin(video v: VideoEncoder, audio a: AudioEncoder?) {
        lock.lock(); defer { lock.unlock() }
        video = v; audio = a
        ts = TSMuxer(withAudio: a != nil)
        t0 = now()
        clockWall = t0; clockMedia = 0; rate = 1
        nextIndex = -1
        latest = nil
        forceKey = true
        pendingAudio = []
        statT = t0
        running = true
    }

    /// Audio is placed on the stream timeline. During catch-up (rate < 1) audio is muted: sped-up audio
    /// sounds "cartoonish". AudioEncoder.fill fills the gap with silence; audio comes back by itself after catch-up.
    /// `squeezeAudio` — compress audio by resampling instead of silence (higher pitch).
    var squeezeAudio = false

    private func pushAudio(_ s: [Float], wall: Double, to a: AudioEncoder) {
        let (m, r) = clock(at: wall)
        if r < 1 && !squeezeAudio { return }
        a.push(r == 1 ? s : resampleStereo(s, rate: r), at: Int64((m * Double(AudioEncoder.rate)).rounded()))
    }

    func stop(reason: String? = nil) {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()
        frameTimer?.cancel(); frameTimer = nil
        audioTimer?.cancel(); audioTimer = nil
        capture?.stop(); capture = nil
        pattern?.stop(); pattern = nil
        releaseVirtualDisplay()
        encodeQueue.sync {}
        video?.invalidate()
        lock.lock()
        video = nil; audio = nil; ts = nil; latest = nil
        lock.unlock()
        server.streamStopped()
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
        log("streaming stopped" + (reason.map { ": \($0)" } ?? ""))
        if let reason { onStopped?(reason) }
    }

    /// The monitor is removed on the main thread once capture has stopped.
    private func releaseVirtualDisplay() {
        guard let vd = virtualDisplay else { return }
        virtualDisplay = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { vd.close() }
    }

    private func setLatest(_ pb: CVPixelBuffer) {
        lock.lock()
        latest = pb
        statCaptured += 1
        lock.unlock()
    }

    private func startTimers() {
        let fps = config.fps
        let ft = DispatchSource.makeTimerSource(flags: .strict, queue: encodeQueue)
        // Ticks land midway between frame boundaries so timer jitter doesn't confuse the frame number.
        ft.schedule(deadline: .now() + 0.5 / Double(fps), repeating: 1.0 / Double(fps), leeway: .microseconds(500))
        ft.setEventHandler { [weak self] in self?.tick() }
        ft.resume()
        frameTimer = ft
        if let a = audio {
            let at = DispatchSource.makeTimerSource(flags: .strict, queue: a.queue)
            at.schedule(deadline: .now() + 0.1, repeating: 0.02, leeway: .milliseconds(2))
            at.setEventHandler { [weak self] in
                guard let self else { return }
                a.fill(nowPos: Int64(self.mediaNow * Double(AudioEncoder.rate)))
            }
            at.resume()
            audioTimer = at
        }
    }

    private func tick() {
        lock.lock()
        let source = pattern
        guard running, let v = video, source != nil || latest != nil else { lock.unlock(); return }
        let pbLatest = latest
        let fps = Double(config.fps)
        let t = now()
        let due = Int64((mediaLocked(t) * fps).rounded(.down))
        if nextIndex < 0 || due - nextIndex > 3 { nextIndex = due }
        var indices: [Int64] = []
        while nextIndex <= due { indices.append(nextIndex); nextIndex += 1 }
        var key = false
        if forceKey { key = true; forceKey = false }
        if t - statT >= 1 {
            let dt = t - statT
            fpsOut = Double(statFrames) / dt
            kbpsOut = Double(statBytes) * 8 / 1000 / dt
            capturedFps = Double(statCaptured) / dt
            encodeMs = statFrames > 0 ? statEncodeMs / Double(statFrames) : 0
            statFrames = 0; statBytes = 0; statCaptured = 0; statEncodeMs = 0; statT = t
        }
        lock.unlock()
        for (i, idx) in indices.enumerated() {
            guard let pb = source?.render(index: idx) ?? pbLatest else { continue }
            v.encode(pb, index: idx, forceKeyframe: key && i == 0)
        }
    }

    // MARK: encoder output

    private func videoOut(_ o: VideoEncoder.Output) {
        lock.lock()
        guard running, let v = video, let ts else { lock.unlock(); return }
        statFrames += 1; statBytes += o.avcc.count; statEncodeMs += o.encodeMs
        let fps = UInt64(config.fps)
        lock.unlock()
        guard server.wantsTS else { return }

        let ticks = UInt64(o.index) * 90000 / fps          // MPEG-TS clock: 90 kHz
        let annexB = H264.annexB(avcc: o.avcc, sps: v.sps, pps: v.pps, keyframe: o.keyframe)
        let pts = ticks + UInt64(tsDelay * 90000)
        lock.lock()
        let t = now()
        var out = Data()
        if !o.keyframe && t - lastPSI > 0.5 { out.append(ts.psi()); lastPSI = t }
        if o.keyframe { lastPSI = t }
        out.append(ts.video(annexB: annexB, pts: pts, pcr: ticks, keyframe: o.keyframe))
        lock.unlock()
        // Pad the stream with null packets up to a byte-rate "floor": the Samsung player measures its buffer
        // in bytes, and on a quiet screen (tens of kbit/s) the seconds of headroom pile up for too long.
        let need = StreamServer.padBytesPerSecond / config.fps - out.count
        if need >= 188 { out.append(TSMuxer.nullPackets(need / 188)) }
        server.distributeVideo(ts: out, keyframe: o.keyframe, media: Double(o.index) / Double(config.fps))
    }

    /// AAC packets are sent in pairs (~43 ms): half as many PES packets for the TV to handle.
    private func audioOut(_ packet: Data, _ pts: Int64) {
        lock.lock()
        guard running, let ts else { lock.unlock(); return }
        pendingAudio.append((packet, pts))
        guard pendingAudio.count >= 2 else { lock.unlock(); return }
        let batch = pendingAudio
        pendingAudio = []
        lock.unlock()
        guard server.wantsTS else { return }

        var adts = Data()
        for (p, _) in batch { adts.append(contentsOf: TSMuxer.adtsHeader(payloadSize: p.count)); adts.append(p) }
        let pts = UInt64(batch[0].1) * 90000 / UInt64(AudioEncoder.rate) + UInt64(tsDelay * 90000)
        lock.lock(); let data = ts.audio(adts: adts, pts: pts); lock.unlock()
        server.distributeAudio(ts: data)
    }
}

func resampleStereo(_ s: [Float], rate: Double) -> [Float] {
    let n = s.count / 2
    let m = max(1, Int((Double(n) * rate).rounded()))
    guard n > 1 else { return s }
    var out = [Float](repeating: 0, count: m * 2)
    let step = Double(n - 1) / Double(max(m - 1, 1))
    for j in 0..<m {
        let x = Double(j) * step
        let i = min(Int(x), n - 2)
        let f = Float(x - Double(i))
        out[2 * j] = s[2 * i] + (s[2 * i + 2] - s[2 * i]) * f
        out[2 * j + 1] = s[2 * i + 1] + (s[2 * i + 3] - s[2 * i + 1]) * f
    }
    return out
}
