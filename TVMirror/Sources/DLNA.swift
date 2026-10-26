import Darwin
import Foundation

struct TV: Identifiable, Hashable, Codable {
    var ip: String
    var name: String
    var model: String?
    var controlURL: String?     // AVTransport (DLNA)
    var samsung = false         // answers Samsung's device-info API (:8001) — such TVs are listed first
    var id: String { ip }

    var label: String {
        var s = name.replacingOccurrences(of: "[TV] ", with: "")
        if let model, !s.contains(model) { s += " · \(model)" }
        return s
    }
}

/// TV discovery (SSDP) and control of the TV's DLNA player (UPnP AVTransport).
enum DLNA {
    static let avt = "urn:schemas-upnp-org:service:AVTransport:1"

    struct SoapError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    static func discover(timeout: Double = 3) async -> [TV] {
        await discoverDetailed(timeout: timeout).tvs
    }

    /// `blocked` — macOS keeps the app off the local network (no "Local Network" permission):
    /// then sendto returns EHOSTUNREACH on every interface.
    static func discoverDetailed(timeout: Double = 3) async -> (tvs: [TV], blocked: Bool) {
        let (locations, blocked) = await Task.detached { ssdpSearch(timeout: timeout) }.value
        var found: [String: TV] = [:]
        await withTaskGroup(of: TV?.self) { g in
            for (loc, source) in locations { g.addTask { await describe(location: loc, host: source) } }
            for await tv in g {
                guard let tv else { continue }
                if found[tv.ip]?.controlURL == nil { found[tv.ip] = tv }
            }
        }
        var result: [TV] = []
        for var tv in found.values {
            if let info = await samsungInfo(ip: tv.ip) {
                tv.samsung = true
                tv.model = tv.model ?? info.model
            }
            result.append(tv)
        }
        log("TVs found: \(result.count)" + result.map { " · \($0.model ?? "unknown model") (\($0.ip))" }.joined())
        return (result.sorted { $0.samsung && !$1.samsung }, blocked && result.isEmpty)
    }

    /// For an address typed in by hand or remembered from last time.
    static func probe(ip: String) async -> TV? {
        guard isPrivateIPv4(ip) else { return nil }
        let info = await samsungInfo(ip: ip)
        var tv = await describe(location: "http://\(ip):9197/dmr", host: ip)   // Samsung's standard DLNA address
        if tv == nil, info == nil { return nil }
        if tv == nil { tv = TV(ip: ip, name: info?.name ?? ip) }
        if let info {
            tv!.samsung = true
            tv!.model = tv!.model ?? info.model
            tv!.name = info.name ?? tv!.name
        }
        return tv
    }

    // MARK: SSDP

    /// M-SEARCH on each home-network interface separately: with a VPN on, the default route
    /// leads into the tunnel, and multicast without an explicit interface goes nowhere.
    /// Returns description URLs (LOCATION) mapped to the address each answer came from.
    static func ssdpSearch(timeout: Double) -> ([String: String], Bool) {
        var socks: [Int32] = []
        for i in lanInterfaces() {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { continue }
            var addr = i.addr
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &addr, socklen_t(MemoryLayout<in_addr>.size))
            var ttl: UInt8 = 2
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, 1)
            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            local.sin_family = sa_family_t(AF_INET)
            local.sin_addr = i.addr
            _ = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            socks.append(fd)
        }
        if socks.isEmpty { log("SSDP: no home-network interface found (Wi-Fi off?)"); return ([:], false) }
        defer { socks.forEach { close($0) } }

        let targets = [avt, "urn:schemas-upnp-org:device:MediaRenderer:1"]
        let msgs = targets.map {
            Array("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \($0)\r\n\r\n".utf8)
        }
        var dst = sockaddrIn("239.255.255.250", 1900)
        var locations: [String: String] = [:]
        let deadline = now() + timeout
        var nextSend = 0.0
        var sends = 0
        var sent = 0, unreachable = 0
        var buf = [UInt8](repeating: 0, count: 65536)
        while now() < deadline {
            if now() >= nextSend, sends < 3 {
                for fd in socks {
                    for m in msgs {
                        let r = withUnsafePointer(to: &dst) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(fd, m, m.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                        if r >= 0 { sent += 1 } else {
                            if errno == EHOSTUNREACH { unreachable += 1 }
                            if sends == 0 { log("SSDP: sendto error \(errno) (\(String(cString: strerror(errno))))") }
                        }
                    }
                }
                sends += 1
                nextSend = now() + 0.8
            }
            var pfds = socks.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            guard poll(&pfds, nfds_t(pfds.count), 100) > 0 else { continue }
            for p in pfds where p.revents & Int16(POLLIN) != 0 {
                var from = sockaddr_in()
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(p.fd, &buf, buf.count, 0, $0, &fromLen) }
                }
                guard n > 0 else { continue }
                let source = ipString(from.sin_addr)
                let text = String(decoding: buf[0..<n], as: UTF8.self)
                for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                    locations[line.dropFirst(9).trimmingCharacters(in: .whitespaces)] = source
                }
            }
        }
        if sent == 0 && unreachable > 0 { log("SSDP: looks like the app has no Local Network access") }
        return (locations, sent == 0 && unreachable > 0)
    }

    /// Reads a device description. `host` is the address the SSDP answer came from: the description and the
    /// control URL must both be plain http on that same private address, so a device on the network can't
    /// make the app fetch or post to other hosts (or local files).
    static func describe(location: String, host: String) async -> TV? {
        guard isPrivateIPv4(host), let url = URL(string: location), url.scheme == "http", url.host == host,
              let data = try? await Net.get(url, timeout: 3),
              let doc = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) else { return nil }
        func text(_ xpath: String, in node: XMLNode? = nil) -> String? {
            let n = try? (node ?? doc).nodes(forXPath: xpath).first
            let s = n?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty ?? true) ? nil : s
        }
        let base = text("//*[local-name()='URLBase']").flatMap { URL(string: $0) } ?? url
        var control: String?
        for svc in (try? doc.nodes(forXPath: "//*[local-name()='service']")) ?? [] {
            guard let type = text("./*[local-name()='serviceType']", in: svc), type.contains("AVTransport"),
                  let c = text("./*[local-name()='controlURL']", in: svc) else { continue }
            guard let u = URL(string: c, relativeTo: base)?.absoluteURL, u.scheme == "http", u.host == host else { continue }
            control = u.absoluteString
            break
        }
        guard control != nil else { return nil }
        let name = text("//*[local-name()='friendlyName']")
        name.map { Redact.hide($0, as: "<TV name>") }
        return TV(ip: host, name: name ?? host,
                  model: text("//*[local-name()='modelName']"), controlURL: control)
    }

    struct SamsungInfo { let name: String?; let model: String? }

    static func samsungInfo(ip: String) async -> SamsungInfo? {
        guard let url = URL(string: "http://\(ip):8001/api/v2/"),
              let data = try? await Net.get(url, timeout: 2),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dev = obj["device"] as? [String: Any] else { return nil }
        let name = dev["name"] as? String
        name.map { Redact.hide($0, as: "<TV name>") }
        return SamsungInfo(name: name, model: dev["modelName"] as? String)
    }

    // MARK: SOAP

    @discardableResult
    static func soap(_ control: String, _ action: String, _ args: [(String, String)], timeout: Double = 5) async throws -> String {
        let inner = args.map { "<\($0.0)>\(xmlEscape($0.1))</\($0.0)>" }.joined()
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" +
            "<s:Body><u:\(action) xmlns:u=\"\(avt)\">\(inner)</u:\(action)></s:Body></s:Envelope>"
        guard let url = URL(string: control) else { throw SoapError(text: tr("bad address \(control)", "плохой адрес \(control)")) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(avt)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.timeoutInterval = timeout
        let (data, resp) = try await Net.session.data(for: req)
        let text = String(decoding: data, as: UTF8.self)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw SoapError(text: tr("the TV rejected \(action): HTTP \(http.statusCode) \(text.prefix(200))", "ТВ отклонил \(action): HTTP \(http.statusCode) \(text.prefix(200))"))
        }
        return text
    }

    static func didl(_ url: String, title: String = tr("Mac screen", "Экран Mac")) -> String {
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"0\" parentID=\"-1\" restricted=\"1\">" +
            "<dc:title>\(xmlEscape(title))</dc:title><upnp:class>object.item.videoItem</upnp:class>" +
            "<res protocolInfo=\"http-get:*:\(StreamServer.dlnaMime):\(StreamServer.dlnaFeatures)\">\(xmlEscape(url))</res></item></DIDL-Lite>"
    }

    static func play(_ tv: TV, url: String) async throws {
        guard let c = tv.controlURL else { throw SoapError(text: tr("no DLNA player found on this TV", "у этого ТВ не найден DLNA-плеер")) }
        _ = try? await soap(c, "Stop", [("InstanceID", "0")], timeout: 3)
        try await soap(c, "SetAVTransportURI", [("InstanceID", "0"), ("CurrentURI", url), ("CurrentURIMetaData", didl(url))])
        try await Task.sleep(nanoseconds: 500_000_000)
        try await soap(c, "Play", [("InstanceID", "0"), ("Speed", "1")])
        log("DLNA: the TV accepted Play for \(url)")
    }

    static func stop(_ tv: TV) async {
        guard let c = tv.controlURL else { return }
        _ = try? await soap(c, "Stop", [("InstanceID", "0")], timeout: 3)
    }

    /// The TV's playback position in seconds (RelTime; Samsung reports it with millisecond precision).
    static func relTime(_ tv: TV) async -> Double? {
        guard let c = tv.controlURL, let xml = try? await soap(c, "GetPositionInfo", [("InstanceID", "0")], timeout: 1),
              let r = xml.range(of: "<RelTime>"), let e = xml.range(of: "</RelTime>", range: r.upperBound..<xml.endIndex)
        else { return nil }
        let parts = xml[r.upperBound..<e.lowerBound].split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    static func transportState(_ tv: TV) async -> String? {
        guard let c = tv.controlURL, let xml = try? await soap(c, "GetTransportInfo", [("InstanceID", "0")], timeout: 1),
              let r = xml.range(of: "<CurrentTransportState>"),
              let e = xml.range(of: "</CurrentTransportState>", range: r.upperBound..<xml.endIndex) else { return nil }
        return String(xml[r.upperBound..<e.lowerBound])
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
