import ReplayKit
import VideoToolbox
import Network
import CoreMedia
import os.log

private var extLogger: OSLog?
private func extLog(_ msg: String) {
    if extLogger == nil {
        extLogger = OSLog(subsystem: "com.iosmirror.extension", category: "main")
    }
    os_log("%{public}@", log: extLogger!, type: .default, msg)
    // Write to app group container
    if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.iosmirror") {
        let logFile = containerURL.appendingPathComponent("ext.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(msg)\n"
        if let existing = try? String(contentsOf: logFile, encoding: .utf8) {
            try? (existing + line).write(to: logFile, atomically: true, encoding: .utf8)
        } else {
            try? line.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - C-compatible encoder output callback (must be outside the class)

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
    let handler = Unmanaged<SampleHandler>.fromOpaque(refCon).takeUnretainedValue()
    handler.handleEncodedSample(sampleBuffer, flags: infoFlags)
}

// MARK: - SampleHandler

/// ReplayKit Broadcast Upload Extension entry point.
///
/// Flow:
///   1. broadcastStarted  → connect to HLSStreamServer on 127.0.0.1:9090 → setup H.264 encoder
///   2. processSampleBuffer → encode CVPixelBuffer → send H.264 Annex-B frames over TCP
///   3. broadcastFinished → send stop control message → clean up
final class SampleHandler: RPBroadcastSampleHandler {

    // MARK: - Properties

    private var connection:         NWConnection?
    private var compressionSession: VTCompressionSession?

    private let queue = DispatchQueue(label: "com.iosmirror.extension", qos: .userInteractive)

    // MARK: - RPBroadcastSampleHandler

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        extLog("broadcastStarted CALLED")
        
        // Signal the host app immediately — before TCP even connects — so the
        // Cast session starts as soon as the countdown finishes.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.iosmirror.broadcastStarted" as CFString),
            nil, nil, true)
        extLog("calling connectToHLSServer")
        connectToHLSServer()
        // Encoder is set up lazily on the first video frame so we can use
        // the actual pixel buffer dimensions (UIScreen.main is unavailable
        // in a Broadcast Upload Extension process).
    }

    override func broadcastPaused() {
        sendControl("pause")
    }

    override func broadcastResumed() {
        sendControl("resume")
    }

    override func broadcastFinished() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.iosmirror.broadcastStopped" as CFString),
            nil, nil, true)
        sendControl("stop")   // belt-and-suspenders via TCP
        compressionSession.map { VTCompressionSessionInvalidate($0) }
        compressionSession = nil
        connection?.cancel()
        connection = nil
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        // Set up encoder on first frame using actual buffer dimensions.
        if compressionSession == nil {
            setupEncoder(width:  Int32(CVPixelBufferGetWidth(pixelBuffer)),
                         height: Int32(CVPixelBufferGetHeight(pixelBuffer)))
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encodeFrame(pixelBuffer, pts: pts)
    }

    // MARK: - Connection

    private func connectToHLSServer() {
        extLog("connectToHLSServer: starting TCP to 127.0.0.1:9090")
        let conn = NWConnection(host: "127.0.0.1", port: 9090, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            extLog("TCP state: \(String(describing: state))")
            if case .ready = state {
                extLog("TCP CONNECTED!")
            }
            if case .failed(let err) = state {
                extLog("TCP FAILED: \(err)")
                self?.scheduleReconnect()
            }
            if case .cancelled = state {
                extLog("TCP cancelled")
            }
        }
        conn.start(queue: queue)
        connection = conn
    }

    private func scheduleReconnect() {
        extLog("scheduleReconnect: retrying in 0.5s")
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.connectToHLSServer()
        }
    }

    // MARK: - VideoToolbox Encoder

    private func setupEncoder(width: Int32, height: Int32) {
        var session: VTCompressionSession?
        let refCon = Unmanaged.passUnretained(self).toOpaque()

        let status = VTCompressionSessionCreate(
            allocator:                nil,
            width:                    width,
            height:                   height,
            codecType:                kCMVideoCodecType_H264,
            encoderSpecification:     nil,
            imageBufferAttributes:    nil,
            compressedDataAllocator:  nil,
            outputCallback:           encoderOutputCallback,
            refcon:                   refCon,
            compressionSessionOut:    &session
        )

        guard status == noErr, let session else {
            finishBroadcastWithError(
                NSError(domain: "IOSMirror", code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create VTCompressionSession: \(status)"])
            )
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
            session,
            imageBuffer:           pixelBuffer,
            presentationTimeStamp: pts,
            duration:              .invalid,
            frameProperties:       nil,
            sourceFrameRefcon:     nil,
            infoFlagsOut:          nil
        )
    }

    // MARK: - Encoded Frame Handler (called from C callback above)

    func handleEncodedSample(_ sampleBuffer: CMSampleBuffer, flags: VTEncodeInfoFlags) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Detect keyframe: absence of NotSync attachment means it IS a sync (key) frame
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil

        var annexB = Data()

        // Prepend SPS + PPS for keyframes so the receiver can decode
        if isKeyframe, let desc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            annexB.append(extractParameterSets(from: desc))
        }

        // CMBlockBuffer contains AVCC-format (length-prefixed) NALUs — convert to Annex-B
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        var avccData = Data(count: totalLength)
        avccData.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: totalLength,
                                      destination: $0.baseAddress!)
        }
        annexB.append(avccToAnnexB(avccData))

        let pts    = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsMs  = Int64(CMTimeGetSeconds(pts) * 1_000)
        sendFrame(type: 0x01, ptsMs: ptsMs, payload: annexB)
    }

    // MARK: - Format Description → SPS/PPS (Annex-B)

    private func extractParameterSets(from desc: CMFormatDescription) -> Data {
        var result   = Data()
        var setCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            desc, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &setCount, nalUnitHeaderLengthOut: nil
        )
        for i in 0..<setCount {
            var ptr:  UnsafePointer<UInt8>?
            var size: Int = 0
            let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            guard st == noErr, let ptr else { continue }
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(UnsafeBufferPointer(start: ptr, count: size))
        }
        return result
    }

    // MARK: - AVCC → Annex-B

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

    // MARK: - Wire Protocol

    // Header layout (13 bytes):
    //   [0]     type   : UInt8  — 0x01 = video frame, 0xFF = control
    //   [1..8]  pts_ms : Int64  — little-endian milliseconds
    //   [9..12] length : UInt32 — little-endian payload byte count

    private func sendFrame(type: UInt8, ptsMs: Int64, payload: Data) {
        guard let conn = connection else { return }
        var header = Data(count: 13)
        header[0] = type
        var pts = ptsMs
        var len = UInt32(payload.count)
        withUnsafeBytes(of: &pts) { header.replaceSubrange(1..<9,  with: $0) }
        withUnsafeBytes(of: &len) { header.replaceSubrange(9..<13, with: $0) }
        conn.send(content: header + payload, completion: .idempotent)
    }

    private func sendControl(_ message: String) {
        let payload = message.data(using: .utf8) ?? Data()
        sendFrame(type: 0xFF, ptsMs: 0, payload: payload)
    }
}
