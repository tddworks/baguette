import BaguetteDevice
import Foundation
import CryptoKit

/// A guest-side binary baguette ships: a dylib injected into simulator
/// apps, or an executable spawned in the guest.
///
/// Three dylibs armed device-wide — the virtual camera, virtual motion
/// and network conditioning — sharing one install layout, one arming
/// mechanism (`InjectedDylibs`) and one `DYLD_INSERT_LIBRARIES`; one
/// handed only to the app baguette launches, `DefaultsLookups`; and one
/// executable, `HingeControl`, run with `simctl spawn`.
struct InjectedDylib: Equatable, Sendable {
    enum Kind: Sendable { case dylib, executable }

    /// Base name; the file on disk is `<name>.dylib`, or `<name>` for an
    /// executable.
    let name: String
    /// Env var that points at a hand-built copy, for iterating on the dylib
    /// without rebuilding baguette.
    let environmentOverride: String
    let kind: Kind

    init(name: String, environmentOverride: String, kind: Kind = .dylib) {
        self.name = name
        self.environmentOverride = environmentOverride
        self.kind = kind
    }

    var fileName: String { kind == .dylib ? "\(name).dylib" : name }

    /// Where this dylib's built copy sits relative to the repo root, for the
    /// dev-build fallback that walks up from the executable.
    ///
    /// All three live under one `Injected/` folder, so the path has to name
    /// it: a bare `<Name>/<Name>.dylib` silently stopped resolving the
    /// moment they moved, and a build with no bundled dylib fails at arm
    /// time rather than at build time.
    var sourceTreePath: String { "Injected/\(name)/\(fileName)" }

    static let camera = InjectedDylib(
        name: "VirtualCamera", environmentOverride: "BAGUETTE_VIRTUALCAMERA_DYLIB")
    static let motion = InjectedDylib(
        name: "VirtualMotion", environmentOverride: "BAGUETTE_VIRTUALMOTION_DYLIB")
    static let network = InjectedDylib(
        name: "VirtualNetwork", environmentOverride: "BAGUETTE_VIRTUALNETWORK_DYLIB")
    /// Lets an app say which preferences it looks up (`PreferenceLookups`).
    /// Never armed device-wide: only the app baguette launches loads it.
    static let defaultsLookups = InjectedDylib(
        name: "DefaultsLookups", environmentOverride: "BAGUETTE_DEFAULTSLOOKUPS_DYLIB")
    /// Drives iPhone Duo's hinge from inside the guest (`GuestHingeMotor`).
    static let hingeControl = InjectedDylib(
        name: "HingeControl", environmentOverride: "BAGUETTE_HINGECONTROL_TOOL", kind: .executable)
}

/// Pure factory: turns a (dylib-bytes, support-dir, dylib) triple into the
/// install layout. Per-hash subdirs dodge the iOS Simulator's dyld
/// page-hash cache rejecting replaced dylibs at the same path with
/// `code:codesigning(3) invalid-page(2)` — every release ships a
/// different sha12, gets a different install path.
///
/// Dylibs from the same build share a directory and differ only by file
/// name, so both can be armed at once.
struct InjectedDylibInstallPlan: Equatable {
    let sha12: String
    let buildDir: String
    let destPath: String

    static func compute(bytes: Data, supportDir: String,
                        dylib: InjectedDylib) -> InjectedDylibInstallPlan {
        let sha = String(sha256Hex(bytes).prefix(12))
        let buildDir = (supportDir as NSString).appendingPathComponent("builds/\(sha)")
        let destPath = (buildDir as NSString).appendingPathComponent(dylib.fileName)
        return InjectedDylibInstallPlan(sha12: sha, buildDir: buildDir, destPath: destPath)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
