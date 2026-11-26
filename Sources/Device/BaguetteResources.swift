import Foundation
import Synchronization

/// Where this process finds the files baguette ships beside its binary: the
/// 3D device models (`Models3D/`), the dylibs it injects into a simulator
/// (`VirtualCamera/`, `VirtualMotion/`, `VirtualNetwork/`, `DefaultsLookups/`)
/// and the helper it runs inside one (`HingeControl/`).
///
/// The `baguette` CLI finds them in `Baguette_Baguette.bundle` next to its
/// executable. A host that links baguette as a library has no such bundle;
/// it copies those folders (from `Sources/Baguette/Resources/`) somewhere it
/// ships and names that folder here, once, before it drives a device. The
/// folder is looked in before the bundle; an environment override still
/// wins over both.
public enum BaguetteResources {
    private static let chosen = Mutex<URL?>(nil)

    /// The folder a host chose, or nil when none was.
    public static var folder: URL? {
        chosen.withLock { $0 }
    }

    /// Look for resources in `folder` (laid out as the bundle's Resources
    /// are); nil goes back to the bundle alone.
    public static func use(folder: URL?) {
        chosen.withLock { $0 = folder }
    }
}
