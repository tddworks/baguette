import Foundation

/// Locator for the static web assets (`simulators.html` and friends)
/// that `baguette serve` serves. Files live at
/// `Sources/BaguetteCore/Resources/Web/` and are bundled into the
/// executable as SPM resources for release.
///
/// Lookup order:
///   1. `$BAGUETTE_WEB_DIR` — explicit override, ideal for live
///      iteration on the HTML without rebuilding.
///   2. Source-tree path (dev) — when the running executable lives
///      inside the package's `.build/`, walk up to the package root
///      and read directly from `Sources/BaguetteCore/Resources/Web/`.
///      Edits show on the next browser refresh; no rebuild.
///   3. Sidecar `Baguette_BaguetteCore.bundle` next to the executable —
///      the SPM-generated resource bundle. We resolve it manually
///      via `dladdr` instead of `Bundle.module` because the latter
///      `fatalError`s when the bundle is missing (e.g. a Homebrew
///      install that didn't ship the bundle).
///
/// `data(named:)` is used by the route handlers; the resolution logic
/// runs once per call which is fine — the OS caches the file pages.
struct WebRoot {

    /// Read a file as UTF-8 text, with the same lookup as `data`.
    static func string(named filename: String) -> String? {
        data(named: filename).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Read a file by name (e.g. `"simulators.html"`). Returns nil
    /// when the asset is missing across every lookup path.
    static func data(named filename: String) -> Data? {
        guard let filename = safeRelativeAssetPath(filename) else { return nil }
        if let path = ProcessInfo.processInfo.environment["BAGUETTE_WEB_DIR"],
           let data = read(URL(fileURLWithPath: path).appendingPathComponent(filename)) {
            return data
        }
        if let dev = sourceTreeRoot()?.appendingPathComponent(filename),
           let data = read(dev) {
            return data
        }
        if let bundled = sidecarWebURL(for: filename),
           let data = read(bundled) {
            return data
        }
        return nil
    }

    // MARK: - private

    /// Keep static asset lookups inside the web root even when a route
    /// passes a percent-decoded path segment such as `..%2FPackage.swift`.
    private static func safeRelativeAssetPath(_ filename: String) -> String? {
        guard !filename.isEmpty, !filename.hasPrefix("/") else { return nil }
        let scalars = filename.unicodeScalars
        guard scalars.allSatisfy({ scalar in
            scalar == "/" || scalar == "." || scalar == "-" || scalar == "_"
                || ("a"..."z").contains(scalar)
                || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar)
        }) else { return nil }

        let parts = filename.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        for part in parts {
            guard !part.isEmpty, part != ".", part != ".." else { return nil }
        }
        return parts.joined(separator: "/")
    }

    private static func read(_ url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Walk up from the executable to find a sibling
    /// `Sources/BaguetteCore/Resources/Web/` — only matches when running
    /// out of `.build/`. Returns nil otherwise (release install).
    private static func sourceTreeRoot() -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0,
              let cstr = info.dli_fname else { return nil }
        var url = URL(fileURLWithPath: String(cString: cstr)).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = url.appendingPathComponent("Sources/BaguetteCore/Resources/Web")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue {
                return candidate
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// Resolve a file inside the SPM-generated resource bundle
    /// expected to sit next to the running executable. Returns nil when
    /// the bundle isn't there (e.g. a binary-only install that forgot
    /// to ship the bundle). Crucially, this avoids `Bundle.module`,
    /// which `fatalError`s on miss.
    ///
    /// `filename` may include a subdirectory segment (e.g.
    /// `farm/farm.html`); the path is split into a subdirectory and
    /// leaf so the bundle's `subdirectory:` argument matches what
    /// `.copy("Resources/Web")` produces in the resource bundle.
    private static func sidecarWebURL(for filename: String) -> URL? {
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
        let parts = filename.split(separator: "/", omittingEmptySubsequences: true)
        let subdir: String = parts.count > 1
            ? "Web/" + parts.dropLast().joined(separator: "/")
            : "Web"
        let leaf = String(parts.last ?? Substring(filename))
        return bundle.url(
            forResource: (leaf as NSString).deletingPathExtension,
            withExtension: (leaf as NSString).pathExtension,
            subdirectory: subdir
        )
    }
}
