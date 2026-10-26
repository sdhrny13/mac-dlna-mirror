import CoreGraphics
import Foundation

/// Virtual monitor for "Second display" mode. macOS treats it as a real one: windows can be dragged onto it
/// and it shows up in System Settings → Displays. It lives as long as this object does.
///
/// Gotcha (measured on macOS 26.6.2): macOS remembers each "monitor" by its identity
/// (vendor/product/serial), and for some identities applySettings says "yes" but the monitor never
/// turns on. So we wait until it really appears in the active display list, and if it doesn't, retry
/// with a new identity. A working identity is saved: that way macOS also keeps the monitor's arrangement.
final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    private var handle: Any?

    struct Unavailable: LocalizedError {
        var errorDescription: String? {
            tr("macOS did not allow creating a virtual monitor — \"Second display\" mode is unavailable on this system version",
               "macOS не дала создать виртуальный монитор — режим «Второй экран» недоступен в этой версии системы")
        }
    }

    private init(handle: Any, id: CGDirectDisplayID, width: Int, height: Int) {
        self.handle = handle
        self.displayID = id
        self.width = width
        self.height = height
    }

    private static let identityKey = "virtualDisplay.identity"

    /// Creates the monitor and waits until it becomes active (up to 3 attempts with different identities).
    static func create(width: Int = 1920, height: Int = 1080, name: String = "TVMirror") async throws -> VirtualDisplay {
        var identity = UserDefaults.standard.array(forKey: identityKey) as? [Int]
        for attempt in 1...3 {
            let ids = identity ?? [Int.random(in: 0x1000...0xEFFF), Int.random(in: 0x1000...0xEFFF), Int.random(in: 1...0x7FFF_FFFF)]
            let created: (Any, CGDirectDisplayID)? = await MainActor.run {
                var id: CGDirectDisplayID = 0
                guard let h = TVMCreateVirtualDisplay(name, UInt32(width), UInt32(height), 60,
                                                      UInt32(ids[0]), UInt32(ids[1]), UInt32(ids[2]), &id), id != 0
                else { return nil }
                return (h, id)
            }
            guard let (h, id) = created else { throw Unavailable() }
            let vd = VirtualDisplay(handle: h, id: id, width: width, height: height)
            if await waitActive(id, timeout: 2) {
                UserDefaults.standard.set(ids, forKey: identityKey)
                log("second display: monitor \(width)×\(height) on, id \(id), attempt \(attempt)")
                return vd
            }
            log("second display: monitor id \(id) did not turn on — retrying with a new identity")
            await MainActor.run { vd.close() }
            identity = nil
            UserDefaults.standard.removeObject(forKey: identityKey)
        }
        throw Unavailable()
    }

    /// CGGetActiveDisplayList also refreshes the process's display cache — without it the new monitor is "not visible".
    private static func waitActive(_ id: CGDirectDisplayID, timeout: Double) async -> Bool {
        let deadline = now() + timeout
        while now() < deadline {
            var list = [CGDirectDisplayID](repeating: 0, count: 32)
            var n: UInt32 = 0
            CGGetActiveDisplayList(32, &list, &n)
            if list.prefix(Int(n)).contains(id) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func close() {
        guard handle != nil else { return }
        handle = nil
        log("second display: virtual monitor removed")
    }

    deinit { close() }
}
