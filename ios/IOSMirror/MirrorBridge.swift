import Foundation
import GoogleCast
import ReplayKit
import UIKit
import Darwin
import os.log

private let logger = OSLog(subsystem: "com.iosmirror.bridge", category: "MirrorBridge")

/// React Native native module that bridges the JS layer to the Google Cast SDK.
/// HLS encoding and serving now live entirely in the BroadcastExtension process.
@objc(MirrorBridge)
final class MirrorBridge: RCTEventEmitter {

    private var hasListeners = false
    private var broadcastStoppedToken: Int32 = -1
    private var broadcastStartedToken: Int32 = -1

    // MARK: - RCTEventEmitter

    override static func requiresMainQueueSetup() -> Bool { false }

    override func supportedEvents() -> [String] {
        ["onDevicesChanged", "onCastStateChanged", "onScanComplete", "onDebug"]
    }

    override func startObserving() { 
        hasListeners = true
        os_log("Started observing events", log: logger, type: .info)
    }
override func stopObserving()  { 
        hasListeners = false
        os_log("Stopped observing events", log: logger, type: .info)
    }

    // MARK: - JS-callable Methods

    @objc func startDiscovery() {
        os_log("startDiscovery called", log: logger, type: .info)
        DispatchQueue.main.async {
            let ctx = GCKCastContext.sharedInstance()
            ctx.sessionManager.add(self)
            ctx.discoveryManager.add(self)
            ctx.discoveryManager.startDiscovery()
            os_log("Discovery started", log: logger, type: .info)
        }
    }

    @objc func stopDiscovery() {
        os_log("stopDiscovery called", log: logger, type: .info)
        DispatchQueue.main.async {
            GCKCastContext.sharedInstance().discoveryManager.stopDiscovery()
        }
    }

    @objc func startMirror(
        _ deviceID: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        os_log("startMirror called for device: %{public}s", log: logger, type: .info, deviceID)
        DispatchQueue.main.async {
            self.emit("onDebug", body: "start_mirror_called")

            let dm = GCKCastContext.sharedInstance().discoveryManager
            var target: GCKDevice?
            for i in 0..<dm.deviceCount {
                let d = dm.device(at: i)
                if d.deviceID == deviceID { target = d; break }
            }
            guard let device = target else {
                os_log("Device not found: %{public}s", log: logger, type: .error, deviceID)
                reject("NOT_FOUND", "Chromecast device not found", nil)
                return
            }

            os_log("Found device: %{public}s", log: logger, type: .info, device.friendlyName ?? deviceID)

            // Listen for the broadcast extension starting.
            var startedTok: Int32 = -1
            notify_register_dispatch(
                "com.iosmirror.broadcastStarted", &startedTok, .main
            ) { [weak self] _ in
                guard let self else { return }
                os_log("broadcastStarted notification received", log: logger, type: .info)
                self.emit("onDebug", body: "broadcast_started_notification")
            }
            self.broadcastStartedToken = startedTok

            // Listen for the broadcast extension stopping.
            var stoppedTok: Int32 = -1
            notify_register_dispatch(
                "com.iosmirror.broadcastStopped", &stoppedTok, .main
            ) { [weak self] _ in
                guard let self else { return }
                os_log("broadcastStopped notification received", log: logger, type: .info)
                self.emit("onDebug", body: "stopped_via_darwin")
                self.cancelBroadcastNotifications()
                GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
                self.emit("onCastStateChanged", body: ["state": "idle"])
            }
            self.broadcastStoppedToken = stoppedTok

            // Start Cast session while app is foregrounded; show picker simultaneously.
            // sessionManager:didStart: immediately sends the HLS URL to Chromecast.
            // The receiver retries fetches until the extension's HTTP server is up.
            os_log("Starting Cast session", log: logger, type: .info)
            self.emit("onDebug", body: "starting_cast_session")
            GCKCastContext.sharedInstance().sessionManager.startSession(with: device)
            
            os_log("Triggering broadcast picker", log: logger, type: .info)
            self.emit("onDebug", body: "triggering_broadcast_picker")
            self.triggerBroadcastPicker()
            
            resolve(nil)
        }
    }

    @objc func stopMirror(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject _: @escaping RCTPromiseRejectBlock
    ) {
        os_log("stopMirror called", log: logger, type: .info)
        DispatchQueue.main.async {
            self.emit("onDebug", body: "stop_mirror_called")
            self.cancelBroadcastNotifications()
            GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
            os_log("Cast session ended", log: logger, type: .info)
            resolve(nil)
        }
    }

    // MARK: - Helpers

    private func cancelBroadcastNotifications() {
        if broadcastStartedToken != -1 {
            notify_cancel(broadcastStartedToken)
            broadcastStartedToken = -1
        }
        if broadcastStoppedToken != -1 {
            notify_cancel(broadcastStoppedToken)
            broadcastStoppedToken = -1
        }
    }

    private func emit(_ name: String, body: Any) {
        guard hasListeners else { return }
        os_log("Emitting event: %{public}s", log: logger, type: .debug, name)
        sendEvent(withName: name, body: body)
    }

    private func loadStream(on session: GCKCastSession) {
        os_log("loadStream called", log: logger, type: .info)
        guard let url = HLSStreamServer.shared.streamURL else {
            os_log("Failed to get stream URL - no IP detected", log: logger, type: .error)
            emit("onDebug", body: "load_stream_no_ip")
            return
        }
        os_log("Loading stream from URL: %{public}s", log: logger, type: .info, url.absoluteString)
        let builder = GCKMediaInformationBuilder(contentURL: url)
        builder.streamType = .live
        builder.contentType = "application/vnd.apple.mpegurl"
        let media = builder.build()
        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = media
        session.remoteMediaClient?.loadMedia(with: request.build())
        emit("onDebug", body: "load_stream:\(url)")
    }

    private func installedBroadcastExtensionBundleID() -> String? {
        guard let pluginsURL = Bundle(for: AppDelegate.self).builtInPlugInsURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: pluginsURL, includingPropertiesForKeys: nil)
        else { return nil }
        return urls.first { $0.pathExtension == "appex" }
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    private func triggerBroadcastPicker() {
        os_log("Triggering system broadcast picker", log: logger, type: .info)
        guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = windowScene.windows.first?.rootViewController
        else { 
            os_log("Failed to find root view controller", log: logger, type: .error)
            return 
        }

        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.preferredExtension = installedBroadcastExtensionBundleID()
        picker.showsMicrophoneButton = false
        rootVC.view.addSubview(picker)

        picker.subviews
            .compactMap { $0 as? UIButton }
            .first?
            .sendActions(for: .touchUpInside)

        os_log("Broadcast picker button tapped", log: logger, type: .info)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { picker.removeFromSuperview() }
    }
}

// MARK: - GCKSessionManagerListener

extension MirrorBridge: GCKSessionManagerListener {

    func sessionManager(
        _ sessionManager: GCKSessionManager,
        didStart session: GCKCastSession
    ) {
        os_log("Cast session started", log: logger, type: .info)
        emit("onDebug", body: "cast_connected")
        // Load the extension's URL immediately. The Chromecast receiver will
        // retry until the extension's HTTP server comes up on port 8080.
        loadStream(on: session)
        emit("onCastStateChanged", body: ["state": "mirroring"])
    }

    func sessionManager(
        _ sessionManager: GCKSessionManager,
        didEnd session: GCKCastSession,
        withError error: Error?
    ) {
        os_log("Cast session ended: %{public}s", log: logger, type: .info, error?.localizedDescription ?? "no error")
        emit("onCastStateChanged", body: ["state": "idle"])
    }

    func sessionManager(
        _ sessionManager: GCKSessionManager,
        didFailToStart session: GCKCastSession,
        withError error: Error
    ) {
        os_log("Cast session failed to start: %{public}s", log: logger, type: .error, error.localizedDescription)
        cancelBroadcastNotifications()
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
        os_log("Device list updated: %d devices", log: logger, type: .info, list.count)
        emit("onDevicesChanged", body: list)
    }

    func didHaveDiscoveryRequest() {}

    func discoveryManagerDidStopDiscovery(_ discoveryManager: GCKDiscoveryManager) {
        os_log("Discovery stopped", log: logger, type: .info)
        emit("onScanComplete", body: NSNull())
    }
}
