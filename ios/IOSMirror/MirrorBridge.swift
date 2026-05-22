import Foundation
import GoogleCast
import ReplayKit
import UIKit
import Darwin

/// React Native native module that bridges the JS layer to the Google Cast SDK
/// and to DLNA/UPnP renderers (Samsung AllShare / Screen Mirror and compatible TVs).
@objc(MirrorBridge)
final class MirrorBridge: RCTEventEmitter {

    private var hasListeners = false

    // Held until "broadcastStarted" Darwin notification fires.
    private var pendingDevice:     GCKDevice?
    private var pendingDLNADevice: DLNADevice?

    // Background task so Cast / DLNA can connect while the app is backgrounded.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // Tokens for Darwin notify registrations; -1 = not registered.
    private var broadcastStartedToken: Int32 = -1
    private var broadcastStoppedToken:  Int32 = -1

    // DLNA support
    private let dlnaDiscovery = DLNADiscovery()
    private var dlnaSession:        DLNASession?
    private var dlnaDeviceRegistry: [String: DLNADevice] = [:]

    // Cached Cast device list so we can merge with DLNA devices on every update.
    private var castDeviceList: [[String: String]] = []

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

        dlnaDiscovery.onUpdate = { [weak self] devices in
            guard let self else { return }
            self.dlnaDeviceRegistry = Dictionary(
                uniqueKeysWithValues: devices.map { ($0.id, $0) })
            self.emitMergedDeviceList()
        }
        dlnaDiscovery.onDebug = { [weak self] msg in
            self?.emit("onDebug", body: msg)
        }
        dlnaDiscovery.start()
    }

    @objc func stopDiscovery() {
        DispatchQueue.main.async {
            GCKCastContext.sharedInstance().discoveryManager.stopDiscovery()
        }
        dlnaDiscovery.stop()
    }

    @objc func startMirror(
        _ deviceID: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        DispatchQueue.main.async {
            self.emit("onDebug", body: "start_mirror_called")

            if let dlnaDevice = self.dlnaDeviceRegistry[deviceID] {
                self.startDLNAMirror(dlnaDevice, resolve: resolve, reject: reject)
            } else {
                self.startCastMirror(deviceID, resolve: resolve, reject: reject)
            }
        }
    }

    @objc func stopMirror(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject _: @escaping RCTPromiseRejectBlock
    ) {
        DispatchQueue.main.async {
            self.pendingDevice     = nil
            self.pendingDLNADevice = nil
            self.cancelBroadcastNotifications()
            self.endBackgroundTask()

            if self.dlnaSession != nil {
                self.dlnaSession?.stop { _ in }
                self.dlnaSession = nil
            } else {
                GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
            }
            // When a broadcast is active this picker shows "Stop Broadcast".
            self.triggerBroadcastPicker()
            resolve(nil)
        }
    }

    // MARK: - Cast path

    private func startCastMirror(
        _ deviceID: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
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
        pendingDevice = device
        registerBroadcastNotifications()
        triggerBroadcastPicker()
        resolve(nil)
    }

    // MARK: - DLNA path

    private func startDLNAMirror(
        _ device: DLNADevice,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        pendingDLNADevice = device
        registerBroadcastNotifications()
        triggerBroadcastPicker()
        resolve(nil)
    }

    private func connectDLNA(device: DLNADevice) {
        guard let url = HLSStreamServer.shared.streamURL else {
            emit("onDebug", body: "dlna_no_ip")
            endBackgroundTask()
            emit("onCastStateChanged", body: ["state": "idle"])
            return
        }
        let session = DLNASession(controlURL: device.controlURL)
        dlnaSession = session
        emit("onDebug", body: "dlna_connecting:\(url):ctrl=\(device.controlURL)")
        session.loadAndPlay(url) { [weak self] err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundTask()
                if let err {
                    self.dlnaSession = nil
                    self.emit("onDebug", body: "dlna_error:\(err.localizedDescription)")
                    self.emit("onCastStateChanged", body: ["state": "idle"])
                } else {
                    self.emit("onDebug", body: "dlna_playing")
                    self.emit("onCastStateChanged", body: ["state": "mirroring"])
                }
            }
        }
    }

    // MARK: - Shared broadcast notification handling

    private func registerBroadcastNotifications() {
        cancelBroadcastNotifications()

        // "broadcastStarted" fires after the 3-second countdown ends —
        // the extension's HTTP server is already listening at this point.
        var startedTok: Int32 = -1
        notify_register_dispatch(
            "com.iosmirror.broadcastStarted", &startedTok, .main
        ) { [weak self] _ in
            guard let self else { return }
            self.emit("onDebug", body: "broadcast_started_received")
            self.backgroundTaskID = UIApplication.shared.beginBackgroundTask {
                self.endBackgroundTask()
            }
            if let device = self.pendingDevice {
                self.pendingDevice = nil
                GCKCastContext.sharedInstance().sessionManager.startSession(with: device)
            } else if let dlnaDevice = self.pendingDLNADevice {
                self.pendingDLNADevice = nil
                self.connectDLNA(device: dlnaDevice)
            }
        }
        broadcastStartedToken = startedTok

        // "broadcastStopped" fires when the user taps the iOS stop button.
        var stoppedTok: Int32 = -1
        notify_register_dispatch(
            "com.iosmirror.broadcastStopped", &stoppedTok, .main
        ) { [weak self] _ in
            guard let self else { return }
            self.emit("onDebug", body: "stopped_via_darwin")
            self.cancelBroadcastNotifications()
            self.endBackgroundTask()
            if self.dlnaSession != nil {
                self.dlnaSession?.stop { _ in }
                self.dlnaSession = nil
            } else {
                GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
            }
            self.emit("onCastStateChanged", body: ["state": "idle"])
        }
        broadcastStoppedToken = stoppedTok
    }

    // MARK: - Helpers

    private func emitMergedDeviceList() {
        var list = castDeviceList
        for device in dlnaDeviceRegistry.values {
            list.append([
                "deviceId":  device.id,
                "name":      device.name,
                "modelName": device.manufacturer,
                "type":      "dlna",
            ])
        }
        emit("onDevicesChanged", body: list)
    }

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

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
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
        // The extension has been running for ~5 s by now, so at least
        // one HLS segment exists. Load immediately for fast video start.
        emit("onDebug", body: "cast_connected")
        loadStream(on: session)
        endBackgroundTask()
        emit("onCastStateChanged", body: ["state": "mirroring"])
    }

    func sessionManager(
        _ sessionManager: GCKSessionManager,
        didEnd session: GCKCastSession,
        withError error: Error?
    ) {
        endBackgroundTask()
        emit("onCastStateChanged", body: ["state": "idle"])
    }

    func sessionManager(
        _ sessionManager: GCKSessionManager,
        didFailToStart session: GCKCastSession,
        withError error: Error
    ) {
        cancelBroadcastNotifications()
        endBackgroundTask()
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
                "type":      "cast",
            ])
        }
        castDeviceList = list
        emitMergedDeviceList()
    }

    func didHaveDiscoveryRequest() {}

    func discoveryManagerDidStopDiscovery(_ discoveryManager: GCKDiscoveryManager) {
        emit("onScanComplete", body: NSNull())
    }
}
