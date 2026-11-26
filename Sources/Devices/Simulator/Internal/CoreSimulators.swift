import BaguetteDevice
import Foundation
import ObjectiveC

/// Production `Simulators` — backed by CoreSimulator + SimulatorKit private
/// classes via the ObjC runtime. No ObjC bridging module needed. Loading
/// the frameworks and reaching the service context are
/// `CoreSimulatorFramework`'s; reading the device set is here.
///
/// Constructed once per CLI invocation with an optional custom device set
/// path; the default Xcode set is used when `deviceSetPath` is `nil`.
public final class CoreSimulators: Simulators, DeviceHost, @unchecked Sendable {
    private let deviceSetPath: String?
    private let serviceContext: @Sendable () -> NSObject?
    private let now: @Sendable () -> TimeInterval
    /// Where each program run in the guest is, asked each time one runs.
    private let programs: InjectedProgramPaths

    /// How long a found device is taken as still there. Finding one costs about 70 ms,
    /// and a read asks up to three times, so polling a screen was mostly this. Short,
    /// because `baguette serve` outlives devices: a deleted one is noticed within this.
    private static let rememberFor: TimeInterval = 5
    private let lock = NSLock()
    private var remembered: [String: (device: NSObject, foundAt: TimeInterval)] = [:]

    /// The simulators of `deviceSetPath`, or of Xcode's default set when nil,
    /// through the active Xcode's CoreSimulator.
    ///
    /// `injectedPrograms` are a host's own copies of the programs baguette
    /// runs in the guest (docs/features/injected-programs/design.md); each
    /// one left nil is found where the CLI ships it (`BAGUETTE_<NAME>_TOOL`,
    /// the source tree, the bundle).
    public convenience init(deviceSetPath: String? = nil, injectedPrograms: InjectedPrograms = InjectedPrograms()) {
        self.init(
            deviceSetPath: deviceSetPath,
            serviceContext: {
                CoreSimulatorFramework.sharedContext(developerDir: CoreSimulators.developerDir())
            },
            injectedPrograms: injectedPrograms
        )
    }

    /// `hingeControl` is one binary answering every program's verbs: the
    /// `HingeControl` they were split from.
    @available(*, deprecated, message: "Pass each program: CoreSimulators(deviceSetPath:injectedPrograms:).")
    public convenience init(deviceSetPath: String? = nil, hingeControl: URL?) {
        self.init(
            deviceSetPath: deviceSetPath,
            injectedPrograms: hingeControl.map(InjectedPrograms.everyVerb(in:)) ?? InjectedPrograms()
        )
    }

    init(
        deviceSetPath: String? = nil,
        serviceContext: @escaping @Sendable () -> NSObject?,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        injectedPrograms: InjectedPrograms = InjectedPrograms()
    ) {
        self.deviceSetPath = deviceSetPath
        self.serviceContext = serviceContext
        self.now = now
        programs = InjectedProgramPaths(injectedPrograms)
        Self.loadFrameworks()
    }

    /// Whether the guest is shut down or gone, per a fresh listing of
    /// the device set this host resolves to. Camera cleanup treats only
    /// that as proof that a failed disarm no longer matters.
    public func hasTerminated(udid: String, xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun")) throws -> Bool {
        guard let set = resolveSet() else { throw DeviceSetUnavailable() }
        return try SimctlCameraGuest.hasTerminated(udid: udid, deviceSetPath: set.path, xcrun: xcrun)
    }

    private struct DeviceSetUnavailable: LocalizedError {
        var errorDescription: String? {
            "The CoreSimulator device set could not be resolved; camera cleanup remains unconfirmed."
        }
    }

    public var all: [any Simulator] {
        guard let set = resolveSet() else { return [] }
        return availableDevices(in: set.object).map { device in
            coreSimulator(from: device, deviceSetPath: set.path)
        }
    }

    /// The one simulator with this UDID, its state read now. Matches the UDID
    /// before reading anything else: every gesture looks its device up, and
    /// building every installed simulator (name, runtime, model — dozens of
    /// reads into CoreSimulator each) to keep one cost each tap ~4 ms.
    public func find(udid: String) -> (any Simulator)? {
        guard let set = resolveSet() else { return nil }
        return availableDevices(in: set.object)
            .first { ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid }
            .map { coreSimulator(from: $0, deviceSetPath: set.path) }
    }

    // MARK: - resolution

    /// Look up the underlying `SimDevice` ObjC object for a UDID.
    /// Used by the Screen/Input adapters as well, hence `internal`.
    public func resolveDevice(udid: String) -> NSObject? {
        let time = now()
        lock.lock()
        let known = remembered[udid]
        lock.unlock()
        // A clock that went back can't say how long it's been, so it looks again.
        if let known, (0..<Self.rememberFor).contains(time - known.foundAt) { return known.device }

        guard let set = resolveSet() else { return nil }
        let device = availableDevices(in: set.object).first {
            ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid
        }
        lock.lock()
        remembered[udid] = device.map { ($0, time) }
        lock.unlock()
        return device
    }

    // MARK: - private

    private func resolveSet() -> (object: NSObject, path: String?)? {
        guard let ctx = serviceContext() else { return nil }
        if let path = deviceSetPath {
            return customDeviceSet(context: ctx, path: path)
        }
        return defaultDeviceSet(context: ctx).map { ($0, nil) }
    }

    private func defaultDeviceSet(context: NSObject) -> NSObject? {
        let sel = NSSelectorFromString("defaultDeviceSetWithError:")
        guard context.responds(to: sel) else { return nil }
        var err: NSError?
        return invokeObjWithError(context, sel, &err)
    }

    private func customDeviceSet(context: NSObject, path: String) -> (object: NSObject, path: String?)? {
        let candidates = [path, (path as NSString).appendingPathComponent("Devices")]
        let withPathSel = NSSelectorFromString("deviceSetWithPath:error:")
        if context.responds(to: withPathSel) {
            for candidate in candidates where existsAsDirectory(candidate) {
                var err: NSError?
                if let set = invokeObjWithObjAndError(context, withPathSel, candidate as NSString, &err),
                    hasDevices(set)
                {
                    return (set, candidate)
                }
            }
        }
        return nil
    }

    private func availableDevices(in set: NSObject) -> [NSObject] {
        (set.value(forKey: "availableDevices") as? [NSObject]) ?? []
    }

    private func coreSimulator(from device: NSObject, deviceSetPath: String?) -> CoreSimulator {
        let udid = (device.value(forKey: "UDID") as? NSUUID)?.uuidString ?? ""
        let name = (device.value(forKey: "name") as? String) ?? "Unknown"
        let raw = (device.value(forKey: "state") as? NSNumber)?.uintValue ?? 1
        // CoreSimulator's `runtime` is a SimRuntime object whose `name`
        // returns the user-facing version string ("iOS 26.4"). Fall
        // back to the runtime identifier and finally to "" so the
        // field is always at least a string.
        let runtime = device.value(forKey: "runtime") as? NSObject
        let deviceType = device.value(forKey: "deviceType") as? NSObject
        let runtimeName =
            runtime.flatMap { rt -> String? in
                (rt.value(forKey: "name") as? String) ?? (rt.value(forKey: "versionString") as? String)
            } ?? ""
        // `deviceType.name` is the stable bundle filename — survives
        // `simctl clone` / rename, where `device.name` does not. Falls
        // back to the user-given `name` so non-clones (and any oddball
        // device with no `deviceType`) resolve to the same string they
        // did before.
        let deviceTypeName =
            deviceType
            .flatMap { $0.value(forKey: "name") as? String } ?? name
        return CoreSimulator(
            udid: udid,
            name: name,
            state: state(from: raw),
            runtime: runtimeName,
            deviceTypeName: deviceTypeName,
            host: self,
            deviceSetPath: deviceSetPath,
            programs: programs,
            // Identity from the installed catalog, read once per device: the
            // identifiers survive a rename and `versionString` compares cleanly,
            // while `runtime.version` is a packed integer.
            metadata: SimulatorMetadata(
                deviceTypeIdentifier: deviceType?.value(forKey: "identifier") as? String,
                productFamily: deviceType?.value(forKey: "productFamily") as? String,
                runtimeIdentifier: runtime?.value(forKey: "identifier") as? String,
                runtimeVersion: runtime?.value(forKey: "versionString") as? String)
        )
    }

    private func state(from raw: UInt) -> SimulatorState {
        switch raw {
        case 0: return .creating
        case 1: return .shutdown
        case 2: return .booting
        case 3: return .booted
        case 4: return .shuttingDown
        default: return .shutdown
        }
    }

    private func existsAsDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func hasDevices(_ set: NSObject) -> Bool {
        ((set.value(forKey: "availableDevices") as? [Any])?.count ?? 0) > 0
    }

    // MARK: - framework loading

    nonisolated(unsafe) private static var loaded = false

    static func loadFrameworks() {
        guard !loaded else { return }
        loaded = true
        for line in frameworkLoadProblems(developerDir: developerDir(), open: CoreSimulatorFramework.open) {
            logErr(line)
        }
    }

    /// Loads CoreSimulator and the selected Xcode's SimulatorKit through
    /// `open` (an image's path in, its load error out), answering what
    /// went wrong, a line at a time.
    static func frameworkLoadProblems(developerDir dev: String, open: (String) -> String?) -> [String] {
        var problems: [String] = []
        // CoreSimulator lives outside Xcode, in a system path that
        // Xcode 27 left alone.
        let coreSim = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
        if let error = open(coreSim) {
            problems.append("CoreSimulator load failed: \(error)")
        }
        guard let simKit = SimulatorKitFramework.path(developerDir: dev) else {
            // No Xcode on this machine carries SimulatorKit at either
            // known location. Say so — a raw dyld error here names one
            // path the user never had and reads as a broken install.
            problems.append("SimulatorKit not found. Searched:")
            for candidate in SimulatorKitFramework.candidatePaths(developerDir: dev) {
                problems.append("  \(candidate)")
            }
            problems.append("Set DEVELOPER_DIR to an Xcode that has it, or see")
            problems.append("https://github.com/tddworks/baguette/issues/28")
            return problems
        }
        if let error = open(simKit) {
            problems.append("SimulatorKit load failed: \(error)")
        }
        return problems
    }

    /// The Xcode whose SimulatorKit this process drives.
    public static func developerDir() -> String { Xcode.developerDir() }
}
