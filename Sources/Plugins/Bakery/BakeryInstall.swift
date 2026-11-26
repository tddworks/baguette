import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// Orchestrates the whole install lifecycle — clone, read the menu,
/// resolve what to install, validate it, copy it into the plugins root,
/// and record what happened. Sits in the App layer alongside
/// `PluginDispatch`; wires the `Checkout` collaborator (mocked in
/// tests) to the pure Domain (`BakeryMenu`, `InstallPlan`,
/// `PluginManifest`) and the `FileSystemBakeries` registry.
///
/// Consent is **not** decided here. `add` / `install` assume the caller
/// (a CLI prompt or a browser `accept`) already obtained it, and record
/// the bakery as trusted. Keeping the trust decision in the App command
/// / route is what lets it be a terminal prompt in one surface and a
/// modal in the other.
///
/// Nothing a plugin ships runs during any of this — the orchestrator
/// only clones and copies files. A plugin's code executes only when the
/// user later activates it.
struct BakeryInstall {
    let checkout: any Checkout
    let home: URL
    private let registry: FileSystemBakeries

    init(checkout: any Checkout, home: URL) {
        self.checkout = checkout
        self.home = home
        self.registry = FileSystemBakeries(home: home)
    }

    /// What a bakery offers, resolved but not yet trusted. The browser
    /// shows this before the user consents; it writes nothing to the
    /// trusted list.
    struct Preview: Equatable, Sendable {
        let ref: BakeryRef
        let commit: String
        let menu: BakeryMenu
        let alreadyTrusted: Bool
    }

    // MARK: - add a source

    /// Clone and read the menu without trusting anything.
    ///
    /// Deliberately unpinned: preview answers "what does this source
    /// offer *now*", which is the question you're deciding on. `add`
    /// then records what preview saw, and that becomes the pin.
    func preview(_ ref: BakeryRef) async throws -> Preview {
        let result = try await checkout.clone(ref.bakery, into: cacheDir(for: ref), at: nil)
        let menu = try BakeryMenu.parsing(json: try menuData(in: result.directory))
        let trusted = try registry.bakeries().contains { $0.id == ref.bakery.cacheSubpath }
        return Preview(ref: ref, commit: result.commit, menu: menu, alreadyTrusted: trusted)
    }

    /// Trust a bakery: preview it, then record it. The caller must have
    /// obtained consent.
    @discardableResult
    func add(_ ref: BakeryRef) async throws -> Bakery {
        let preview = try await self.preview(ref)
        let bakery = Bakery(
            id: ref.bakery.cacheSubpath,
            url: ref.cloneURL,
            commit: preview.commit,
            plugins: preview.menu.entries.map(\.name),
            addedAt: ISO8601DateFormatter().string(from: Date())
        )
        try registry.record(bakery)
        return bakery
    }

    // MARK: - install a plugin

    /// Install one plugin from `ref`, trusting the bakery in the same
    /// step (the direct-install path) or reusing an already-trusted one.
    @discardableResult
    func install(ref: BakeryRef, requested: String?) async throws -> [InstalledPlugin] {
        // Install at the commit the user actually trusted, when there is
        // one. Taking HEAD here would mean a bakery trusted months ago
        // silently delivers whatever it holds today — the pin only means
        // something if it's what we fetch. A source not yet trusted has
        // no pin, so this is its first-contact clone.
        let pinned = try registry.bakeries().first { $0.id == ref.bakery.cacheSubpath }?.commit
        let result = try await checkout.clone(ref.bakery, into: cacheDir(for: ref), at: pinned)
        let menu = try BakeryMenu.parsing(json: try menuData(in: result.directory))
        let entries = try InstallPlan.resolve(ref: ref, requested: requested, menu: menu)

        var installed: [InstalledPlugin] = []
        for entry in entries {
            let source = result.directory.appendingPathComponent(entry.path)
            // The installed plugin's identity is its own manifest, not
            // the menu label — validate it and key everything off it.
            let manifest = try PluginManifest.parsing(
                json: try Data(contentsOf: source.appendingPathComponent(FileSystemPlugins.manifestFilename))
            )
            try copyPlugin(from: source, name: manifest.name)
            let record = InstalledPlugin(
                name: manifest.name, bakery: ref.bakery.cacheSubpath, commit: result.commit
            )
            try registry.recordInstalled(record)
            installed.append(record)
        }

        // A direct install trusts the source it pulled from.
        try registry.record(Bakery(
            id: ref.bakery.cacheSubpath,
            url: ref.cloneURL,
            commit: result.commit,
            plugins: menu.entries.map(\.name),
            addedAt: ISO8601DateFormatter().string(from: Date())
        ))
        return installed
    }

    /// Install a plugin named `name` from whichever trusted bakery
    /// offers it. No new consent — every candidate is already trusted.
    /// Refuses when no trusted bakery offers it, or more than one does
    /// (the user should qualify `owner/repo/name`).
    @discardableResult
    func installByName(_ name: String) async throws -> [InstalledPlugin] {
        let offering = try registry.bakeries().filter { $0.plugins.contains(name) }
        guard let bakery = offering.first else {
            throw BakeryResolveError.notOffered(name: name)
        }
        guard offering.count == 1 else {
            throw BakeryResolveError.ambiguous(name: name, bakeries: offering.map(\.id))
        }
        let ref = try BakeryRef.parse(bakery.url)
        return try await install(ref: ref, requested: name)
    }

    func remove(name: String) throws {
        try? FileManager.default.removeItem(at: pluginsRoot.appendingPathComponent(name))
        try registry.forgetInstalled(name: name)
    }

    // MARK: - private

    private var pluginsRoot: URL { home.appendingPathComponent("plugins") }

    private func cacheDir(for ref: BakeryRef) -> URL {
        home.appendingPathComponent("bakeries").appendingPathComponent(ref.bakery.cacheSubpath)
    }

    private func menuData(in cloneDir: URL) throws -> Data {
        guard let data = try? Data(contentsOf: cloneDir.appendingPathComponent("baguette.json")) else {
            throw BakeryMenuError.missing
        }
        return data
    }

    private func copyPlugin(from source: URL, name: String) throws {
        try FileManager.default.createDirectory(at: pluginsRoot, withIntermediateDirectories: true)
        let dest = pluginsRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
    }
}

/// Why a bare plugin name couldn't be resolved to a trusted bakery.
enum BakeryResolveError: Error, Equatable, CustomStringConvertible {
    case notOffered(name: String)
    case ambiguous(name: String, bakeries: [String])

    var description: String {
        switch self {
        case .notOffered(let name):
            return "no trusted bakery offers a plugin named \"\(name)\" — add one with `baguette bakery add`"
        case .ambiguous(let name, let bakeries):
            return """
                more than one trusted bakery offers \"\(name)\" \
                (\(bakeries.joined(separator: ", "))) — install it as owner/repo/\(name)
                """
        }
    }
}
