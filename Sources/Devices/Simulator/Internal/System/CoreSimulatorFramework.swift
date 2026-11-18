import BaguetteDevice
import Foundation

/// CoreSimulator's way in: loading a private framework image, and the
/// shared `SimServiceContext` every device set is read from. Which images
/// to load, and what to say when one is missing, is `CoreSimulators`'.
enum CoreSimulatorFramework {
    /// Load the image at `path` into this process; its load error, or `nil`.
    static func open(_ path: String) -> String? {
        dlopen(path, RTLD_NOW | RTLD_GLOBAL) == nil ? dlerrorString() : nil
    }

    /// The service context for this Xcode, or `nil` when CoreSimulator
    /// isn't loaded or refuses it.
    static func sharedContext(developerDir: String) -> NSObject? {
        guard let cls = NSClassFromString("SimServiceContext") else { return nil }
        let sel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        var err: NSError?
        let ctx = invokeClassObjWithObjAndError(cls, sel, developerDir as NSString, &err)
        if ctx == nil, let err { logErr("sharedServiceContext: \(err)") }
        return ctx
    }
}
