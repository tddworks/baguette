import Foundation

/// The Xcode on this Mac that carries the simulator: where baguette finds
/// SimulatorKit, CoreSimulator, and the device art Apple ships.
public enum Xcode {
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
    public static func developerDir() -> String {
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
        let out =
            String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    private static func hasSimulatorKit(at developerDir: String) -> Bool {
        SimulatorKitFramework.path(developerDir: developerDir) != nil
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
