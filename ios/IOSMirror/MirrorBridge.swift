import Foundation
import GoogleCast
import ReplayKit
import UIKit
import Darwin

/// React Native native module that bridges the JS layer to the Google Cast SDK.
/// HLS encoding and serving now live entirely in the BroadcastExtension process.
@objc(MirrorBridge)
final class MirrorBridge: RCTEventEmitter {

    private var hasListeners = false
    private var broadcastStoppedToken: Int32 = -1

    // MARK: - RCTEventEmitter

    override static func requiresMainQueueSetup() -> Bool { false }

    override func supportedEvents() -> [String] {
        ["onDevicesChanged", "onCastStateChanged", "onScanComplete", "onDebug"]
    }

    override func startObserving() { hasListeners = true  }
    override func stopObserving()  { hasListeners = false }

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

            // Listen for the broadcast extension stopping.
            var stoppedTok: Int32 = -1
            notify_register_dispatch(
                "com.iosmirror.broadcastStopped", &stoppedTok, .main
            ) { [weak self] _ in
                guard let self else { return }
                self.emit("onDebug", body: "stopped_via_darwin")
                self.cancelBroadcastNotifications()
                GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
                self.emit("onCastStateChanged", body: ["state": "idle"])
            }
            self.broadcastStoppedToken = stoppedTok

            // Start Cast session while app is foregrounded; show picker simultaneously.
            // sessionManager:didStart: immediately sends the HLS URL to Chromecast.
            // The receiver retries fetches until the extension's HTTP server is up.
            GCKCastContext.sharedInstance().sessionManager.startSession(with: device)
            self.triggerBroadcastPicker()
            resolve(nil)
        }
    }

    @objc func stopMirror(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject _: @escaping RCTPromiseRejectBlock
    ) {
        DispatchQueue.main.async {
            self.cancelBroadcastNotifications()
            GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
            resolve(nil)
        }
    }

    // MARK: - Helpers

    private func cancelBroadcastNotifications() {
        if broadcastStoppedToken != -1 {
            notify_cancel(broadcastStoppedToken)
            broadcastStoppedToken = -1
        }
    }

    private func emit(_ name: String, body: Any) {
        guard hasListeners else { return }
        sendEvent(withName: name, body: body)
    }

    private func loadStream(on session: GCKCastSession) {
        guard let url = HLSStreamServer.shared.streamURL else {
            emit("onDebug", body: "load_stream_no_ip")
            return
        }
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
        emit("onCastStateChanged", body: ["state": "idle"])
    }

    func sessionManager(
        _ sessionManager: GCKSessionManager,
        didFailToStart session: GCKCastSession,
        withError error: Error
    ) {
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
        emit("onDevicesChanged", body: list)
    }

    func didHaveDiscoveryRequest() {}

    func discoveryManagerDidStopDiscovery(_ discoveryManager: GCKDiscoveryManager) {
        emit("onScanComplete", body: NSNull())
    }
}
