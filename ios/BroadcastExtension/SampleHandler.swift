import ReplayKit
import VideoToolbox
import Network
import CoreMedia
import Darwin
import os.log
import Foundation

// Import notification functions from Darwin
@_silgen_name("notify_register_dispatch") private func notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ out_token: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @escaping (Int32) -> Void
) -> Int32

@_silgen_name("notify_cancel") private func notify_cancel(_ token: Int32) -> Int32

private let extLogger = OSLog(subsystem: "com.iosmirror.extension", category: "HTTPServer")

// MARK: - VT encoder output callback (file-scope, C-compatible)

private func encoderOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let refCon = outputCallbackRefCon,
          status == noErr,
          let sampleBuffer
    else { return }
    Unmanaged<SampleHandler>.fromOpaque(refCon)
        .takeUnretainedValue()
        .handleEncodedSample(sampleBuffer)
}

// MARK: - SampleHandler
//
// Self-contained broadcast extension:
//   • encodes screen frames to H.264 via VideoToolbox
//   • packetizes to MPEG-TS with TSPacketizer
//   • writes HLS segments to a temp directory
//   • serves the live HLS playlist + segments on port 8080
//
// The main app only manages the Cast session; it never sees the video data.

final class SampleHandler: RPBroadcastSampleHandler {

    // MARK: - Encoder
    private var compressionSession: VTCompressionSession?

    // MARK: - Stop notification
    private var stopBroadcastToken: Int32 = -1

    // MARK: - HLS pipeline
    private var httpListener:     NWListener?
    private var segmentDir:       URL!
    private var packetizer      = TSPacketizer()
    private var segmentData     = Data()
    private var segmentStartPTS: Int64 = Int64.min   // uninitialised sentinel
    private var segmentIndex    = 0
    private var mediaSequence   = 0
    private var segments:         [String] = []
    private var localIP         = "127.0.0.1"

    private let queue = DispatchQueue(label: "com.iosmirror.extension", qos: .userInteractive)

    private let httpPort:        NWEndpoint.Port = 8080
    private let segmentDuration: Double          = 2.0
    private let maxSegments                      = 5

    // MARK: - RPBroadcastSampleHandler

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        setupSegmentDir()
        localIP = detectLocalIP() ?? "127.0.0.1"
        startHTTPServer()
        
        // Listen for stop command from the main app.
        var stopTok: Int32 = -1
        notify_register_dispatch(
            "com.iosmirror.stopBroadcast", &stopTok, queue
        ) { [weak self] _ in
            os_log("Stop broadcast notification received", log: extLogger, type: .info)
            self?.finishBroadcastWithUserStopped()
        }
        self.stopBroadcastToken = stopTok

        // Tell the main app the broadcast is live so it can load the stream on Cast.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.iosmirror.broadcastStarted" as CFString),
            nil, nil, true)
    }

    override func broadcastPaused()  {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        // Clean up stop notification token.
        if stopBroadcastToken != -1 {
            notify_cancel(stopBroadcastToken)
            stopBroadcastToken = -1
        }
        
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.iosmirror.broadcastStopped" as CFString),
            nil, nil, true)

        compressionSession.map { VTCompressionSessionInvalidate($0) }
        compressionSession = nil
        httpListener?.cancel()
        httpListener = nil
    }
    
    // Called when main app sends stopBroadcast notification.
    private func finishBroadcastWithUserStopped() {
        os_log("Finishing broadcast due to user stop", log: extLogger, type: .info)
        
        // Clean up stop notification token.
        if stopBroadcastToken != -1 {
            notify_cancel(stopBroadcastToken)
            stopBroadcastToken = -1
        }
        
        // Post broadcast stopped notification.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.iosmirror.broadcastStopped" as CFString),
            nil, nil, true)
        
        compressionSession.map { VTCompressionSessionInvalidate($0) }
        compressionSession = nil
        httpListener?.cancel()
        httpListener = nil
        
        // This tells the system the broadcast ended.
        let noError: NSError? = nil
        finishBroadcastWithError(noError)
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        if compressionSession == nil {
            setupEncoder(width:  Int32(CVPixelBufferGetWidth(pixelBuffer)),
                         height: Int32(CVPixelBufferGetHeight(pixelBuffer)))
        }

        encodeFrame(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // MARK: - Setup

    private func setupSegmentDir() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls_ext", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in files { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        }
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

    // MARK: - HTTP Server (port 8080, serves to Chromecast directly)

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
        os_log("TCP connected", log: extLogger, type: .info)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, _, _ in
            guard let self, let data,
                  let request = String(data: data, encoding: .utf8)
            else { conn.cancel(); return }
            self.respond(path: self.parsePath(from: request), conn: conn)
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
            sendHTTP(body, contentType: "application/vnd.apple.mpegurl", conn: conn)
        } else if name.hasSuffix(".ts") {
            let file = segmentDir.appendingPathComponent(name)
            if let body = try? Data(contentsOf: file) {
                sendHTTP(body, contentType: "video/mp2t", conn: conn)
            } else {
                send404(conn)
            }
        } else {
            send404(conn)
        }
    }

    private func sendHTTP(_ body: Data, contentType: String, conn: NWConnection) {
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

    // MARK: - VideoToolbox Encoder

    private func setupEncoder(width: Int32, height: Int32) {
        var session: VTCompressionSession?
        let refCon  = Unmanaged.passUnretained(self).toOpaque()
        let status  = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encoderOutputCallback,
            refcon: refCon, compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            finishBroadcastWithError(NSError(
                domain: "IOSMirror", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "VTCompressionSession failed: \(status)"]))
            return
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,                   value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,        value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,                value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,              value: NSNumber(value: 4_000_000))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,           value: NSNumber(value: 30))
        VTCompressionSessionPrepareToEncodeFrames(session)
        compressionSession = session
    }

    private func encodeFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session = compressionSession else { return }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: pts, duration: .invalid,
            frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil
        )
    }

    // MARK: - Encoded Frame Handler (called by C callback above)

    func handleEncodedSample(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil

        var annexB = Data()
        if isKeyframe, let desc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            annexB.append(extractParameterSets(from: desc))
        }

        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        var avccData = Data(count: totalLength)
        _ = avccData.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: totalLength,
                                      destination: $0.baseAddress!)
        }
        annexB.append(avccToAnnexB(avccData))

        let pts90k = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 90_000)
        queue.async { self.handleVideoFrame(annexB, pts90k: pts90k, isKeyframe: isKeyframe) }
    }

    // MARK: - HLS Segmentation (runs on queue)

    private func handleVideoFrame(_ annexB: Data, pts90k: Int64, isKeyframe: Bool) {
        if segmentStartPTS == Int64.min {
            guard isKeyframe else { return }
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

    private func flushSegment() {
        let name = "seg\(segmentIndex).ts"
        try? segmentData.write(to: segmentDir.appendingPathComponent(name), options: .atomic)
        segments.append(name)
        segmentIndex += 1
        segmentData = Data()
        if segments.count > maxSegments {
            let old = segments.removeFirst()
            try? FileManager.default.removeItem(at: segmentDir.appendingPathComponent(old))
            mediaSequence += 1
        }
    }

    // MARK: - Format Helpers

    private func extractParameterSets(from desc: CMFormatDescription) -> Data {
        var result = Data()
        var setCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            desc, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &setCount, nalUnitHeaderLengthOut: nil)
        for i in 0..<setCount {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard st == noErr, let ptr else { continue }
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(UnsafeBufferPointer(start: ptr, count: size))
        }
        return result
    }

    private func avccToAnnexB(_ data: Data) -> Data {
        var result = Data()
        var offset = 0
        while offset + 4 <= data.count {
            let naluLen = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
            }
            offset += 4
            let end = offset + Int(naluLen)
            guard end <= data.count else { break }
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(data[offset..<end])
            offset = end
        }
        return result
    }
}
