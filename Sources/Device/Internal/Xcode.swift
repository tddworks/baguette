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

    // MARK: - every installed Xcode

    /// The Xcode bundles on this Mac, in the order an asset Apple ships
    /// inside Xcode is looked for: the selected one (`developerDir()`)
    /// first, then the others in `/Applications` and `~/Applications`,
    /// newest first.
    public static func installed(fileManager: FileManager = .default) -> [URL] {
        let selected = URL(fileURLWithPath: developerDir())
            .deletingLastPathComponent().deletingLastPathComponent()
        let folders = [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appending(path: "Applications"),
        ]
        let found: [(URL, String)] = folders.flatMap { folder -> [(URL, String)] in
            let apps = (try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil)) ?? []
            return apps.compactMap { app in
                guard app.pathExtension == "app",
                      let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
                      info["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode"
                else { return nil }
                return (app, info["CFBundleShortVersionString"] as? String ?? "0")
            }
        }
        return searchOrder(selected: selected, installed: found)
    }

    /// The selected Xcode, then the rest by version, newest first,
    /// compared as numbers (26.10 is newer than 26.4). Each Xcode once.
    static func searchOrder(selected: URL?, installed: [(URL, String)]) -> [URL] {
        let others = installed
            .filter { $0.0.standardizedFileURL != selected?.standardizedFileURL }
            .sorted { $0.1.compare($1.1, options: .numeric) == .orderedDescending }
            .map(\.0)
        return (selected.map { [$0] } ?? []) + others
    }
}
