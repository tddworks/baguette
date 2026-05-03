import Foundation
import ObjectiveC

/// Production `Simulators` — backed by CoreSimulator + SimulatorKit private
/// classes via the ObjC runtime. No ObjC bridging module needed.
///
/// Constructed once per CLI invocation with an optional custom device set
/// path; the default Xcode set is used when `deviceSetPath` is `nil`.
final class CoreSimulators: Simulators, @unchecked Sendable {
    private let deviceSetPath: String?

    init(deviceSetPath: String? = nil) {
        self.deviceSetPath = deviceSetPath
        Self.loadFrameworks()
    }

    var all: [Simulator] {
        guard let set = resolveSet() else { return [] }
        return availableDevices(in: set).map { device in
            simulator(from: device)
        }
    }

    func find(udid: String) -> Simulator? {
        all.first { $0.udid == udid }
    }

    func boot(_ simulator: Simulator) throws {
        guard let device = resolveDevice(udid: simulator.udid) else {
            throw SimulatorError.notFound(udid: simulator.udid)
        }

        // Try bootWithOptions:error: first (headless boot, persists past disconnect).
        let bootOpts = NSSelectorFromString("bootWithOptions:error:")
        if device.responds(to: bootOpts) {
            var err: NSError?
            let opts: NSDictionary = ["persist": true]
            if invokeBoolWithObjAndError(device, bootOpts, opts, &err) { return }
            if let err { logErr("bootWithOptions failed: \(err)") }
        }

        let bootSel = NSSelectorFromString("bootWithError:")
        if device.responds(to: bootSel) {
            var err: NSError?
            if invokeBoolWithError(device, bootSel, &err) { return }
            if let err { logErr("bootWithError failed: \(err)") }
        }

        throw SimulatorError.bootFailed
    }

    func shutdown(_ simulator: Simulator) throws {
        guard let device = resolveDevice(udid: simulator.udid) else {
            throw SimulatorError.notFound(udid: simulator.udid)
        }
        let sel = NSSelectorFromString("shutdownWithError:")
        guard device.responds(to: sel) else { throw SimulatorError.shutdownFailed }
        var err: NSError?
        guard invokeBoolWithError(device, sel, &err) else {
            if let err { logErr("shutdownWithError failed: \(err)") }
            throw SimulatorError.shutdownFailed
        }
    }

    func screen(for simulator: Simulator) -> any Screen {
        SimulatorKitScreen(udid: simulator.udid, host: self)
    }

    func input(for simulator: Simulator) -> any Input {
        IndigoHIDInput(udid: simulator.udid, host: self)
    }

    // MARK: - resolution

    /// Look up the underlying `SimDevice` ObjC object for a UDID.
    /// Used by the Screen/Input adapters as well, hence `internal`.
    func resolveDevice(udid: String) -> NSObject? {
        guard let set = resolveSet() else { return nil }
        for device in availableDevices(in: set) {
            if (device.value(forKey: "UDID") as? NSUUID)?.uuidString == udid {
                return device
            }
        }
        return nil
    }

    // MARK: - private

    private func resolveSet() -> NSObject? {
        guard let ctx = sharedServiceContext() else { return nil }
        if let path = deviceSetPath {
            return customDeviceSet(context: ctx, path: path) ?? defaultDeviceSet(context: ctx)
        }
        return defaultDeviceSet(context: ctx)
    }

    private func sharedServiceContext() -> NSObject? {
        guard let cls = NSClassFromString("SimServiceContext") else { return nil }
        let sel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        var err: NSError?
        let ctx = invokeClassObjWithObjAndError(cls, sel, Self.developerDir() as NSString, &err)
        if ctx == nil, let err { logErr("sharedServiceContext: \(err)") }
        return ctx
    }

    private func defaultDeviceSet(context: NSObject) -> NSObject? {
        let sel = NSSelectorFromString("defaultDeviceSetWithError:")
        guard context.responds(to: sel) else { return nil }
        var err: NSError?
        return invokeObjWithError(context, sel, &err)
    }

    private func customDeviceSet(context: NSObject, path: String) -> NSObject? {
        let candidates = [path, (path as NSString).appendingPathComponent("Devices")]
        let withPathSel = NSSelectorFromString("deviceSetWithPath:error:")
        if context.responds(to: withPathSel) {
            for candidate in candidates where existsAsDirectory(candidate) {
                var err: NSError?
                if let set = invokeObjWithObjAndError(context, withPathSel, candidate as NSString, &err),
                   hasDevices(set) {
                    return set
                }
            }
        }
        return nil
    }

    private func availableDevices(in set: NSObject) -> [NSObject] {
        (set.value(forKey: "availableDevices") as? [NSObject]) ?? []
    }

    private func simulator(from device: NSObject) -> Simulator {
        let udid = (device.value(forKey: "UDID") as? NSUUID)?.uuidString ?? ""
        let name = (device.value(forKey: "name") as? String) ?? "Unknown"
        let raw = (device.value(forKey: "state") as? NSNumber)?.uintValue ?? 1
        // CoreSimulator's `runtime` is a SimRuntime object whose `name`
        // returns the user-facing version string ("iOS 26.4"). Fall
        // back to the runtime identifier and finally to "" so the
        // field is always at least a string.
        let runtimeName = (device.value(forKey: "runtime") as? NSObject).flatMap { rt -> String? in
            (rt.value(forKey: "name") as? String) ?? (rt.value(forKey: "versionString") as? String)
        } ?? ""
        return Simulator(
            udid: udid, name: name,
            state: state(from: raw),
            runtime: runtimeName,
            host: self
        )
    }

    private func state(from raw: UInt) -> Simulator.State {
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
        let dev = developerDir()
        let coreSim = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
        let simKit = (dev as NSString)
            .appendingPathComponent("Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit")
        if dlopen(coreSim, RTLD_NOW | RTLD_GLOBAL) == nil {
            logErr("CoreSimulator load failed: \(dlerrorString())")
        }
        if dlopen(simKit, RTLD_NOW | RTLD_GLOBAL) == nil {
            logErr("SimulatorKit load failed: \(dlerrorString())")
        }
    }

    /// Resolve a developer directory that actually contains
    /// `SimulatorKit.framework`.
    ///
    /// `xcode-select -p` is the first choice, but it commonly points at
    /// `/Library/Developer/CommandLineTools` (no SimulatorKit) when a
    /// user installs CLT before Xcode, or after renaming/moving an
    /// Xcode bundle. In that case we fall back to scanning
    /// `/Applications` for any `Xcode*.app` whose `Contents/Developer`
    /// has SimulatorKit — covers `Xcode.app`, `Xcode-beta.app`,
    /// `Xcode_26_2.app`, etc.
    static func developerDir() -> String {
        if let dev = xcodeSelectDir(), hasSimulatorKit(at: dev) { return dev }
        if let dev = scanApplications() { return dev }
        // No working Xcode found — return xcode-select's answer (or the
        // canonical default) so the subsequent dlopen surfaces a path
        // the user recognises in the error.
        return xcodeSelectDir() ?? "/Applications/Xcode.app/Contents/Developer"
    }

    private static func xcodeSelectDir() -> String? {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        task.arguments = ["-p"]
        task.standardOutput = pipe
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let out = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    private static func hasSimulatorKit(at developerDir: String) -> Bool {
        let path = (developerDir as NSString)
            .appendingPathComponent("Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit")
        return FileManager.default.fileExists(atPath: path)
    }

    private static func scanApplications() -> String? {
        let fm = FileManager.default
        // Try the canonical path first so a normal install wins over
        // any side-by-side Xcode betas.
        let canonical = "/Applications/Xcode.app/Contents/Developer"
        if hasSimulatorKit(at: canonical) { return canonical }
        let entries = (try? fm.contentsOfDirectory(atPath: "/Applications")) ?? []
        for app in entries.sorted()
        where app.hasPrefix("Xcode") && app.hasSuffix(".app") && app != "Xcode.app" {
            let dev = "/Applications/\(app)/Contents/Developer"
            if hasSimulatorKit(at: dev) { return dev }
        }
        return nil
    }
}

// MARK: - shared ObjC-runtime helpers

func dlerrorString() -> String {
    guard let err = dlerror() else { return "(null)" }
    return String(cString: err)
}

func logErr(_ message: String) {
    fputs("[baguette] \(message)\n", stderr)
}

func invokeBoolWithError(
    _ target: NSObject, _ sel: Selector, _ err: inout NSError?
) -> Bool {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return false }
    typealias Fn = @convention(c) (
        AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> Bool
    return unsafeBitCast(imp, to: Fn.self)(target, sel, &err)
}

func invokeBoolWithObjAndError(
    _ target: NSObject, _ sel: Selector, _ arg: AnyObject, _ err: inout NSError?
) -> Bool {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return false }
    typealias Fn = @convention(c) (
        AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> Bool
    return unsafeBitCast(imp, to: Fn.self)(target, sel, arg, &err)
}

func invokeObjWithError(
    _ target: NSObject, _ sel: Selector, _ err: inout NSError?
) -> NSObject? {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return nil }
    typealias Fn = @convention(c) (
        AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> AnyObject?
    return unsafeBitCast(imp, to: Fn.self)(target, sel, &err) as? NSObject
}

func invokeObjWithObjAndError(
    _ target: NSObject, _ sel: Selector, _ arg: AnyObject, _ err: inout NSError?
) -> NSObject? {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return nil }
    typealias Fn = @convention(c) (
        AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> AnyObject?
    return unsafeBitCast(imp, to: Fn.self)(target, sel, arg, &err) as? NSObject
}

func invokeClassObjWithObjAndError(
    _ cls: AnyClass, _ sel: Selector, _ arg: AnyObject, _ err: inout NSError?
) -> NSObject? {
    guard let metaCls = object_getClass(cls),
          let imp = class_getMethodImplementation(metaCls, sel)
    else { return nil }
    typealias Fn = @convention(c) (
        AnyClass, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> AnyObject?
    return unsafeBitCast(imp, to: Fn.self)(cls, sel, arg, &err) as? NSObject
}
