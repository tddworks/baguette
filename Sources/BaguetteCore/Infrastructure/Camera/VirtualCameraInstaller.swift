import Foundation

/// Resolves the bundled `VirtualCamera.dylib` and copies it into a
/// per-hash subdirectory under
/// `~/Library/Application Support/Baguette/builds/<sha12>/VirtualCamera.dylib`.
/// The caller arms each booted sim with `DYLD_INSERT_LIBRARIES` pointing
/// at that path via `SimulatorInjection`.
///
/// Pure work (sha → dest path) lives in
/// `VirtualCameraInstallPlan`. This file owns the filesystem side —
/// bundle lookup, mkdir, write, permissions — kept thin so the
/// pure factory is exercised end-to-end by tests.
enum VirtualCameraInstaller {

    static var defaultSupportDir: String {
        ("~/Library/Application Support/Baguette" as NSString).expandingTildeInPath
    }

    /// Resolve the dylib bundled inside the running baguette binary.
    /// Returns `nil` when the dylib can't be located — the caller
    /// surfaces a `camera_state.error` instead of crashing.
    ///
    /// Lookup order (matches `WebRoot.swift`'s pattern):
    ///   1. `$BAGUETTE_VIRTUALCAMERA_DYLIB` — explicit override.
    ///   2. Source-tree fallback — when running out of `.build/`,
    ///      walk up to find `VirtualCamera/VirtualCamera.dylib`.
    ///   3. Sidecar `Baguette_BaguetteCore.bundle` next to the executable.
    ///   4. Sibling of the executable (`./VirtualCamera.dylib`) —
    ///      flat binary installs / Homebrew bottles that didn't ship
    ///      the resource bundle.
    ///
    /// Crucially does NOT use `Bundle.module` — that accessor
    /// `fatalError`s when the bundle is missing, which crashes
    /// Homebrew installs.
    static func bundledDylibURL() -> URL? {
        if let env = ProcessInfo.processInfo.environment["BAGUETTE_VIRTUALCAMERA_DYLIB"],
           FileManager.default.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        if let dev = sourceTreeDylib() { return dev }
        if let bundled = sidecarBundleDylib() { return bundled }
        if let sibling = executableSiblingDylib() { return sibling }
        return nil
    }

    private static func sourceTreeDylib() -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0,
              let cstr = info.dli_fname else { return nil }
        var url = URL(fileURLWithPath: String(cString: cstr)).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidates = [
                url.appendingPathComponent("Sources/BaguetteCore/Resources/VirtualCamera/VirtualCamera.dylib"),
                url.appendingPathComponent("VirtualCamera/VirtualCamera.dylib"),
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    private static func sidecarBundleDylib() -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0,
              let cstr = info.dli_fname else { return nil }
        let exeDir = URL(fileURLWithPath: String(cString: cstr)).deletingLastPathComponent()
        let bundleNames = ["Baguette_BaguetteCore.bundle", "Baguette_Baguette.bundle"]
        guard let bundle = bundleNames.lazy.compactMap({ name -> Bundle? in
            let bundleURL = exeDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else { return nil }
            return Bundle(url: bundleURL)
        }).first else { return nil }
        return bundle.url(
            forResource: "VirtualCamera",
            withExtension: "dylib",
            subdirectory: "VirtualCamera"
        )
    }

    private static func executableSiblingDylib() -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0,
              let cstr = info.dli_fname else { return nil }
        let exeDir = URL(fileURLWithPath: String(cString: cstr)).deletingLastPathComponent()
        let url = exeDir.appendingPathComponent("VirtualCamera.dylib")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Read the bundled bytes, compute the install plan, apply it
    /// (idempotent), return the destination path. Returns `nil` if
    /// the dylib isn't bundled in this build configuration.
    static func installIfNeeded(supportDir: String = defaultSupportDir) -> String? {
        guard let url = bundledDylibURL(),
              let bytes = try? Data(contentsOf: url) else { return nil }
        let plan = VirtualCameraInstallPlan.compute(bytes: bytes, supportDir: supportDir)
        try? apply(plan: plan, bytes: bytes)
        return FileManager.default.fileExists(atPath: plan.destPath) ? plan.destPath : nil
    }

    /// Idempotent — if the file already exists at `plan.destPath` we
    /// trust its contents (the path itself is sha-keyed, so identical
    /// bytes land at the same path) and skip the rewrite. Skipping
    /// preserves the linker's adhoc signature, which iOS 26's
    /// simulator dyld rejects after any post-build `codesign --force`.
    static func apply(plan: VirtualCameraInstallPlan, bytes: Data) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: plan.destPath) { return }
        try fm.createDirectory(
            atPath: plan.buildDir,
            withIntermediateDirectories: true
        )
        try bytes.write(to: URL(fileURLWithPath: plan.destPath))
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plan.destPath)
    }
}
