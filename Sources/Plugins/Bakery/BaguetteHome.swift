import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// Where baguette keeps installed plugins, trusted bakeries, and the
/// clone cache — `~/.baguette` by default, or `$BAGUETTE_HOME` when set.
///
/// One resolver so the CLI, the server, and the plugin scanner all
/// agree on the same directory. The override exists for sandboxing and
/// for tests that must not touch the real home.
enum BaguetteHome {
    static var url: URL {
        if let override = ProcessInfo.processInfo.environment["BAGUETTE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".baguette")
    }

    /// The installed-plugins root — the directory `FileSystemPlugins`
    /// scans and `BakeryInstall` copies into.
    static var pluginsRoot: URL { url.appendingPathComponent("plugins") }
}
