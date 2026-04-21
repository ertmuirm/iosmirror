import Foundation
import GoogleCast
import ReplayKit
import UIKit

// Import Darwin notification functions for communicating with broadcast extension.
// These are used to receive broadcastStarted, firstSegmentReady, and broadcastStopped signals.
@_silgen_name("notify_register_dispatch") private func notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ out_token: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @escaping (Int32) -> Void
) -> Int32

@_silgen_name("notify_cancel") private func notify_cancel(_ token: Int32) -> Int32

/// React Native native module that bridges the JS layer to the Google Cast SDK
/// and the HLS stream server.
/// Note: Extension now runs its own HTTP server and provides the stream URL
/// via UserDefaults (App Group) and Darwin notifications.
@objc(MirrorBridge)
final class MirrorBridge: RCTEventEmitter {

    private var hasListeners = false

    // Token for Darwin notify registration; -1 = not registered.
    private var broadcastStoppedToken: Int32 = -1
    private var firstSegmentToken: Int32 = -1

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

            // Extension runs its own HTTP server - we just listen for first segment ready.
            // Register for firstSegmentReady notification from extension.
            var segmentTok: Int32 = -1
            notify_register_dispatch(
                "com.iosmirror.firstSegmentReady", &segmentTok, .main
            ) { [weak self] _ in
                guard let self else { return }
                self.emit("onDebug", body: "first_segment_ready")
                // Get stream URL from extension via App Group
                let sharedDefaults = UserDefaults(suiteName: "group.com.iosmirror")
                if let urlString = sharedDefaults?.string(forKey: "streamURL"),
                   let url = URL(string: urlString) {
                    // Load stream on Cast session
                    if let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession {
                        self.loadStreamURL(url, on: session)
                    } else {
                        // Cast not connected yet - wait for didStart
                        // Store URL for sessionManager:didStart to use
                        self.pendingStreamURL = url
                    }
                }
            }
            self.firstSegmentToken = segmentTok

            // Register for broadcast stopped notification (from extension or iOS stop button).
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

            // Start Cast session - the picker will trigger the broadcast.
            GCKCastContext.sharedInstance().sessionManager.startSession(with: device)
            self.triggerBroadcastPicker()
            resolve(nil)
        }
    }

    /// Pending stream URL waiting for Cast to connect.
    private var pendingStreamURL: URL?

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
        if firstSegmentToken != -1 {
            notify_cancel(firstSegmentToken)
            firstSegmentToken = -1
        }
    }

    private func emit(_ name: String, body: Any) {
        guard hasListeners else { return }
        sendEvent(withName: name, body: body)
    }

    /// Loads the HLS URL on the connected Chromecast session.
    /// Loads a stream URL into Cast (new extension-based version).
    private func loadStreamURL(_ url: URL, on session: GCKCastSession) {
        let builder = GCKMediaInformationBuilder(contentURL: url)
        builder.streamType = .live
        builder.contentType = "application/vnd.apple.mpegurl"
        let media = builder.build()
        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = media
        session.remoteMediaClient?.loadMedia(with: request.build())
        emit("onDebug", body: "load_stream_called:\(url)")
    }

    /// Loads stream URL from local HLSStreamServer (legacy version).
    private func loadStream(on session: GCKCastSession) {
        guard let url = HLSStreamServer.shared.streamURL else { return }
        loadStreamURL(url, on: session)
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
        // Check if we have a pending stream URL from extension
        if let url = pendingStreamURL {
            pendingStreamURL = nil
            loadStreamURL(url, on: session)
        }
        // Otherwise check if extension already wrote a stream URL
        let sharedDefaults = UserDefaults(suiteName: "group.com.iosmirror")
        if let urlString = sharedDefaults?.string(forKey: "streamURL"),
           let url = URL(string: urlString) {
            loadStreamURL(url, on: session)
        }
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
        pendingStreamURL = nil
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
