import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// What a plugin is allowed to ask baguette to do. A manifest declares
/// the set it needs; the server grants exactly that set for the life of
/// one command invocation and refuses everything else.
///
/// Least privilege by default: a manifest that declares nothing gets
/// nothing. The set is closed so a typo is a parse error rather than a
/// silent denial at runtime — and so a user reading
/// `baguette plugin show` sees a finite, meaningful list before
/// installing.
enum PluginCapability: String, Equatable, Sendable, CaseIterable, Comparable {
    /// Read the on-screen accessibility tree.
    case describeUI = "describe-ui"
    /// Capture the screen.
    case screenshot
    /// Dispatch gestures, keys and button presses to the device. The
    /// most powerful one — it can drive the device anywhere, including
    /// through consent dialogs — so it is never implied.
    case input
    /// Read the unified log stream.
    case logs
    /// Read or override the status bar.
    case statusBar = "status-bar"
    /// Read or set the interface settings — appearance style, Increase
    /// Contrast, content size. One capability for the whole `simctl ui`
    /// family: a plugin that can darken the screen can already restyle
    /// it, so splitting read from write would be a distinction without
    /// a difference.
    case interface
    /// Read or set the simulated location.
    case location
    /// Install an app on the device.
    ///
    /// Kept apart from `media` because they are not the same authority:
    /// one puts a picture in the photo library, the other puts an
    /// executable on the device. A plugin that wants to seed test images
    /// shouldn't have to be trusted to install software.
    case apps
    /// Add photos or videos to the device's library.
    case media
    /// Open a deep link, and read the URL schemes the device's apps
    /// answer to. One capability for the pair, on the `interface`
    /// precedent: a plugin that can open *any* URL is not meaningfully
    /// restrained by hiding the list of which ones exist.
    ///
    /// Deliberately apart from `apps`, which installs software. This one
    /// only launches what is already there, and a plugin that wants to
    /// fire a deep link shouldn't have to be trusted to put an
    /// executable on the device.
    case openURL = "open-url"
    /// List simulators and their state.
    case simulators

    static func < (lhs: PluginCapability, rhs: PluginCapability) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
