import Darwin
import Foundation
import QuartzCore

/// Monotonic clock in seconds. Same base as ScreenCaptureKit PTS (host time).
func now() -> Double { CACurrentMediaTime() }

// MARK: - Log

final class Log {
    static let shared = Log()
    let fileURL: URL
    var onLine: ((String) -> Void)?
    private let lock = NSLock()
    private var buffer: [String] = []
    private let handle: FileHandle?
    private let df: DateFormatter

    private init() {
        df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // TVMIRROR_LOG — a separate log file (for test instances, so they don't overwrite the app's log)
        fileURL = ProcessInfo.processInfo.environment["TVMIRROR_LOG"].map { URL(fileURLWithPath: $0) }
            ?? dir.appendingPathComponent("TVMirror.log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    func write(_ msg: String) {
        lock.lock()
        let line = "\(df.string(from: Date())) \(msg)"
        buffer.append(line)
        if buffer.count > 400 { buffer.removeFirst(buffer.count - 400) }
        handle?.write(Data((line + "\n").utf8))
        let cb = onLine
        lock.unlock()
        print(line)
        fflush(stdout)
        cb?(line)
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

func log(_ msg: String) { Log.shared.write(msg) }

// MARK: - Big-endian byte writer

struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u24(_ v: UInt32) {
        data.append(UInt8(truncatingIfNeeded: v >> 16))
        data.append(UInt8(truncatingIfNeeded: v >> 8))
        data.append(UInt8(truncatingIfNeeded: v))
    }
    mutating func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(truncatingIfNeeded: v)) }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(truncatingIfNeeded: v)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func fourcc(_ s: String) { data.append(contentsOf: Array(s.utf8.prefix(4))) }
    mutating func zeros(_ n: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: n)) }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
}

// MARK: - Network

struct LANInterface {
    let name: String
    let addr: in_addr
    let ip: String
}

func ipString(_ a: in_addr) -> String {
    var a = a
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
    return String(cString: buf)
}

func isPrivateIPv4(_ ip: String) -> Bool {
    let p = ip.split(separator: ".").compactMap { Int($0) }
    guard p.count == 4 else { return false }
    return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
}

/// Home-network interfaces. VPN tunnels (utun etc.) are skipped: multicast doesn't go through them,
/// and a VPN in TUN mode takes over the default route — which is why plain SSDP got "No route to host".
func lanInterfaces() -> [LANInterface] {
    var res: [LANInterface] = []
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
    defer { freeifaddrs(ifap) }
    let skip = ["utun", "ipsec", "ppp", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap"]
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = p.pointee
        guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let flags = Int32(bitPattern: ifa.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
        let name = String(cString: ifa.ifa_name)
        if skip.contains(where: { name.hasPrefix($0) }) { continue }
        let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        let ip = ipString(sin.sin_addr)
        guard isPrivateIPv4(ip) else { continue }
        res.append(LANInterface(name: name, addr: sin.sin_addr, ip: ip))
    }
    return res.sorted { a, b in a.name == "en0" && b.name != "en0" }
}

func sockaddrIn(_ ip: String, _ port: UInt16) -> sockaddr_in {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    inet_pton(AF_INET, ip, &a.sin_addr)
    return a
}

/// The Mac's address that can see the given host (so the TV can reach us).
func localIP(toward host: String) -> String? {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var dst = sockaddrIn(host, 9)
    let ok = withUnsafePointer(to: &dst) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
    guard ok else { return lanInterfaces().first?.ip }
    var me = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let got = withUnsafeMutablePointer(to: &me) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) == 0 }
    }
    guard got else { return nil }
    let ip = ipString(me.sin_addr)
    // If the route goes into a VPN tunnel, use the Wi-Fi address.
    return isPrivateIPv4(ip) ? ip : (lanInterfaces().first?.ip ?? ip)
}

/// URLSession without the system proxy: VPN clients like to set an HTTP proxy,
/// but requests to the TV must go directly over the local network.
func directSession(timeout: Double = 4, delegate: URLSessionDelegate? = nil) -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.connectionProxyDictionary = [:]
    c.timeoutIntervalForRequest = timeout
    c.timeoutIntervalForResource = timeout * 2
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
}

/// Refuses HTTP redirects: the TV never needs them, and a redirect could send a request to another host.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum Net {
    static let session = directSession(timeout: 10, delegate: NoRedirects())

    static func get(_ url: URL, timeout: Double) async throws -> Data {
        var r = URLRequest(url: url)
        r.timeoutInterval = timeout
        let (data, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
