import Foundation

/// The image this code was loaded from — baguette's own executable.
enum ExecutableImage {
    /// The folder the executable sits in, or `nil` when dyld can't say.
    static func directory() -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let cstr = info.dli_fname else { return nil }
        return URL(fileURLWithPath: String(cString: cstr)).deletingLastPathComponent()
    }
}
