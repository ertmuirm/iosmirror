import ReplayKit
import VideoToolbox
import Network
import CoreMedia

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
    private var frameCount:         Int64 = 0

    private let queue = DispatchQueue(label: "com.iosmirror.extension", qos: .userInteractive)

    // MARK: - RPBroadcastSampleHandler

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        connectToHLSServer()
        setupEncoder()
    }

    override func broadcastPaused() {
        sendControl("pause")
    }

    override func broadcastResumed() {
        sendControl("resume")
    }

    override func broadcastFinished() {
        sendControl("stop")
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

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encodeFrame(pixelBuffer, pts: pts)
    }

    // MARK: - Connection

    private func connectToHLSServer() {
        let conn = NWConnection(host: "127.0.0.1", port: 9090, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.scheduleReconnect() }
        }
        conn.start(queue: queue)
        connection = conn
    }

    private func scheduleReconnect() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.connectToHLSServer()
        }
    }

    // MARK: - VideoToolbox Encoder

    private func setupEncoder() {
        // Use native screen resolution; ReplayKit delivers at device scale
        let screenBounds = UIScreen.main.nativeBounds
        let width  = Int32(screenBounds.width)
        let height = Int32(screenBounds.height)

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator:                nil,
            width:                    width,
            height:                   height,
            codecType:                kCMVideoCodecType_H264,
            encoderSpecification:     nil,
            imageBufferAttributes:    nil,
            compressedDataAllocator:  nil,
            outputCallback:           encoderOutputCallback,
            refcon:                   Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut:    &session
        )

        guard status == noErr, let session else {
            finishBroadcastWithError(
                NSError(domain: "IOSMirror", code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create encoder"])
            )
            return
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,                    value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,         value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,                 value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,               value: NSNumber(value: 4_000_000))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,  value: NSNumber(value: 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,            value: NSNumber(value: 30))
        VTCompressionSessionPrepareToEncodeFrames(session)

        compressionSession = session
    }

    private func encodeFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session = compressionSession else { return }
        frameCount += 1
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer:              pixelBuffer,
            presentationTimeStamp:    pts,
            duration:                 .invalid,
            frameProperties:          nil,
            sourceFrameRefcon:        nil,
            infoFlagsOut:             nil
        )
    }

    // MARK: - Encoder Output Callback (C function)

    private let encoderOutputCallback: VTCompressionOutputCallback = { refcon, _, status, flags, sampleBuffer in
        guard status == noErr,
              let sampleBuffer,
              let refcon
        else { return }

        let handler = Unmanaged<SampleHandler>.fromOpaque(refcon).takeUnretainedValue()
        handler.handleEncodedSample(sampleBuffer, flags: flags)
    }

    private func handleEncodedSample(_ sampleBuffer: CMSampleBuffer, flags: VTEncodeInfoFlags) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Detect keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil

        var annexB = Data()

        // Prepend SPS + PPS for keyframes
        if isKeyframe, let desc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            annexB.append(extractParameterSets(from: desc))
        }

        // Convert AVCC length-prefixed NALUs → Annex-B start-code NALUs
        var totalLength = 0
        CMBlockBufferGetDataLength(dataBuffer, &totalLength)   // ← corrected call
        var avccData = Data(count: totalLength)
        avccData.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: totalLength,
                                      destination: $0.baseAddress!)
        }
        annexB.append(avccToAnnexB(avccData))

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsMs = Int64(CMTimeGetSeconds(pts) * 1_000)
        sendFrame(type: 0x01, ptsMs: ptsMs, payload: annexB)
    }

    // MARK: - Format Description → SPS/PPS

    private func extractParameterSets(from desc: CMFormatDescription) -> Data {
        var result = Data()
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            desc, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )
        for i in 0..<count {
            var ptr:  UnsafePointer<UInt8>?
            var size: Int = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            if status == noErr, let ptr {
                result.append(contentsOf: [0, 0, 0, 1])
                result.append(UnsafeBufferPointer(start: ptr, count: size))
            }
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
    //   [0]    type   : UInt8   — 0x01 = video, 0xFF = control
    //   [1..8] pts_ms : Int64   — little-endian
    //   [9..12] length: UInt32  — little-endian

    private func sendFrame(type: UInt8, ptsMs: Int64, payload: Data) {
        guard let conn = connection else { return }
        var header = Data(count: 13)
        header[0] = type
        var pts = ptsMs
        var len = UInt32(payload.count)
        withUnsafeBytes(of: &pts) { header.replaceSubrange(1..<9, with: $0) }
        withUnsafeBytes(of: &len) { header.replaceSubrange(9..<13, with: $0) }
        conn.send(content: header + payload, completion: .idempotent)
    }

    private func sendControl(_ message: String) {
        let payload = message.data(using: .utf8) ?? Data()
        sendFrame(type: 0xFF, ptsMs: 0, payload: payload)
    }
}
