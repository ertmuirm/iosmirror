import Foundation

// MARK: - MPEG-TS Constants

private enum PID {
    static let pat:   UInt16 = 0x0000
    static let pmt:   UInt16 = 0x1000
    static let video: UInt16 = 0x0100
}

private let tsPacketSize = 188
private let tsHeaderSize = 4

// MARK: - TSPacketizer

/// Produces MPEG-TS packets suitable for HLS .ts segments.
///
/// Usage:
///   1. Call `makeSegmentHeader()` once at the start of each segment.
///   2. For each H.264 Annex-B frame call `makeVideoPackets(_:pts:isKeyframe:)`.
///   3. Accumulate the returned Data and write to a .ts file.
final class TSPacketizer {

    private var videoContinuity: UInt8 = 0
    private var patContinuity:   UInt8 = 0
    private var pmtContinuity:   UInt8 = 0

    // Last known SPS/PPS in Annex-B form (start-code + NALU)
    private var spsAnnexB: Data?
    private var ppsAnnexB: Data?

    // MARK: - Public API

    /// Returns PAT + PMT TS packets to open a segment.
    func makeSegmentHeader() -> Data {
        makePAT() + makePMT()
    }

    /// Parses Annex-B `data`, caches SPS/PPS, and returns TS packets.
    func makeVideoPackets(_ data: Data, pts: Int64, isKeyframe: Bool) -> Data {
        // Cache SPS / PPS from the stream
        parseParameterSets(from: data)

        var pesPayload = Data()

        if isKeyframe {
            if let sps = spsAnnexB { pesPayload.append(sps) }
            if let pps = ppsAnnexB { pesPayload.append(pps) }
        }
        pesPayload.append(data)

        let pes = buildPES(payload: pesPayload, pts: pts, streamID: 0xE0)
        return tsPackets(pid: PID.video, payload: pes, continuity: &videoContinuity, pusi: true)
    }

    // MARK: - Parameter Set Parsing

    private func parseParameterSets(from data: Data) {
        forEachNALU(in: data) { startCode, nalu in
            let nalType = nalu.first.map { $0 & 0x1F } ?? 0
            if nalType == 7 { spsAnnexB = startCode + nalu }
            if nalType == 8 { ppsAnnexB = startCode + nalu }
        }
    }

    /// Iterates Annex-B start-code delimited NALUs.
    private func forEachNALU(in data: Data, body: (Data, Data) -> Void) {
        var i = 0
        let startCode3: [UInt8] = [0, 0, 1]
        let startCode4: [UInt8] = [0, 0, 0, 1]

        while i < data.count {
            // Find next start code
            var scLen = 0
            if i + 3 < data.count && data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1 {
                scLen = 4
            } else if i + 2 < data.count && data[i] == 0 && data[i+1] == 0 && data[i+2] == 1 {
                scLen = 3
            } else {
                i += 1
                continue
            }

            let naluStart = i + scLen
            // Find where this NALU ends (next start code or EOF)
            var naluEnd = naluStart + 1
            while naluEnd + 2 < data.count {
                if data[naluEnd] == 0 && data[naluEnd+1] == 0 {
                    if naluEnd + 3 < data.count && data[naluEnd+2] == 1 { break }
                    if naluEnd + 3 < data.count && data[naluEnd+2] == 0 && data[naluEnd+3] == 1 { break }
                }
                naluEnd += 1
            }
            if naluEnd + 2 >= data.count { naluEnd = data.count }

            let sc = scLen == 4 ? Data(startCode4) : Data(startCode3)
            body(sc, data[naluStart..<naluEnd])
            i = naluEnd
        }
    }

    // MARK: - PAT

    private func makePAT() -> Data {
        var section = Data()
        section.append(contentsOf: [
            0x00,               // pointer field
            0x00,               // table_id = PAT
            0xB0, 0x0D,         // section_syntax_indicator=1, length=13
            0x00, 0x01,         // transport_stream_id
            0xC1,               // version=0, current_next=1
            0x00,               // section_number
            0x00,               // last_section_number
            0x00, 0x01,         // program_number=1
        ])
        // PMT PID
        let pmtPID = PID.pmt
        section.append(UInt8(0xE0 | ((pmtPID >> 8) & 0x1F)))
        section.append(UInt8(pmtPID & 0xFF))
        // CRC32 over bytes after pointer field
        let crc = crc32MPEG(section.dropFirst())
        section.append(contentsOf: crcBytes(crc))

        return tsPackets(pid: PID.pat, payload: section, continuity: &patContinuity, pusi: true)
    }

    // MARK: - PMT

    private func makePMT() -> Data {
        var section = Data()
        section.append(contentsOf: [
            0x00,               // pointer field
            0x02,               // table_id = PMT
            0xB0, 0x12,         // section_syntax_indicator=1, length=18
            0x00, 0x01,         // program_number
            0xC1,               // version=0, current_next=1
            0x00,               // section_number
            0x00,               // last_section_number
        ])
        // PCR PID
        let videoPID = PID.video
        section.append(UInt8(0xE0 | ((videoPID >> 8) & 0x1F)))
        section.append(UInt8(videoPID & 0xFF))
        section.append(contentsOf: [0xF0, 0x00])   // program_info_length=0
        // Stream descriptor: H.264 video
        section.append(0x1B)                         // stream_type = AVC
        section.append(UInt8(0xE0 | ((videoPID >> 8) & 0x1F)))
        section.append(UInt8(videoPID & 0xFF))
        section.append(contentsOf: [0xF0, 0x00])    // ES_info_length=0
        let crc = crc32MPEG(section.dropFirst())
        section.append(contentsOf: crcBytes(crc))

        return tsPackets(pid: PID.pmt, payload: section, continuity: &pmtContinuity, pusi: true)
    }

    // MARK: - PES

    private func buildPES(payload: Data, pts: Int64, streamID: UInt8) -> Data {
        var pes = Data()
        // start code
        pes.append(contentsOf: [0x00, 0x00, 0x01, streamID])
        // PES packet length (0 = unbounded, valid for video)
        pes.append(contentsOf: [0x00, 0x00])
        // flags: PTS present
        pes.append(contentsOf: [0x80, 0x80, 0x05])
        // PTS (90 kHz)
        pes.append(contentsOf: encodePTS(pts))
        pes.append(payload)
        return pes
    }

    // MARK: - TS Packetization

    private func tsPackets(
        pid: UInt16,
        payload: Data,
        continuity: inout UInt8,
        pusi: Bool
    ) -> Data {
        var result = Data()
        var offset = 0
        var firstPacket = pusi

        while offset < payload.count {
            var packet = Data(repeating: 0xFF, count: tsPacketSize)
            packet[0] = 0x47    // sync byte

            let pusiFlag: UInt8 = firstPacket ? 0x40 : 0x00
            packet[1] = pusiFlag | UInt8((pid >> 8) & 0x1F)
            packet[2] = UInt8(pid & 0xFF)

            let payloadAvailable = tsPacketSize - tsHeaderSize
            let remaining = payload.count - offset

            if remaining >= payloadAvailable {
                // Payload-only packet
                packet[3] = 0x10 | (continuity & 0x0F)
                packet.replaceSubrange(4..<tsPacketSize, with: payload[offset..<(offset + payloadAvailable)])
                offset += payloadAvailable
            } else {
                // Need adaptation field for stuffing
                let stuffBytes = payloadAvailable - remaining  // always >= 1 (adaptation field header)
                packet[3] = 0x30 | (continuity & 0x0F)
                if stuffBytes == 1 {
                    // Adaptation field length byte only, no flags
                    packet[4] = 0x00
                } else {
                    packet[4] = UInt8(stuffBytes - 1)   // adaptation_field_length
                    packet[5] = 0x00                    // no flags, rest is 0xFF stuffing
                    // bytes 6..(4+stuffBytes) are already 0xFF from initializer
                }
                let payloadStart = 4 + stuffBytes
                packet.replaceSubrange(payloadStart..<tsPacketSize, with: payload[offset...])
                offset = payload.count
            }

            continuity = (continuity + 1) & 0x0F
            result.append(packet)
            firstPacket = false
        }

        return result
    }

    // MARK: - Utilities

    private func encodePTS(_ pts: Int64) -> [UInt8] {
        // 5-byte PTS with marker bits
        let p = pts
        return [
            0x21 | UInt8((p >> 29) & 0x0E),
            UInt8((p >> 22) & 0xFF),
            0x01 | UInt8((p >> 14) & 0xFE),
            UInt8((p >> 7)  & 0xFF),
            0x01 | UInt8((p << 1)  & 0xFE),
        ]
    }

    private func crc32MPEG(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0
                    ? (crc << 1) ^ 0x04C1_1DB7
                    : crc << 1
            }
        }
        return crc
    }

    private func crcBytes(_ crc: UInt32) -> [UInt8] {
        [
            UInt8((crc >> 24) & 0xFF),
            UInt8((crc >> 16) & 0xFF),
            UInt8((crc >>  8) & 0xFF),
            UInt8( crc        & 0xFF),
        ]
    }
}
