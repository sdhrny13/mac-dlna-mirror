import Foundation

/// Writes the frame rate into the SPS (H.264 VUI timing_info). VideoToolbox doesn't write it, and the TV's
/// hardware player may set up its output from this field and fall back to a default (30/25) without it.
/// For progressive frames: rate = time_scale / (2 × num_units_in_tick).
enum SPSTiming {
    private static let highProfiles: Set<UInt64> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]

    /// `sps` — the whole NAL (with the 0x67 header byte). nil if the layout is not one we can parse.
    static func addTiming(_ sps: Data, fps: Int) -> Data? {
        let bytes = [UInt8](sps)
        guard bytes.count > 4, bytes[0] & 0x1F == 7 else { return nil }
        var r = BitReader(unescape(Array(bytes[1...])))
        var w = BitWriter()
        func copy(_ n: Int) -> UInt64? { guard let v = r.bits(n) else { return nil }; w.put(v, n); return v }
        func copyUE() -> UInt64? { guard let v = r.ue() else { return nil }; w.ue(v); return v }

        guard let profile = copy(8), copy(8) != nil, copy(8) != nil, copyUE() != nil else { return nil }
        if highProfiles.contains(profile) {
            guard let chroma = copyUE() else { return nil }
            if chroma == 3 { guard copy(1) != nil else { return nil } }
            guard copyUE() != nil, copyUE() != nil, copy(1) != nil, let scaling = copy(1), scaling == 0 else { return nil }
        }
        guard copyUE() != nil, let poc = copyUE() else { return nil }
        if poc == 0 { guard copyUE() != nil else { return nil } } else if poc == 1 { return nil }
        guard copyUE() != nil, copy(1) != nil, copyUE() != nil, copyUE() != nil, let frameMbsOnly = copy(1) else { return nil }
        if frameMbsOnly == 0 { guard copy(1) != nil else { return nil } }
        guard copy(1) != nil, let cropping = copy(1) else { return nil }
        if cropping == 1 { for _ in 0..<4 { guard copyUE() != nil else { return nil } } }

        guard let vuiPresent = r.bits(1) else { return nil }
        w.put(1, 1)
        if vuiPresent == 1 {
            guard let ar = copy(1) else { return nil }
            if ar == 1 { guard let idc = copy(8) else { return nil }; if idc == 255 { guard copy(32) != nil else { return nil } } }
            guard let overscan = copy(1) else { return nil }
            if overscan == 1 { guard copy(1) != nil else { return nil } }
            guard let signal = copy(1) else { return nil }
            if signal == 1 {
                guard copy(4) != nil, let colour = copy(1) else { return nil }
                if colour == 1 { guard copy(24) != nil else { return nil } }
            }
            guard let chromaLoc = copy(1) else { return nil }
            if chromaLoc == 1 { guard copyUE() != nil, copyUE() != nil else { return nil } }
            guard let timing = r.bits(1), timing == 0 else { return nil }   // already present — leave it alone
        } else {
            w.put(0, 4)   // aspect_ratio, overscan, video_signal, chroma_loc — absent
        }
        w.put(1, 1)                     // timing_info_present_flag
        w.put(1, 32)                    // num_units_in_tick
        w.put(UInt64(fps * 2), 32)      // time_scale
        w.put(1, 1)                     // fixed_frame_rate_flag
        if vuiPresent == 1 {
            // rest of the VUI (hrd, bitstream_restriction) — copied as is, up to the stop bit
            guard let stop = r.stopBitPosition(), stop >= r.position else { return nil }
            var left = stop - r.position
            while left > 0 { let n = min(left, 32); guard let v = r.bits(n) else { return nil }; w.put(v, n); left -= n }
        } else {
            w.put(0, 4)   // nal_hrd, vcl_hrd, pic_struct, bitstream_restriction — absent (low_delay isn't written without hrd)
        }
        w.put(1, 1)       // rbsp_stop_one_bit
        w.alignZero()
        return Data([bytes[0]] + escape(w.bytes))
    }

    // MARK: emulation prevention (00 00 03)

    private static func unescape(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var zeros = 0
        for x in b {
            if zeros >= 2 && x == 3 { zeros = 0; continue }
            out.append(x)
            zeros = x == 0 ? zeros + 1 : 0
        }
        return out
    }

    private static func escape(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count + 4)
        var zeros = 0
        for x in b {
            if zeros >= 2 && x <= 3 { out.append(3); zeros = 0 }
            out.append(x)
            zeros = x == 0 ? zeros + 1 : 0
        }
        return out
    }

    private struct BitReader {
        let data: [UInt8]
        private(set) var position = 0
        init(_ d: [UInt8]) { data = d }

        mutating func bits(_ n: Int) -> UInt64? {
            guard n >= 0, position + n <= data.count * 8 else { return nil }
            var v: UInt64 = 0
            for _ in 0..<n {
                let bit = (data[position >> 3] >> (7 - UInt8(position & 7))) & 1
                v = (v << 1) | UInt64(bit)
                position += 1
            }
            return v
        }

        mutating func ue() -> UInt64? {
            var zeros = 0
            while true {
                guard let b = bits(1) else { return nil }
                if b == 1 { break }
                zeros += 1
                if zeros > 31 { return nil }
            }
            guard let rest = bits(zeros) else { return nil }
            return (UInt64(1) << UInt64(zeros)) - 1 + rest
        }

        /// Position of rbsp_stop_one_bit — the last 1 bit in the data.
        func stopBitPosition() -> Int? {
            for byteIdx in stride(from: data.count - 1, through: 0, by: -1) where data[byteIdx] != 0 {
                let b = data[byteIdx]
                for bit in 0..<8 where (b >> UInt8(bit)) & 1 == 1 { return byteIdx * 8 + 7 - bit }
            }
            return nil
        }
    }

    private struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var bitCount = 0

        mutating func put(_ v: UInt64, _ n: Int) {
            guard n > 0 else { return }
            for i in stride(from: n - 1, through: 0, by: -1) {
                if bitCount % 8 == 0 { bytes.append(0) }
                if (v >> UInt64(i)) & 1 == 1 { bytes[bytes.count - 1] |= 1 << UInt8(7 - bitCount % 8) }
                bitCount += 1
            }
        }

        mutating func ue(_ v: UInt64) {
            let x = v + 1
            let len = 64 - x.leadingZeroBitCount
            put(0, len - 1)
            put(x, len)
        }

        mutating func alignZero() {
            while bitCount % 8 != 0 { put(0, 1) }
        }
    }
}
