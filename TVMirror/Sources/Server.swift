import Foundation
import Network

/// A server client: the TV's DLNA player reading the MPEG-TS stream over HTTP.
final class StreamClient {
    let id: Int
    let conn: NWConnection
    let remote: String
    // the fields below change only under the server lock
    var needKey = true
    var maxPending = 512 * 1024
    var firstMedia: Double?       // stream time of the first frame sent to this client
    var onClose: ((StreamClient) -> Void)?

    private let pLock = NSLock()
    private var _pending = 0
    private var _closed = false

    init(id: Int, conn: NWConnection, remote: String) {
        self.id = id; self.conn = conn; self.remote = remote
    }

    var pending: Int { pLock.lock(); defer { pLock.unlock() }; return _pending }

    func send(_ d: Data, closeAfter: Bool = false) {
        pLock.lock()
        if _closed { pLock.unlock(); return }
        _pending += d.count
        pLock.unlock()
        conn.send(content: d, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            self.pLock.lock(); self._pending -= d.count; self.pLock.unlock()
            if err != nil || closeAfter { self.close() }
        })
    }

    func close() {
        pLock.lock()
        if _closed { pLock.unlock(); return }
        _closed = true
        pLock.unlock()
        conn.cancel()
        onClose?(self)
    }
}

/// HTTP server for the DLNA stream (Network.framework). Only the TV being streamed to and the Mac itself
/// may connect; anyone else is dropped before a single byte is read. Routes:
///   /screen-<random>.ts  — MPEG-TS for the TV's DLNA player; the path changes with every session
///   /status              — JSON for debugging
final class StreamServer {
    // DLNA stream parameters (changed by command-line flags for experiments with the TV buffer).
    static var dlnaMime = "video/mpeg"
    static var dlnaFlags = "01700000000000000000000000000000"
    static var dlnaPN: String?
    static var dlnaTLAG = false
    static var padBytesPerSecond = 0
    static var dlnaFeatures: String {
        (dlnaPN.map { "DLNA.ORG_PN=\($0);" } ?? "") + "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=\(dlnaFlags)"
    }
    /// Connections open at once; the TV needs one or two.
    static let maxConnections = 8
    /// How long a client has to send its request headers, s.
    static let requestTimeout = 5.0

    private(set) var port: UInt16 = 0
    weak var engine: Engine?
    /// Events for the UI: ("ts-open" | "ts-close", TV address).
    var onEvent: ((String, String) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "tvmirror.net", qos: .userInitiated)
    private let lock = NSLock()
    private var clients: [Int: StreamClient] = [:]
    private var nextID = 1
    private var connections = 0
    private var allowedHosts: Set<String> = []
    private var path = StreamServer.randomPath()
    private var lastRefusalLog = 0.0

    struct PortBusy: LocalizedError { var errorDescription: String? { tr("ports 8090–8099 are busy", "порты 8090–8099 заняты") } }

    func start(preferredPort: UInt16 = 8090) throws {
        for p in preferredPort..<(preferredPort + 10) where listen(on: p) {
            port = p
            log("server listening on port \(p)")
            return
        }
        throw PortBusy()
    }

    private func listen(on p: UInt16) -> Bool {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        guard let port = NWEndpoint.Port(rawValue: p), let l = try? NWListener(using: params, on: port) else { return false }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        l.stateUpdateHandler = { st in
            switch st {
            case .ready: ok = true; sem.signal()
            case .failed, .cancelled: sem.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        _ = sem.wait(timeout: .now() + 2)
        guard ok else { l.cancel(); return false }
        l.stateUpdateHandler = { st in if case .failed(let e) = st { log("server: error \(e)") } }
        listener = l
        return true
    }

    // MARK: access

    /// Opens the stream to one TV: from now on only `host` (and the Mac itself) may connect,
    /// at a fresh random path. Returns that path.
    func authorize(host: String) -> String {
        lock.lock(); defer { lock.unlock() }
        allowedHosts = [host]
        path = Self.randomPath()
        return path
    }

    /// The current stream path (for local testing).
    var streamPath: String { lock.lock(); defer { lock.unlock() }; return path }

    private static func randomPath() -> String {
        "/screen-" + (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() + ".ts"
    }

    private func isAllowed(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || allowedHosts.contains(host)
    }

    // MARK: stream state

    var tsCount: Int { lock.lock(); defer { lock.unlock() }; return clients.count }
    var wantsTS: Bool { tsCount > 0 }

    /// The stream time from which the DLNA player started watching (the most recently connected one).
    var tsFirstMedia: Double? {
        lock.lock(); defer { lock.unlock() }
        return clients.values.filter { $0.firstMedia != nil }.max { $0.id < $1.id }?.firstMedia
    }

    /// The stream has ended: drop the clients and close access until the next `authorize`.
    func streamStopped() {
        lock.lock()
        let all = Array(clients.values)
        allowedHosts = []
        path = Self.randomPath()
        lock.unlock()
        for c in all { c.close() }
    }

    // MARK: delivery

    func distributeVideo(ts: Data, keyframe: Bool, media: Double = 0) {
        var wantKey = false
        lock.lock()
        for c in clients.values {
            if c.needKey {
                guard keyframe else { wantKey = true; continue }
                c.needKey = false
                if c.firstMedia == nil {
                    c.firstMedia = media
                    log(String(format: "DLNA: first frame to client %@ — stream time %.3f", c.remote, media))
                }
            }
            if c.pending > c.maxPending {
                // The network can't keep up: drop frames until the next keyframe so latency doesn't pile up.
                c.needKey = true
                wantKey = true
                log("client \(c.remote): network can't keep up (\(c.pending / 1024) KB queued) — skipping frames")
                continue
            }
            c.send(ts)
        }
        lock.unlock()
        if wantKey { engine?.requestKeyframe() }
    }

    func distributeAudio(ts: Data) {
        lock.lock()
        for c in clients.values where !c.needKey && c.pending <= c.maxPending { c.send(ts) }
        lock.unlock()
    }

    // MARK: HTTP

    private func accept(_ c: NWConnection) {
        let host = remoteHost(c)
        lock.lock()
        let ok = isAllowed(host) && connections < Self.maxConnections
        if ok { connections += 1 }
        let t = now()
        let logRefusal = !ok && t - lastRefusalLog > 5
        if logRefusal { lastRefusalLog = t }
        lock.unlock()
        guard ok else {
            if logRefusal { log("server: refused a connection from \(host)") }
            c.cancel()
            return
        }
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed: c.cancel()
            case .cancelled:
                c.stateUpdateHandler = nil
                self?.connectionClosed()
            default: break
            }
        }
        c.start(queue: queue)
        let timeout = DispatchWorkItem { c.cancel() }
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: timeout)
        readRequest(c, Data(), timeout)
    }

    private func connectionClosed() {
        lock.lock(); connections -= 1; lock.unlock()
    }

    private func readRequest(_ c: NWConnection, _ buf: Data, _ timeout: DispatchWorkItem) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, err in
            guard let self else { return }
            var b = buf
            if let data { b.append(data) }
            if let r = b.range(of: Data([13, 10, 13, 10])) {
                timeout.cancel()
                self.route(c, String(decoding: b[b.startIndex..<r.lowerBound], as: UTF8.self))
            } else if done || err != nil || b.count > 16384 {
                c.cancel()
            } else {
                self.readRequest(c, b, timeout)
            }
        }
    }

    private func remoteHost(_ c: NWConnection) -> String {
        guard case .hostPort(let host, _) = c.endpoint else { return "?" }
        var s: String
        switch host {
        case .ipv4(let a): s = "\(a)"
        case .ipv6(let a): s = "\(a)"
        case .name(let n, _): s = n
        @unknown default: return "?"
        }
        if let i = s.firstIndex(of: "%") { s = String(s[..<i]) }   // drop the interface scope
        if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }      // IPv4 seen through an IPv6 socket
        return s
    }

    private func route(_ c: NWConnection, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { c.cancel(); return }
        let method = String(parts[0])
        let target = String(parts[1].split(separator: "?").first ?? "")
        var h: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            h[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        guard method == "GET" || method == "HEAD" else {
            respond(c, 405, "text/plain", Data("method not allowed".utf8))
            return
        }
        if target == streamPath {
            startTS(c, remote: remoteHost(c), headOnly: method == "HEAD", headers: h)
        } else if target == "/status" {
            respond(c, 200, "application/json", statusJSON(), headOnly: method == "HEAD")
        } else {
            respond(c, 404, "text/plain", Data("not found".utf8))
        }
    }

    private func respond(_ c: NWConnection, _ code: Int, _ type: String, _ body: Data, headOnly: Bool = false) {
        let reason = [200: "OK", 404: "Not Found", 405: "Method Not Allowed"][code] ?? "OK"
        var d = Data(("HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n" +
                      "Cache-Control: no-store\r\nConnection: close\r\n\r\n").utf8)
        if !headOnly { d.append(body) }
        c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
    }

    private func remove(_ cl: StreamClient) {
        lock.lock()
        let existed = clients.removeValue(forKey: cl.id) != nil
        lock.unlock()
        guard existed else { return }
        log("disconnected: \(cl.remote) (DLNA)")
        DispatchQueue.main.async { self.onEvent?("ts-close", cl.remote) }
    }

    // MARK: DLNA (MPEG-TS)

    private func startTS(_ c: NWConnection, remote: String, headOnly: Bool, headers: [String: String]) {
        let hdr = "HTTP/1.0 200 OK\r\nContent-Type: \(Self.dlnaMime)\r\n" +
            "contentFeatures.dlna.org: \(Self.dlnaFeatures)\r\ntransferMode.dlna.org: Streaming\r\n" +
            (Self.dlnaTLAG ? "realTimeInfo.dlna.org: DLNA.ORG_TLAG=*\r\n" : "") +
            "Cache-Control: no-cache\r\nConnection: close\r\nServer: TVMirror/2.0 UPnP/1.0 DLNADOC/1.50\r\n\r\n"
        if headOnly || engine?.running != true {
            c.send(content: Data(hdr.utf8), completion: .contentProcessed { _ in c.cancel() })
            return
        }
        let bitrate = engine?.config.bitrate ?? 6_000_000
        lock.lock()
        let cl = StreamClient(id: nextID, conn: c, remote: remote)
        nextID += 1
        cl.onClose = { [weak self] cl in self?.remove(cl) }
        cl.maxPending = max(1 << 20, bitrate / 8 * 3)   // the TV player reads in bursts — give it ~3 s of headroom
        clients[cl.id] = cl
        lock.unlock()
        cl.send(Data(hdr.utf8))
        log("DLNA player \(remote) connected to the stream: \(headers["user-agent"] ?? "?"), range \(headers["range"] ?? "-"), " +
            "getcontentFeatures \(headers["getcontentfeatures.dlna.org"] ?? "-")")
        DispatchQueue.main.async { self.onEvent?("ts-open", remote) }
        engine?.requestKeyframe()
        drainReads(cl)
    }

    /// The TV sends nothing after its request; reading only notices when it hangs up.
    private func drainReads(_ cl: StreamClient) {
        cl.conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, err in
            if done || err != nil { cl.close() } else { self?.drainReads(cl) }
        }
    }

    private func statusJSON() -> Data {
        lock.lock()
        let list = clients.values.map { c -> [String: Any] in ["remote": c.remote, "pending": c.pending] }
        lock.unlock()
        let e = engine
        let obj: [String: Any] = ["running": e?.running ?? false, "fps": e?.fpsOut ?? 0, "kbps": e?.kbpsOut ?? 0,
                                  "captureFps": e?.capturedFps ?? 0, "encodeMs": e?.encodeMs ?? 0,
                                  "width": e?.width ?? 0, "height": e?.height ?? 0, "clients": list]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])) ?? Data()
    }
}
