import UIKit
import GoogleCast
import React_RCTAppDelegate
import AVFoundation
import BackgroundTasks

@main
final class AppDelegate: RCTAppDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        moduleName = "IOSMirror"
        initialProps = [:]

        setupGoogleCast()
        
        // Setup audio session for background operation
        setupAudioSession()
        
        // Register background tasks
        registerBackgroundTasks()

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.iosmirror.refresh", using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    private func handleAppRefresh(task: BGAppRefreshTask) {
        // Schedule next refresh
        scheduleAppRefresh()
        
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        // Keep streaming alive
        task.setTaskCompleted(success: true)
    }
    
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.iosmirror.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule app refresh: \(error)")
        }
    }

    override func sourceURL(for bridge: RCTBridge!) -> URL! {
        bundleURL()
    }

    func bundleURL() -> URL! {
#if DEBUG
        RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
#else
        Bundle(for: AppDelegate.self).url(forResource: "main", withExtension: "jsbundle")
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
