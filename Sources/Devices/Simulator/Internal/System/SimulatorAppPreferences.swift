import BaguetteDevice
import AppKit
import Foundation

/// Simulator.app's own preferences domain.
///
/// This is the integration-only half of the `SimulatorLifetime` split
/// described in AGENTS.md: the three irreducible calls are the
/// `CFPreferences` read, the `CFPreferences` write, and the
/// `NSRunningApplication` lookup. Everything that decides *what those
/// values mean* lives in `SimulatorLifetime` and is unit-covered.
///
/// The preferences domain and the bundle identifier are the same string
/// — Simulator.app stores its settings under its own bundle id.
enum SimulatorAppPreferences {
    /// Simulator.app's bundle identifier, which doubles as its
    /// CFPreferences domain.
    static let domain = "com.apple.iphonesimulator"

    private static var domainID: CFString { domain as CFString }

    /// Read the current device lifetime policy.
    ///
    /// Keys that are absent stay absent in the plist handed to
    /// `SimulatorLifetime.from` — the value type is what decides that
    /// absence means shutdown.
    static func lifetime() -> SimulatorLifetime {
        var plist: [String: Any] = [:]
        for key in [SimulatorLifetime.windowCloseKey, SimulatorLifetime.appQuitKey] {
            let value = CFPreferencesCopyValue(
                key as CFString,
                domainID,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
            if let value { plist[key] = value }
        }
        return SimulatorLifetime.from(plist: plist)
    }

    /// Write the policy into Simulator.app's domain.
    ///
    /// Writes go to the current user, any host — the same location
    /// `defaults write com.apple.iphonesimulator …` targets.
    static func write(_ lifetime: SimulatorLifetime) throws {
        for (key, value) in lifetime.plistPatch {
            CFPreferencesSetValue(
                key as CFString,
                (value ? kCFBooleanTrue : kCFBooleanFalse),
                domainID,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        guard CFPreferencesSynchronize(
            domainID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else {
            throw SimulatorAppPreferencesError.synchronizeFailed
        }
    }

    /// Whether Simulator.app is running right now — it may hold a
    /// cached copy of these keys, so a write while it is up isn't
    /// reliably live.
    static var simulatorAppIsRunning: Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: domain)
            .isEmpty
    }
}

enum SimulatorAppPreferencesError: Error, CustomStringConvertible {
    case synchronizeFailed

    var description: String {
        switch self {
        case .synchronizeFailed:
            return "could not write to the \(SimulatorAppPreferences.domain) preferences domain"
        }
    }
}
