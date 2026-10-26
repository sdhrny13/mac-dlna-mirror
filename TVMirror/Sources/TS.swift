import Foundation

/// Minimal MPEG-TS muxer for DLNA mode: H.264 + AAC (ADTS), PCR on the video track.
final class TSMuxer {
    static let pmtPID: UInt16 = 0x1000
    static let videoPID: UInt16 = 0x0100
    static let audioPID: UInt16 = 0x0101

    let withAudio: Bool
    private var cc: [UInt16: UInt8] = [:]

    init(withAudio: Bool) { self.withAudio = withAudio }

    func psi() -> Data {
        var pat = ByteWriter()
        pat.u16(1); pat.u16(0xE000 | Self.pmtPID)
        var pmt = ByteWriter()
        pmt.u16(0xE000 | Self.videoPID)   // PCR PID
        pmt.u16(0xF000)                   // program_info_length = 0
        pmt.u8(0x1B); pmt.u16(0xE000 | Self.videoPID); pmt.u16(0xF000)
        if withAudio { pmt.u8(0x0F); pmt.u16(0xE000 | Self.audioPID); pmt.u16(0xF000) }
        return sectionPacket(pid: 0, section: section(tableID: 0, ext: 1, payload: pat.data))
            + sectionPacket(pid: Self.pmtPID, section: section(tableID: 2, ext: 1, payload: pmt.data))
    }

    func video(annexB: Data, pts: UInt64, pcr: UInt64, keyframe: Bool) -> Data {
        var out = keyframe ? psi() : Data()
        out.append(pes(pid: Self.videoPID, streamID: 0xE0, payload: annexB, pts: pts, pcr: pcr,
                       randomAccess: keyframe, bounded: false))
        return out
    }

    func audio(adts: Data, pts: UInt64) -> Data {
        pes(pid: Self.audioPID, streamID: 0xC0, payload: adts, pts: pts, pcr: nil, randomAccess: false, bounded: true)
    }

    /// Null TS packets (PID 0x1FFF): the decoder discards them; they only add bytes to the stream.
    static func nullPackets(_ n: Int) -> Data {
        var p = [UInt8](repeating: 0xFF, count: 188)
        p[0] = 0x47; p[1] = 0x1F; p[2] = 0xFF; p[3] = 0x10
        var d = Data(capacity: n * 188)
        for _ in 0..<n { d.append(contentsOf: p) }
        return d
    }

    static func adtsHeader(payloadSize: Int, sampleRate: Int = 48000, channels: Int = 2) -> [UInt8] {
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
        let sfi = UInt8(rates.firstIndex(of: sampleRate) ?? 3)
        let len = payloadSize + 7
        let ch = UInt8(channels)
        return [0xFF, 0xF1,
                (1 << 6) | (sfi << 2) | (ch >> 2),
                ((ch & 3) << 6) | UInt8((len >> 11) & 0x03),
                UInt8((len >> 3) & 0xFF),
                UInt8((len & 7) << 5) | 0x1F,
                0xFC]
    }

    // MARK: internals

    private func nextCC(_ pid: UInt16) -> UInt8 {
        let v = cc[pid] ?? 0
        cc[pid] = (v + 1) & 0x0F
        return v
    }

    private func section(tableID: UInt8, ext: UInt16, payload: Data) -> Data {
        var w = ByteWriter()
        w.u8(tableID)
        w.u16(0xB000 | UInt16(5 + payload.count + 4))
        w.u16(ext); w.u8(0xC1); w.u8(0); w.u8(0)
        w.bytes(payload)
        w.u32(Self.crc32(w.data))
        return w.data
    }

    private func sectionPacket(pid: UInt16, section: Data) -> Data {
        var p: [UInt8] = [0x47, 0x40 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10 | nextCC(pid), 0x00]
        p.append(contentsOf: section)
        p.append(contentsOf: [UInt8](repeating: 0xFF, count: 188 - p.count))
        return Data(p)
    }

    private static func ptsBytes(_ v: UInt64) -> [UInt8] {
        let pts = v & 0x1_FFFF_FFFF
        return [UInt8(0x20 | ((pts >> 29) & 0x0E) | 1),
                UInt8((pts >> 22) & 0xFF),
                UInt8(((pts >> 14) & 0xFE) | 1),
                UInt8((pts >> 7) & 0xFF),
                UInt8(((pts << 1) & 0xFE) | 1)]
    }

    private static func pcrBytes(_ v: UInt64) -> [UInt8] {
        let b = v & 0x1_FFFF_FFFF
        return [UInt8((b >> 25) & 0xFF), UInt8((b >> 17) & 0xFF), UInt8((b >> 9) & 0xFF),
                UInt8((b >> 1) & 0xFF), UInt8(((b & 1) << 7) | 0x7E), 0x00]
    }

    private func pes(pid: UInt16, streamID: UInt8, payload: Data, pts: UInt64, pcr: UInt64?,
                     randomAccess: Bool, bounded: Bool) -> Data {
        var h = ByteWriter()
        h.bytes([0, 0, 1, streamID])
        let len = 3 + 5 + payload.count
        h.u16(bounded && len <= 0xFFFF ? UInt16(len) : 0)
        h.u8(0x80); h.u8(0x80); h.u8(5)
        h.bytes(Self.ptsBytes(pts))
        var data = [UInt8](h.data)
        data.append(contentsOf: payload)

        var out = Data(capacity: (data.count / 184 + 2) * 188)
        var off = 0
        var first = true
        while off < data.count {
            var af: [UInt8] = []   // adaptation field contents without the length byte
            if first {
                var flags: UInt8 = 0
                if randomAccess { flags |= 0x40 }
                if pcr != nil { flags |= 0x10 }
                if flags != 0 {
                    af.append(flags)
                    if let pcr { af.append(contentsOf: Self.pcrBytes(pcr)) }
                }
            }
            var afTotal = af.isEmpty ? 0 : af.count + 1
            let remaining = data.count - off
            if remaining < 184 - afTotal {
                let stuff = 184 - afTotal - remaining
                if afTotal == 0 {
                    afTotal = stuff
                    af = stuff >= 2 ? [0x00] + [UInt8](repeating: 0xFF, count: stuff - 2) : []
                } else {
                    af.append(contentsOf: [UInt8](repeating: 0xFF, count: stuff))
                    afTotal += stuff
                }
            }
            let take = min(184 - afTotal, remaining)
            var pkt: [UInt8] = [0x47, (first ? 0x40 : 0) | UInt8(pid >> 8), UInt8(pid & 0xFF),
                                (afTotal > 0 ? 0x30 : 0x10) | nextCC(pid)]
            if afTotal > 0 { pkt.append(UInt8(afTotal - 1)); pkt.append(contentsOf: af) }
            pkt.append(contentsOf: data[off..<(off + take)])
            out.append(contentsOf: pkt)
            off += take
            first = false
        }
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i) << 24
        for _ in 0..<8 { c = (c & 0x8000_0000) != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1 }
        return c
    }

    static func crc32(_ d: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in d { crc = (crc << 8) ^ crcTable[Int(((crc >> 24) ^ UInt32(b)) & 0xFF)] }
        return crc
    }
}

/// Converts AVCC (NAL length + NAL) to Annex-B (start codes) for MPEG-TS.
enum H264 {
    static func annexB(avcc: Data, sps: Data, pps: Data, keyframe: Bool) -> Data {
        let sc: [UInt8] = [0, 0, 0, 1]
        var out = Data(capacity: avcc.count + sps.count + pps.count + 32)
        out.append(contentsOf: sc + [0x09, 0xF0])   // AUD — Samsung players like it
        if keyframe {
            out.append(contentsOf: sc); out.append(sps)
            out.append(contentsOf: sc); out.append(pps)
        }
        avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 4 <= p.count {
                let n = Int(p[i]) << 24 | Int(p[i + 1]) << 16 | Int(p[i + 2]) << 8 | Int(p[i + 3])
                i += 4
                guard n > 0, i + n <= p.count else { break }
                let type = p[i] & 0x1F
                if type != 9 && !(keyframe && (type == 7 || type == 8)) {
                    out.append(contentsOf: sc)
                    out.append(UnsafeBufferPointer(rebasing: p[i..<(i + n)]))
                }
                i += n
            }
        }
        return out
    }
}
