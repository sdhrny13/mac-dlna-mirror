import Foundation

/// Measuring the TV DLNA player's latency, and the "catch-up".
///
/// DLNA latency = the headroom the TV player buffered before starting: after that it plays at exactly 1×.
/// It is measured from RelTime (playback position; whole seconds on some TVs, milliseconds on Samsung): we poll
/// the TV often and catch the moment the second changes — at that moment the screen shows "first frame + RelTime".
/// If latency is above the target, the stream clock is slowed down (rate < 1): the TV receives content slightly
/// faster than real time, plays it at 1× and thereby eats up the extra headroom.
final class DLNALatency {
    let tv: TV
    private unowned let engine: Engine
    private unowned let server: StreamServer
    var catchUp: Bool
    var target: Double
    var catchRate: Double
    /// Smoothed latency, s; nil — not measured yet.
    private(set) var latency: Double?
    var onUpdate: ((Double) -> Void)?
    private var task: Task<Void, Never>?

    init(tv: TV, engine: Engine, server: StreamServer, catchUp: Bool, target: Double = 1.0, catchRate: Double = 0.85) {
        self.tv = tv
        self.engine = engine
        self.server = server
        self.catchUp = catchUp
        self.target = target
        self.catchRate = catchRate
    }

    func start() {
        task = Task.detached { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        engine.setRate(1)
    }

    /// Highest latency target worth catching up to; the TV player holds ~4 s on its own.
    static let maxTarget = 2.5

    /// The TV couldn't hold the current target, so aim higher. Past `maxTarget` catching up would only cause
    /// more stalls, so it is switched off for the rest of the session and latency stays where the TV keeps it.
    private func raiseTarget(by step: Double, _ why: String) {
        if target + step > Self.maxTarget {
            catchUp = false
            engine.setRate(1)
            log(String(format: "DLNA: %@ — catch-up off for this session (target would pass %.1f s)", why, Self.maxTarget))
        } else {
            target += step
            log(String(format: "DLNA: %@, new target %.2f s", why, target))
        }
    }

    private func run() async {
        var lastRel: Double?
        var lastState = ""
        var stateAt = 0.0
        var prevPoll = now()
        var lastChange = now()
        var samples: [Double] = []
        var lastLog = 0.0
        var precise = false     // the TV reports RelTime with fractions of a second (Samsung does)
        while !Task.isCancelled, engine.running {
            let t = now()
            if t - stateAt > 1 {
                stateAt = t
                if let st = await DLNA.transportState(tv), st != lastState {
                    let first = server.tsFirstMedia.map { String(format: "%.2f", $0) } ?? "-"
                    log(String(format: "DLNA: TV → %@ (stream %.2f s, first frame %@)", st, engine.mediaNow, first))
                    lastState = st
                    if st != "PLAYING" { engine.setRate(1) }
                }
            }
            let t1 = now()
            guard let rel = await DLNA.relTime(tv) else {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            let t2 = now()
            if rel != rel.rounded() { precise = true }
            if let lr = lastRel, rel > lr, rel - lr < 3, t2 - t1 < 0.2, let first = server.tsFirstMedia {
                // Precise RelTime — the moment of measurement is the middle of the request. Whole seconds — the second
                // changed somewhere between the previous poll and this one, take the middle (needs frequent polling).
                let tc = precise ? (t1 + t2) / 2 : (prevPoll + (t1 + t2) / 2) / 2
                let (m, _) = engine.clock(at: tc)
                let sample = m - (first + rel)
                // A jump in latency = the TV player "hiccuped" and refilled its buffer. So the target
                // is too low for this network — raise it and catch up again.
                if let prev = latency, sample > prev + 1.0, samples.count >= 3 {
                    samples.removeAll()
                    raiseTarget(by: 0.25, String(format: "TV rebuffered (latency %.2f → %.2f s)", prev, sample))
                }
                samples.append(sample)
                if samples.count > 5 { samples.removeFirst() }
                let med = samples.sorted()[samples.count / 2]
                latency = med
                onUpdate?(med)
                if t2 - lastLog > 5 {
                    lastLog = t2
                    log(String(format: "DLNA: latency ≈ %.2f s, rate %.2f, target %.2f", med, engine.playbackRate, target))
                }
                if catchUp && lastState == "PLAYING" && samples.count >= 3 {
                    if med > target + 0.3 {
                        engine.setRate(catchRate)
                    } else if med < target + 0.05 {
                        engine.setRate(1)
                    }
                }
            }
            if rel != lastRel { lastChange = t2 }
            // The TV stalled (buffer ran out) — stop catching up and aim for a larger latency
            if lastState == "PLAYING", t2 - lastChange > 2.5, engine.playbackRate < 1 {
                engine.setRate(1)
                samples.removeAll()
                raiseTarget(by: 0.5, "TV player stalled")
            }
            lastRel = rel
            prevPoll = t2
            // Poll often only while catching up or while samples are still being collected; after that, once a second.
            let calm = precise && engine.playbackRate == 1 && samples.count >= 5
            try? await Task.sleep(nanoseconds: calm ? 1_000_000_000 : 80_000_000)
        }
    }
}
