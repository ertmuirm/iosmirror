import Foundation
import Network
import CoreMedia
import Darwin

// MARK: - HLSStreamServer

/// Dual-purpose server:
///   - TCP port 9090  : receives encoded H.264 NAL units from BroadcastExtension
///   - HTTP port 8080 : serves live HLS playlist + .ts segments to Chromecast
final class HLSStreamServer {

    static let shared = HLSStreamServer()

    // MARK: - Configuration

    private let extensionPort: NWEndpoint.Port = 9090
    private let httpPort:      NWEndpoint.Port = 8080
    private let segmentDuration: Double = 2.0
    private let maxSegments      = 5

    // MARK: - State

    private(set) var streamURL: URL?
    private(set) var segmentCount = 0   // incremented each time a segment is flushed
    var onExtensionConnected: (() -> Void)?
    var onFirstSegmentReady:  (() -> Void)?
    var onBroadcastStopped:   (() -> Void)?

    private var httpListener:      NWListener?
    private var extensionListener: NWListener?

    private var segmentDir:    URL!
    private var packetizer  = TSPacketizer()
    private var segmentData = Data()
    private var segmentStartPTS: Int64 = Int64.min   // 90 kHz ticks; min = uninitialised
    private var segmentIndex   = 0
    private var mediaSequence  = 0
    private var segments:      [String] = []         // filename of each ready segment

    private var receiveBuffer = Data()
    private var localIP = "127.0.0.1"

    private let queue = DispatchQueue(label: "com.iosmirror.hls", qos: .userInteractive)

    private init() {
        setupSegmentDir()
    }

    // MARK: - Lifecycle

    func start() {
        // Re-detect every session so we pick up IP changes (DHCP renewal, etc.)
        localIP = detectLocalIP() ?? "127.0.0.1"
        streamURL = URL(string: "http://\(localIP):\(httpPort)/stream/index.m3u8")
        startExtensionServer()
        startHTTPServer()
    }

    func stop() {
        extensionListener?.cancel()
        httpListener?.cancel()
        extensionListener = nil
        httpListener      = nil
        queue.async { self.clearSegments() }
    }

    // MARK: - Setup

    private func setupSegmentDir() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls_segments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        segmentDir = dir
    }

    private func detectLocalIP() -> String? {
        var addr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addr) == 0 else { return nil }
        defer { freeifaddrs(addr) }
        var ptr = addr
        while let p = ptr {
            let sa = p.pointee.ifa_addr!
            if sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: p.pointee.ifa_name)
                if name == "en0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    return String(cString: host)
                }
            }
            ptr = p.pointee.ifa_next
        }
        return nil
    }

    // MARK: - Extension TCP Listener (port 9090)

    private func startExtensionServer() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true   // SO_REUSEADDR: safe to rebind after stop
        guard let listener = try? NWListener(using: params, on: extensionPort) else { return }
        extensionListener = listener
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .global())
            self?.receiveLoop(conn)
            if let cb = self?.onExtensionConnected {
                self?.onExtensionConnected = nil
                DispatchQueue.main.async { cb() }
            }
        }
        listener.start(queue: queue)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, err in
            guard let self else { return }
            if let data, !data.isEmpty { self.receiveBuffer.append(data) }
            self.drainBuffer()
            if err == nil { self.receiveLoop(conn) }
        }
    }

    // Frame wire format (from SampleHandler):
    //   type   : UInt8   — 0x01 = video, 0xFF = control
    //   pts_ms : Int64   — presentation timestamp in milliseconds
    //   length : UInt32  — payload byte count
    //   payload: [UInt8]

    private func drainBuffer() {
        let headerSize = 13   // 1 + 8 + 4
        while receiveBuffer.count >= headerSize {
            let type = receiveBuffer[0]
            let ptsMs = receiveBuffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: Int64.self) }
            let length = receiveBuffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 9, as: UInt32.self) }
            let total = headerSize + Int(length)
            guard receiveBuffer.count >= total else { break }

            let payload = receiveBuffer.subdata(in: headerSize..<total)
            receiveBuffer.removeFirst(total)

            if type == 0x01 {
                let pts90k = ptsMs * 90   // ms → 90 kHz ticks
                handleVideoFrame(payload, pts90k: pts90k)
            } else if type == 0xFF {
                if String(data: payload, encoding: .utf8) == "stop" {
                    let cb = onBroadcastStopped
                    onBroadcastStopped = nil
                    DispatchQueue.main.async { cb?() }
                }
            }
        }
    }

    // MARK: - HLS Segmentation

    private func handleVideoFrame(_ annexB: Data, pts90k: Int64) {
        // Detect keyframe (IDR, NAL type 5)
        let isKeyframe = containsIDR(annexB)

        if segmentStartPTS == Int64.min {
            guard isKeyframe else { return }   // wait for first IDR
            segmentStartPTS = pts90k
            segmentData.append(packetizer.makeSegmentHeader())
        }

        let elapsed = Double(pts90k - segmentStartPTS) / 90_000.0
        if elapsed >= segmentDuration && isKeyframe {
            flushSegment()
            segmentStartPTS = pts90k
            segmentData.append(packetizer.makeSegmentHeader())
        }

        segmentData.append(packetizer.makeVideoPackets(annexB, pts: pts90k, isKeyframe: isKeyframe))
    }

    private func containsIDR(_ annexB: Data) -> Bool {
        var i = 0
        while i + 4 < annexB.count {
            if annexB[i] == 0 && annexB[i+1] == 0 {
                let sc4 = annexB[i+2] == 0 && annexB[i+3] == 1
                let sc3 = annexB[i+2] == 1
                let naluByte: UInt8
                if sc4 && i + 4 < annexB.count { naluByte = annexB[i+4] }
                else if sc3 && i + 3 < annexB.count { naluByte = annexB[i+3] }
                else { i += 1; continue }
                if naluByte & 0x1F == 5 { return true }
            }
            i += 1
        }
        return false
    }

    private func flushSegment() {
        let name = "seg\(segmentIndex).ts"
        let path = segmentDir.appendingPathComponent(name)
        try? segmentData.write(to: path, options: .atomic)
        segments.append(name)
        segmentIndex += 1
        segmentCount += 1
        segmentData = Data()

        if segmentCount == 1 {
            let cb = onFirstSegmentReady
            onFirstSegmentReady = nil
            DispatchQueue.main.async { cb?() }
        }

        if segments.count > maxSegments {
            let old = segments.removeFirst()
            try? FileManager.default.removeItem(at: segmentDir.appendingPathComponent(old))
            mediaSequence += 1
        }
    }

    private func clearSegments() {
        for name in segments {
            try? FileManager.default.removeItem(at: segmentDir.appendingPathComponent(name))
        }
        segments.removeAll()
        segmentData = Data()
        segmentIndex = 0
        mediaSequence = 0
        segmentStartPTS = Int64.min
        receiveBuffer = Data()
        packetizer = TSPacketizer()
        segmentCount         = 0
        onExtensionConnected = nil
        onFirstSegmentReady  = nil
        onBroadcastStopped   = nil
    }

    // MARK: - HTTP Server (port 8080)

    private func startHTTPServer() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: httpPort) else { return }
        httpListener = listener
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .global())
            self?.serveHTTP(conn)
        }
        listener.start(queue: queue)
    }

    private func serveHTTP(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, _, _ in
            guard let self, let data,
                  let request = String(data: data, encoding: .utf8)
            else { conn.cancel(); return }

            let path = self.parsePath(from: request)
            self.respond(path: path, conn: conn)
        }
    }

    private func parsePath(from request: String) -> String {
        guard let line = request.split(separator: "\n").first else { return "/" }
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : "/"
    }

    private func respond(path: String, conn: NWConnection) {
        let name = (path as NSString).lastPathComponent

        if name == "index.m3u8" {
            let body = buildPlaylist().data(using: .utf8) ?? Data()
            send(body, contentType: "application/vnd.apple.mpegurl", conn: conn)

        } else if name.hasSuffix(".ts") {
            let file = segmentDir.appendingPathComponent(name)
            if let body = try? Data(contentsOf: file) {
                send(body, contentType: "video/mp2t", conn: conn)
            } else {
                send404(conn)
            }

        } else {
            send404(conn)
        }
    }

    private func send(_ body: Data, contentType: String, conn: NWConnection) {
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Access-Control-Allow-Origin: *",
            "Cache-Control: no-cache, no-store",
            "Connection: close",
            "", "",
        ].joined(separator: "\r\n")
        var response = header.data(using: .utf8)!
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func send404(_ conn: NWConnection) {
        let msg = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: msg.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - HLS Playlist

    private func buildPlaylist() -> String {
        var m3u8  = "#EXTM3U\n"
        m3u8     += "#EXT-X-VERSION:3\n"
        m3u8     += "#EXT-X-TARGETDURATION:\(Int(segmentDuration) + 1)\n"
        m3u8     += "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)\n"
        for name in segments {
            m3u8 += "#EXTINF:\(segmentDuration),\n"
            m3u8 += "http://\(localIP):\(httpPort)/stream/\(name)\n"
        }
        return m3u8
    }
}
