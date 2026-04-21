import Foundation
import GoogleCast
import ReplayKit
import UIKit
import Darwin

/// React Native native module that bridges the JS layer to the Google Cast SDK
/// and the HLS stream server.
@objc(MirrorBridge)
final class MirrorBridge: RCTEventEmitter {

    private var hasListeners = false

    // Token for Darwin notify registration; -1 = not registered.
    private var broadcastStoppedToken: Int32 = -1
    private var broadcastStartedToken: Int32 = -1

    // MARK: - RCTEventEmitter

    override static func requiresMainQueueSetup() -> Bool { false }

    override func supportedEvents() -> [String] {
        ["onDevicesChanged", "onCastStateChanged", "onScanComplete", "onDebug"]
    }

    override func startObserving() {
        hasListeners = true
    }

    override func stopObserving() {
        hasListeners = false
    }

    // MARK: - JS-callable Methods

    @objc func startDiscovery() {
        DispatchQueue.main.async {
            let ctx = GCKCastContext.sharedInstance()
            ctx.sessionManager.add(self)
            ctx.discoveryManager.add(self)
            ctx.discoveryManager.startDiscovery()
        }
    }

    @objc func stopDiscovery() {
        DispatchQueue.main.async {
            GCKCastContext.sharedInstance().discoveryManager.stopDiscovery()
        }
    }

    @objc func startMirror(
        _ deviceID: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        DispatchQueue.main.async {
            // Confirm the JS→native bridge is alive.
            self.emit("onDebug", body: "start_mirror_called")

            let dm = GCKCastContext.sharedInstance().discoveryManager
            var target: GCKDevice?
            for i in 0..<dm.deviceCount {
                let d = dm.device(at: i)
                if d.deviceID == deviceID { target = d; break }
            }
            guard let device = target else {
                reject("NOT_FOUND", "Chromecast device not found", nil)
                return
            }

            HLSStreamServer.shared.start()

            // Fires once port 9090 is actually bound and ready to accept.
            HLSStreamServer.shared.onListenerReady = { [weak self] in
                self?.emit("onDebug", body: "listener_ready:9090")
            }

            // Fires when the extension's TCP connection is established.
            HLSStreamServer.shared.onExtensionConnected = { [weak self] in
                self?.emit("onDebug", body: "tcp_connected")
            }

            // Fires when the first .ts segment is written to disk.
            // If Cast is already up, load immediately; otherwise didStart handles it.
            HLSStreamServer.shared.onFirstSegmentReady = { [weak self] in
                guard let self else { return }
                self.emit("onDebug", body: "first_segment_ready")
                DispatchQueue.main.async {
                    if let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession {
                        self.loadStream(on: session)
                    }
                    // else: Cast isn't connected yet — didStart will call loadStream
                    // once it connects and finds segmentCount > 0.
                }
            }

            // Belt-and-suspenders stop: TCP control frame from extension.
            HLSStreamServer.shared.onBroadcastStopped = { [weak self] in
                guard let self else { return }
                self.emit("onDebug", body: "stopped_via_tcp")
                self.cancelBroadcastNotifications()
                GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
                HLSStreamServer.shared.stop()
                self.emit("onCastStateChanged", body: ["state": "idle"])
            }

            // Darwin notification stop: fires when user taps iOS stop button.
            var stoppedTok: Int32 = -1
            notify_register_dispatch(
                "com.iosmirror.broadcastStopped", &stoppedTok, .main
            ) { [weak self] _ in
                guard let self else { return }
                self.emit("onDebug", body: "stopped_via_darwin")
                self.cancelBroadcastNotifications()
                GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
                HLSStreamServer.shared.stop()
                self.emit("onCastStateChanged", body: ["state": "idle"])
            }
            self.broadcastStoppedToken = stoppedTok

            // Start Cast and show the broadcast picker at the same time.
            // The picker goes up immediately (no 5-second wait for Cast).
            // Video loads via onFirstSegmentReady (Cast already up) or
            // sessionManager:didStart: (Cast connects after broadcast starts).
            GCKCastContext.sharedInstance().sessionManager.startSession(with: device)
            self.triggerBroadcastPicker()
            
            // Also register for broadcastStarted in case we get killed
            self.registerBroadcastStartedHandler()
            
            resolve(nil)
        }
    }

    // Handle broadcastStarted from extension - restart server if we were killed
    private func registerBroadcastStartedHandler() {
        var startedTok: Int32 = -1
        notify_register_dispatch(
            "com.iosmirror.broadcastStarted", &startedTok, .main
        ) { [weak self] _ in
            guard let self else { return }
            self.emit("onDebug", body: "broadcastStarted_from_extension")
            // Restart HLSStreamServer if needed (app may have been killed)
            if HLSStreamServer.shared.segmentCount == 0 {
                HLSStreamServer.shared.start()
            }
        }
        self.broadcastStartedToken = startedTok
    }

    @objc func stopMirror(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject _: @escaping RCTPromiseRejectBlock
    ) {
        DispatchQueue.main.async {
            self.cancelBroadcastNotifications()
            HLSStreamServer.shared.onBroadcastStopped  = nil
            HLSStreamServer.shared.onFirstSegmentReady = nil
            GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
            HLSStreamServer.shared.stop()
            resolve(nil)
        }
    }

    // MARK: - Helpers

    private func cancelBroadcastNotifications() {
        if broadcastStoppedToken != -1 {
            notify_cancel(broadcastStoppedToken)
            broadcastStoppedToken = -1
        }
        if broadcastStartedToken != -1 {
            notify_cancel(broadcastStartedToken)
            broadcastStartedToken = -1
        }
    }

    private func emit(_ name: String, body: Any) {
        guard hasListeners else { return }
        sendEvent(withName: name, body: body)
    }

    /// Loads the HLS URL on the connected Chromecast session.
    private func loadStream(on session: GCKCastSession) {
        guard let url = HLSStreamServer.shared.streamURL else { return }
        let builder = GCKMediaInformationBuilder(contentURL: url)
        builder.streamType = .live
        builder.contentType = "application/vnd.apple.mpegurl"
        let media = builder.build()
        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = media
        session.remoteMediaClient?.loadMedia(with: request.build())
        emit("onDebug", body: "load_stream_called:\(url)")
    }

    private func installedBroadcastExtensionBundleID() -> String? {
        guard let pluginsURL = Bundle(for: AppDelegate.self).builtInPlugInsURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: pluginsURL, includingPropertiesForKeys: nil)
        else { return nil }
        return urls.first { $0.pathExtension == "appex" }
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// Shows the iOS system broadcast picker so the user can tap "Start Broadcast".
    private func triggerBroadcastPicker() {
        guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = windowScene.windows.first?.rootViewController
        else { return }

        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.preferredExtension = installedBroadcastExtensionBundleID()
        picker.showsMicrophoneButton = false
        rootVC.view.addSubview(picker)

        picker.subviews
            .compactMap { $0 as? UIButton }
            .first?
            .sendActions(for: .touchUpInside)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { picker.removeFromSuperview() }
    }
}

// MARK: - GCKSessionManagerListener

extension MirrorBridge: GCKSessionManagerListener {

    func sessionManager(
        _ sessionManager: GCKSessionManager,
        didStart session: GCKCastSession
    ) {
        emit("onDebug", body: "cast_connected")
        // If the broadcast started before Cast finished connecting,
        // segments are already on disk — load the stream immediately.
        if HLSStreamServer.shared.segmentCount > 0 {
            loadStream(on: session)
        }
        // Otherwise onFirstSegmentReady will call loadStream once segments arrive.
        emit("onCastStateChanged", body: ["state": "mirroring"])
    }

    func sessionManager(
        _ sessionManager: GCKSessionManager,
        didEnd session: GCKCastSession,
        withError error: Error?
    ) {
        emit("onCastStateChanged", body: ["state": "idle"])
    }

    func sessionManager(
        _ sessionManager: GCKSessionManager,
        didFailToStart session: GCKCastSession,
        withError error: Error
    ) {
        cancelBroadcastNotifications()
        HLSStreamServer.shared.onBroadcastStopped  = nil
        HLSStreamServer.shared.onFirstSegmentReady = nil
        HLSStreamServer.shared.stop()
        emit("onCastStateChanged", body: ["state": "idle"])
        emit("onDebug", body: "cast_failed:\(error.localizedDescription)")
    }
}

// MARK: - GCKDiscoveryManagerListener

extension MirrorBridge: GCKDiscoveryManagerListener {

    func didUpdateDeviceList() {
        let dm = GCKCastContext.sharedInstance().discoveryManager
        var list: [[String: String]] = []
        for i in 0..<dm.deviceCount {
            let d = dm.device(at: i)
            list.append([
                "deviceId":  d.deviceID,
                "name":      d.friendlyName ?? d.deviceID,
                "modelName": d.modelName    ?? "Chromecast",
            ])
        }
        emit("onDevicesChanged", body: list)
    }

    func didHaveDiscoveryRequest() {
        // nothing needed
    }

    func discoveryManagerDidStopDiscovery(_ discoveryManager: GCKDiscoveryManager) {
        emit("onScanComplete", body: NSNull())
    }
}
