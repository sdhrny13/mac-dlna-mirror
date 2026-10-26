import AppKit
import Foundation

// No arguments — the regular windowed app.
// With --headless / --discover — command-line mode for testing and debugging:
//   TVMirror --discover
//   TVMirror --headless --test-pattern [--port 8090] [--height 1080] [--fps 30] [--no-audio]
//            [--tv 192.168.1.50 --catchup --pad-kbps 8000] [--duration 20]
let args = CommandLine.arguments
if args.contains("--headless") || args.contains("--discover") {
    Headless.run(args)
} else {
    TVMirrorApp.main()
}

enum Headless {
    static func run(_ args: [String]) -> Never {
        func value(_ k: String) -> String? {
            guard let i = args.firstIndex(of: k), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if args.contains("--discover") {
            Task {
                for tv in await DLNA.discover() {
                    print("\(tv.ip)\t\(tv.label)\tdlna=\(tv.controlURL ?? "-")\tsamsung=\(tv.samsung)")
                }
                exit(0)
            }
            dispatchMain()
        }

        let server = StreamServer()
        do { try server.start(preferredPort: UInt16(value("--port") ?? "8090") ?? 8090) } catch {
            log("server: \(error.localizedDescription)"); exit(1)
        }
        let engine = Engine(server: server)
        var cfg = StreamConfig()
        cfg.testPattern = args.contains("--test-pattern")
        cfg.height = Int(value("--height") ?? "1080") ?? 1080
        cfg.fps = Int(value("--fps") ?? "30") ?? 30
        cfg.audio = !args.contains("--no-audio")
        cfg.bitrate = Int(value("--bitrate") ?? "") ?? StreamConfig.bitrate(height: cfg.height, fps: cfg.fps)
        if let w = value("--width") { cfg.width = Int(w) }
        cfg.lowLatency = !args.contains("--no-lowlatency")
        cfg.profile = value("--profile") ?? "auto"
        cfg.ltr = args.contains("--ltr")
        cfg.extend = args.contains("--extend")
        cfg.fpsInSPS = !args.contains("--no-fps-sps")
        cfg.plainSPS = args.contains("--plain-sps")
        if let f = value("--dlna-flags") { StreamServer.dlnaFlags = f.padding(toLength: 32, withPad: "0", startingAt: 0) }
        if let m = value("--mime") { StreamServer.dlnaMime = m }
        StreamServer.dlnaPN = value("--pn")
        StreamServer.dlnaTLAG = args.contains("--tlag")
        StreamServer.padBytesPerSecond = (Int(value("--pad-kbps") ?? "0") ?? 0) * 1000 / 8
        var monitor: DLNALatency?
        var activeTV: TV?

        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sig.setEventHandler {
            engine.stop()
            if let tv = activeTV {
                let sem = DispatchSemaphore(value: 0)
                Task { await DLNA.stop(tv); sem.signal() }
                _ = sem.wait(timeout: .now() + 3)
            }
            exit(0)
        }
        sig.resume()

        Task {
            do { try await engine.start(cfg) } catch {
                log("could not start: \(error.localizedDescription)"); exit(1)
            }
            if let ip = value("--tv") {
                guard let tv = await DLNA.probe(ip: ip) else { log("TV \(ip) is not responding"); exit(1) }
                activeTV = tv
                let me = localIP(toward: tv.ip) ?? "127.0.0.1"
                let path = server.authorize(host: tv.ip)
                do {
                    try await DLNA.play(tv, url: "http://\(me):\(server.port)\(path)")
                    let m = DLNALatency(tv: tv, engine: engine, server: server, catchUp: args.contains("--catchup"),
                                        target: Double(value("--target") ?? "1") ?? 1,
                                        catchRate: Double(value("--catch-rate") ?? "0.85") ?? 0.85)
                    m.start()
                    monitor = m
                } catch { log("TV: \(error.localizedDescription)") }
            } else {
                // no TV — only this Mac may read the stream (ffprobe, VLC). Printed straight to the terminal:
                // the log masks the token.
                print("stream for local testing: http://127.0.0.1:\(server.port)\(server.streamPath)")
            }
            if let d = Double(value("--duration") ?? "") {
                try? await Task.sleep(nanoseconds: UInt64(d * 1e9))
                monitor?.stop()
                engine.stop()
                if let tv = activeTV { await DLNA.stop(tv) }
                exit(0)
            }
        }
        // stats every 2 seconds
        let stat = DispatchSource.makeTimerSource(queue: .main)
        stat.schedule(deadline: .now() + 2, repeating: 2)
        stat.setEventHandler {
            guard engine.running else { return }
            let s = String(format: "fps %.0f (captured %.0f) · %.0f kbit/s · encoder %.1f ms · DLNA %d",
                           engine.fpsOut, engine.capturedFps, engine.kbpsOut, engine.encodeMs, server.tsCount)
            log(s)
        }
        stat.resume()
        dispatchMain()
    }
}
