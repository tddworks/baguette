import BaguetteDevice
import AppKit

/// Xcode 27's Device Hub, as a host process.
///
/// The one fact the input surface needs is whether it is running at all:
/// if it isn't, no daemon is coming to attach to a booting device, and
/// there is nothing to wait for. Bundle id from its `Info.plist`
/// (`Xcode.app/Contents/Applications/DeviceHub.app`).
enum DeviceHubApp {
    static let bundleIdentifier = "com.apple.dt.Devices"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
