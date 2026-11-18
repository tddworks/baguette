import BaguetteDevice
import Foundation

/// Resolves a bundled dylib and copies it into a per-hash subdirectory under
/// `~/Library/Application Support/Baguette/builds/<sha12>/<Name>.dylib`.
/// The caller arms each booted sim with `DYLD_INSERT_LIBRARIES` pointing at
/// that path via `SimulatorInjection`.
///
/// Pure work (sha → dest path) lives in `InjectedDylibInstallPlan`. This
/// file owns the filesystem side — bundle lookup, mkdir, write, permissions
/// — kept thin so the pure factory is exercised end-to-end by tests.
///
/// Generalised from the camera's installer when motion became a second
/// injected dylib: everything here was identical except the file name.
enum InjectedDylibInstaller {

    static var defaultSupportDir: String {
        ("~/Library/Application Support/Baguette" as NSString).expandingTildeInPath
    }

    /// Resolve `dylib` inside the running baguette binary. Returns `nil`
    /// when it can't be located — the caller surfaces an error to the user
    /// instead of crashing.
    ///
    /// Lookup order (matches `WebRoot.swift`'s pattern):
    ///   1. The dylib's env override — an explicit path.
    ///   2. Source-tree fallback — when running out of `.build/`, walk up to
    ///      find `<Name>/<Name>.dylib`.
    ///   3. Sidecar `Baguette_Baguette.bundle` next to the executable.
    ///   4. Sibling of the executable (`./<Name>.dylib`) — flat binary
    ///      installs / Homebrew bottles that didn't ship the resource bundle.
    ///
    /// Crucially does NOT use `Bundle.module` — that accessor `fatalError`s
    /// when the bundle is missing, which crashes Homebrew installs.
    static func bundledDylibURL(_ dylib: InjectedDylib) -> URL? {
        if let env = ProcessInfo.processInfo.environment[dylib.environmentOverride],
           FileManager.default.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        if let dev = sourceTreeDylib(dylib) { return dev }
        if let bundled = sidecarBundleDylib(dylib) { return bundled }
        if let sibling = executableSiblingDylib(dylib) { return sibling }
        return nil
    }

    private static func executableDirectory() -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let cstr = info.dli_fname else { return nil }
        return URL(fileURLWithPath: String(cString: cstr)).deletingLastPathComponent()
    }

    private static func sourceTreeDylib(_ dylib: InjectedDylib) -> URL? {
        guard var url = executableDirectory() else { return nil }
        for _ in 0..<6 {
            let candidate = url.appendingPathComponent(dylib.sourceTreePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    private static func sidecarBundleDylib(_ dylib: InjectedDylib) -> URL? {
        guard let exeDir = executableDirectory() else { return nil }
        let bundleURL = exeDir.appendingPathComponent("Baguette_Baguette.bundle")
        guard FileManager.default.fileExists(atPath: bundleURL.path),
              let bundle = Bundle(url: bundleURL) else { return nil }
        return bundle.url(
            forResource: dylib.name,
            withExtension: dylib.kind == .dylib ? "dylib" : nil,
            subdirectory: dylib.name
        )
    }

    private static func executableSiblingDylib(_ dylib: InjectedDylib) -> URL? {
        guard let exeDir = executableDirectory() else { return nil }
        let url = exeDir.appendingPathComponent(dylib.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Read the bundled bytes, compute the install plan, apply it
    /// (idempotent), return the destination path. Returns `nil` if the dylib
    /// isn't bundled in this build configuration.
    static func installIfNeeded(_ dylib: InjectedDylib,
                                supportDir: String = defaultSupportDir) -> String? {
        guard let url = bundledDylibURL(dylib),
              let bytes = try? Data(contentsOf: url) else { return nil }
        let plan = InjectedDylibInstallPlan.compute(bytes: bytes, supportDir: supportDir,
                                                    dylib: dylib)
        try? apply(plan: plan, bytes: bytes)
        return FileManager.default.fileExists(atPath: plan.destPath) ? plan.destPath : nil
    }

    /// Idempotent — if the file already exists at `plan.destPath` we trust
    /// its contents (the path itself is sha-keyed, so identical bytes land at
    /// the same path) and skip the rewrite. Skipping preserves the linker's
    /// adhoc signature, which iOS 26's simulator dyld rejects after any
    /// post-build `codesign --force`.
    /// The write goes to a unique temporary file and is then moved into
    /// place, because the existence check above is a time-of-check that two
    /// concurrent callers (a camera start and a motion arm, say) can both
    /// pass. A direct write would let one caller arm the path while the
    /// other was still filling it, and dyld would reject the truncated
    /// dylib. A move is atomic, so a racing caller sees either no file or a
    /// complete one — and whoever loses the race is happy, since identical
    /// bytes are what put them at this sha-keyed path to begin with.
    static func apply(plan: InjectedDylibInstallPlan, bytes: Data) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: plan.destPath) { return }
        try fm.createDirectory(atPath: plan.buildDir, withIntermediateDirectories: true)
        let staging = URL(fileURLWithPath: plan.buildDir)
            .appendingPathComponent(".\(UUID().uuidString).partial")
        try bytes.write(to: staging)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        do {
            try fm.moveItem(at: staging, to: URL(fileURLWithPath: plan.destPath))
        } catch {
            try? fm.removeItem(at: staging)
            // Another caller finishing first is success, not failure.
            guard fm.fileExists(atPath: plan.destPath) else { throw error }
        }
    }
}
