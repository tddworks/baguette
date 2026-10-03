import Foundation

/// `SimulatorInjection` backed by `xcrun simctl spawn <udid> launchctl …`.
///
/// Arming is a **read-modify-write**, because `DYLD_INSERT_LIBRARIES` is a
/// single string shared by every injecting feature:
///
/// ```
/// launchctl getenv DYLD_INSERT_LIBRARIES        → what's armed now
///   → InjectedDylibs.adding / .removing         → merge by dylib filename
/// launchctl setenv DYLD_INSERT_LIBRARIES <join> → write it back
/// launchctl unsetenv DYLD_INSERT_LIBRARIES      → or drop it entirely
/// ```
///
/// Writing a bare path instead would mean the second feature to arm
/// silently disarms the first. Dropping the variable on any teardown would
/// mean whichever feature stops first disarms the other.
///
/// All of it is scoped to the simulator's launchd domain, so the value
/// survives until the simulator reboots. Re-arming on boot is the caller's
/// responsibility.
///
/// Bounded process capture keeps guest diagnostics out of the environment
/// value and waits for complete stdout before modifying it.
final class SimctlSimulatorInjection: SimulatorInjection, Sendable {
    private let xcrun: URL

    private static let variable = "DYLD_INSERT_LIBRARIES"

    init(xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun")) {
        self.xcrun = xcrun
    }

    func arm(dylibPath: String, on simulator: any Simulator) async throws {
        let udid = simulator.udid
        try await Task.detached {
            try self.locked(udid) {
                let armed = try self.currentDylibs(udid: udid)
                try self.write(armed.adding(dylibPath), udid: udid)
            }
        }.value
    }

    func disarm(dylibPath: String, on simulator: any Simulator) async throws {
        let udid = simulator.udid
        try await Task.detached {
            try self.locked(udid) {
                let armed = try self.currentDylibs(udid: udid)
                try self.write(armed.removing(dylibPath), udid: udid)
            }
        }.value
    }

    /// Runs `body` holding an exclusive lock on this simulator's environment.
    ///
    /// The read-modify-write is not atomic on its own: if the camera and
    /// motion arm at the same moment, both can read the same old value and
    /// the second `setenv` drops the first one's dylib. The lock is a **file**
    /// lock rather than something on this instance, because `CoreSimulator`
    /// hands out a fresh `SimctlSimulatorInjection` per call and the CLI is a
    /// different process from the server entirely — an in-process lock would
    /// protect nothing.
    private func locked<T>(
        _ udid: String,
        _ body: () throws -> T
    ) throws -> T {
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: InjectedDylibInstaller.defaultSupportDir)
            .appendingPathComponent("locks")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent("\(udid).inject.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o644)
        // Running unlocked would silently reintroduce exactly the race this
        // guards, so a lock we cannot take fails the operation instead. That
        // costs nothing in practice: the same support directory holds the
        // installed dylibs, so if it isn't writable there was nothing to arm.
        guard descriptor >= 0 else {
            throw SimulatorInjectionError.lockUnavailable(path: lockPath)
        }
        defer { close(descriptor) }
        // Retry a signal-interrupted wait; anything else is a real failure.
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw SimulatorInjectionError.lockUnavailable(path: lockPath)
            }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Matches by **file name**, not by whole path. Every release installs
    /// under a fresh sha-keyed directory, so the path this build would arm
    /// is almost never the path an earlier one did; comparing paths would
    /// report "not armed" for a dylib that is very much loaded. Same rule
    /// `InjectedDylibs` merges by.
    func armed(dylibPath: String, on simulator: any Simulator) async throws -> Bool {
        let udid = simulator.udid
        let name = (dylibPath as NSString).lastPathComponent
        return try await Task.detached {
            try self.currentDylibs(udid: udid).paths
                .contains { ($0 as NSString).lastPathComponent == name }
        }.value
    }

    /// Only launchctl's empty status-1 response confirms an unset variable.
    /// Other failures leave the environment unknown and must prevent a write.
    private func currentDylibs(udid: String) throws -> InjectedDylibs {
        do {
            let output = try spawn(udid: udid, arguments: ["getenv", Self.variable])
            return InjectedDylibs.parsing(output.stdout)
        } catch SimctlCapture.Failure.failed(_, 1, "") {
            return InjectedDylibs.parsing(nil)
        }
    }

    private func write(_ dylibs: InjectedDylibs, udid: String) throws {
        // An empty value is not the same as no value — dyld reports an
        // empty entry as a library it failed to load — so the last dylib
        // leaving takes the whole variable with it.
        let arguments =
            dylibs.isEmpty
            ? ["unsetenv", Self.variable]
            : ["setenv", Self.variable, dylibs.environmentValue]
        _ = try spawn(udid: udid, arguments: arguments)
    }

    private func spawn(udid: String, arguments: [String]) throws -> SimctlCapture.Output {
        try SimctlCapture.run(
            udid: udid,
            arguments: ["simctl", "spawn", udid, "launchctl"] + arguments,
            xcrun: xcrun
        )
    }
}

enum SimulatorInjectionError: LocalizedError, Equatable, CustomStringConvertible {
    /// The per-simulator lock guarding `DYLD_INSERT_LIBRARIES` couldn't be
    /// taken. Reported rather than skipped: proceeding unlocked would let a
    /// concurrent arm drop another feature's dylib, invisibly.
    case lockUnavailable(path: String)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .lockUnavailable(let path):
            return "could not lock \(path) to update DYLD_INSERT_LIBRARIES"
        }
    }
}
