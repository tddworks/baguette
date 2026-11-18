import Foundation

enum DeviceModelRoots {
    static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundle: Bundle? = sidecarResourceBundle()
    ) -> [URL] {
        var roots: [URL] = []
        if let override = environment["BAGUETTE_3D_MODEL_DIR"], !override.isEmpty {
            roots.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            roots.append(
                applicationSupport
                    .appending(path: "com.tddworks.baguette")
                    .appending(path: "3d-models")
            )
        }
        if let resources = bundle?.resourceURL {
            roots.append(resources.appending(path: "Models3D"))
        }
        return roots
    }

    /// Resolve the SPM-generated `Baguette_Baguette.bundle` next to the
    /// running executable via `dladdr` — never `Bundle.module`, which
    /// `fatalError`s when the bundle is missing and looks in
    /// `Bundle.main.bundleURL`, the *symlink's* directory under a
    /// Homebrew install (`bin/baguette` → `libexec/baguette`, bundle in
    /// `libexec/`). `dladdr` reports the resolved real path, so the
    /// sidecar lookup works through the symlink; a missing bundle just
    /// drops the bundled-models root.
    private static func sidecarResourceBundle() -> Bundle? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0,
              let cstr = info.dli_fname else { return nil }
        let exeDir = URL(fileURLWithPath: String(cString: cstr)).deletingLastPathComponent()
        let bundleURL = exeDir.appendingPathComponent("Baguette_Baguette.bundle")
        guard FileManager.default.fileExists(atPath: bundleURL.path) else { return nil }
        return Bundle(url: bundleURL)
    }
}
