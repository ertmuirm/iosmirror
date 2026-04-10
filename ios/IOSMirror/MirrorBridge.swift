import Foundation
import React
import GoogleCast
import ReplayKit
import UIKit

/// React Native native module that bridges the JS layer to the Google Cast SDK
/// and the HLS stream server.
@objc(MirrorBridge)
final class MirrorBridge: RCTEventEmitter {

    private var hasListeners = false

    // MARK: - RCTEventEmitter

    override static func requiresMainQueueSetup() -> Bool { false }

    override func supportedEvents() -> [String] {
        ["onDevicesChanged", "onCastStateChanged", "onScanComplete"]
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
            GCKCastContext.sharedInstance().sessionManager.startSession(with: device)
            resolve(nil)
        }
    }

    @objc func stopMirror(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject _: @escaping RCTPromiseRejectBlock
    ) {
        DispatchQueue.main.async {
            GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
            HLSStreamServer.shared.stop()
            resolve(nil)
        }
    }

    // MARK: - Helpers

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
    }

    /// Shows the iOS system broadcast picker so the user can tap "Start Broadcast".
    private func triggerBroadcastPicker() {
        guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = windowScene.windows.first?.rootViewController
        else { return }

        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.preferredExtension = "com.iosmirror.BroadcastExtension"
        picker.showsMicrophoneButton = false
        rootVC.view.addSubview(picker)

        // Programmatically trigger the system sheet
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
        loadStream(on: session)
        emit("onCastStateChanged", body: ["state": "mirroring"])
        DispatchQueue.main.async { self.triggerBroadcastPicker() }
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
        HLSStreamServer.shared.stop()
        emit("onCastStateChanged", body: ["state": "idle"])
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
        emit("onScanComplete", body: nil)
    }
}
