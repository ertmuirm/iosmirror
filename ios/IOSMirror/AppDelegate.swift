import UIKit
import GoogleCast
import React_RCTAppDelegate

@main
final class AppDelegate: RCTAppDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        moduleName = "IOSMirror"
        initialProps = [:]

        setupGoogleCast()

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func sourceURL(for bridge: RCTBridge!) -> URL! {
        bundleURL()
    }

    override func bundleURL() -> URL! {
#if DEBUG
        RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
#else
        Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
    }

    // MARK: - Google Cast

    private func setupGoogleCast() {
        // Replace with your Cast Application ID when you publish a custom receiver.
        // kGCKDefaultMediaReceiverApplicationID works for testing with the default receiver.
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options  = GCKCastOptions(discoveryCriteria: criteria)
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKLogger.sharedInstance().delegate = self
    }
}

// MARK: - GCKLoggerDelegate

extension AppDelegate: GCKLoggerDelegate {
    func logMessage(_ message: String, at level: GCKLoggerLevel, fromFunction function: String, location: String) {
#if DEBUG
        print("[Cast] \(function) \(message)")
#endif
    }
}
