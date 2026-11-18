import Foundation

/// Locator for the plugins baguette itself ships (currently the
/// reference accessibility audit). Deliberately the same three-step
/// lookup `WebRoot` uses for the web assets, for the same reasons:
///
///   1. `$BAGUETTE_PLUGIN_DIR` — explicit override.
///   2. Source-tree path (dev) — when the running executable lives
///      inside the package's `.build/`, walk up to the package root
///      and read `Plugins/` directly. Edit a bundled plugin and the
///      next run picks it up; no rebuild.
///   3. Sidecar `Baguette_Baguette.bundle` next to the executable —
///      the SPM resource bundle, resolved via `dladdr` rather than
///      `Bundle.module`, which `fatalError`s when the bundle is
///      missing (e.g. a binary-only install).
///
/// Returns nil when nothing resolves. A missing bundled root is not an
/// error — it just means no plugins ship with this build.
enum PluginRoot {

    /// Path inside the package's source tree.
    static let sourceTreePath = "Sources/Baguette/Resources/Plugins"
    /// Directory name inside the SPM resource bundle.
    static let bundleDirectoryName = "Plugins"

    /// How far above the executable to look for a package root. Three
    /// levels covers `.build/<triple>/<config>/`; the rest is slack for
    /// deeper layouts (a test bundle sits three levels lower again).
    static let searchDepth = 8

    static func bundled() -> URL? {
        if let override = ProcessInfo.processInfo.environment["BAGUETTE_PLUGIN_DIR"] {
            let url = URL(fileURLWithPath: override)
            return isDirectory(url) ? url : nil
        }
        guard let exeDir = executableDirectory() else { return nil }
        return sourceTreeRoot(startingAt: exeDir) ?? sidecarRoot(nextTo: exeDir)
    }

    /// Walk up from `startingAt` looking for the package's bundled
    /// plugins. Only matches when running out of `.build/`; returns nil
    /// for a release install, and gives up after `depth` levels rather
    /// than climbing to `/` and adopting somebody else's `Sources/`.
    ///
    /// Takes its starting point rather than calling `dladdr` itself, so
    /// the walk — the part that can actually be wrong — is testable
    /// against a synthetic tree. Mirrors `WebRoot.sourceTreeRoot`.
    static func sourceTreeRoot(startingAt directory: URL, depth: Int = searchDepth) -> URL? {
        var url = directory
        for _ in 0..<depth {
            let candidate = url.appendingPathComponent(sourceTreePath)
            if isDirectory(candidate) { return candidate }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// The SPM resource bundle sitting beside the executable. Resolved
    /// by path rather than through `Bundle.module`, which `fatalError`s
    /// when the bundle is missing — a binary-only install should get
    /// "no bundled plugins", not a crash.
    static func sidecarRoot(nextTo directory: URL) -> URL? {
        let bundleURL = directory.appendingPathComponent("Baguette_Baguette.bundle")
        guard FileManager.default.fileExists(atPath: bundleURL.path),
              let bundle = Bundle(url: bundleURL),
              let resources = bundle.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent(bundleDirectoryName)
        return isDirectory(candidate) ? candidate : nil
    }

    // MARK: - private

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// Where this binary lives. The one irreducible call — integration-only.
    private static func executableDirectory() -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let cstr = info.dli_fname else { return nil }
        return URL(fileURLWithPath: String(cString: cstr)).deletingLastPathComponent()
    }
}
