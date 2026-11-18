import BaguetteDevice
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// The browser half of plugin distribution: preview a bakery, list the
/// ones you trust, and install from those. In its own file like
/// `ServerPluginRoutes`.
///
/// Previewing clones a repo into the cache and reads its menu, which is
/// as powerful as `boot`/`shutdown` and rides the same browser-trust
/// gate (`rejectUntrustedBrowser` — Origin / `Sec-Fetch-Site` /
/// DNS-rebind).
///
/// **Installing rides a second gate on top of that one.** It copies
/// files into a directory whose contents baguette later executes, and
/// the only thing standing in front of a browser route is a set of
/// origin heuristics — well tested, but heuristics. So the install
/// route takes a bakery's **recorded id**, never a URL or a git ref:
/// the page can only reach a source already in `bakeries.json`, at the
/// commit pinned there. If an origin check is ever wrong, the blast
/// radius is "installs a plugin from a repo you already vetted" rather
/// than "clones anything and writes it to your disk".
///
/// **Trusting a new source still isn't something a page can do.** A
/// modal button isn't real consent — the page sets the flag it then
/// checks — so `bakery add` stays a terminal act and preview still
/// ends by handing you the command. See `InstallDecision`.
extension Server {

    func bakeryInstaller() -> BakeryInstall {
        return BakeryInstall(checkout: GitCheckout(), home: BaguetteHome.url)
    }

    func registerBakeryRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let installer = bakeryInstaller()
        let home = BaguetteHome.url
        let plugins = self.plugins

        // Clone + read the menu so the modal can show what it'd be
        // trusting. Records nothing.
        router.post("/bakeries/preview") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let ref = try await Self.stringField(r, "ref")
            switch await Self.previewBakery(reference: ref, install: installer) {
            case .ok(let json): return Self.jsonResponse(json)
            case .failed(let message): return Self.pluginError(message, status: .badRequest)
            }
        }

        // Install one plugin from a bakery the user already trusts.
        // The body names the bakery by its recorded id — an id that
        // isn't in `bakeries.json` resolves to nothing and no remote is
        // contacted to find out. See the type comment above.
        router.post("/bakeries/install") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let body = try await Self.jsonBody(r)
            switch await Self.installFromBakery(
                bakery: body["bakery"] as? String ?? "",
                plugin: body["plugin"] as? String ?? "",
                home: home, install: installer
            ) {
            case .ok(let json): return Self.jsonResponse(json)
            case .refused(let message): return Self.pluginError(message, status: .forbidden)
            case .failed(let message):
                return Self.pluginError(message, status: .internalServerError)
            }
        }

        router.get("/bakeries.json") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            // "Already installed" is what the plugin scan can see, not
            // what `installed.json` recorded: a bundled plugin has no
            // provenance record and must still read as satisfied.
            let present = Set(((try? plugins.all()) ?? []).map(\.id))
            switch Self.listBakeries(home: home, installed: present) {
            case .ok(let json): return Self.jsonResponse(json)
            case .failed(let message):
                return Self.pluginError(message, status: .internalServerError)
            }
        }
    }

    // MARK: - listing

    enum BakeryListOutcome: Equatable {
        case ok(String)
        case failed(String)
    }

    /// The trusted bakeries, as the modal renders them.
    ///
    /// A read failure is reported rather than flattened to an empty
    /// list: a corrupt or unreadable `bakeries.json` would otherwise
    /// show in the UI as "no bakeries added", which is exactly what a
    /// fresh install looks like — and the user's next add would write
    /// that emptiness back over whatever was really there.
    ///
    /// A serialization failure is reported too. Falling back to `Data()`
    /// meant a 200 with `Content-Type: application/json` and an empty
    /// body, which throws inside the browser's `JSON.parse` with no way
    /// to tell it apart from success.
    /// `installed` is every plugin name the machine can currently see,
    /// so each offer can say whether there's anything left to do.
    static func listBakeries(home: URL, installed: Set<String>) -> BakeryListOutcome {
        do {
            let bakeries = try FileSystemBakeries(home: home).bakeries()
            let dict: [String: Any] = ["bakeries": bakeries.map { bakery in
                [
                    "id": bakery.id,
                    "commit": bakery.commit,
                    "plugins": PluginOffer.list(of: bakery, installed: installed).map {
                        ["name": $0.name, "installed": $0.installed]
                    },
                ]
            }]
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            return .ok(String(decoding: data, as: UTF8.self))
        } catch {
            return .failed("can't read the bakery registry: \(error)")
        }
    }

    // MARK: - install

    enum BakeryInstallOutcome: Equatable {
        case ok(String)
        /// The request may not be served at all — an untrusted bakery
        /// or a plugin it doesn't offer. Distinct from `failed`: there
        /// is nothing wrong, the answer is no.
        case refused(String)
        case failed(String)
    }

    /// Install one plugin from an already-trusted bakery.
    ///
    /// The bakery is resolved from the trusted list by id before
    /// anything else happens, so an untrusted id costs a dictionary
    /// lookup and nothing more — no ref parsed, no remote contacted, no
    /// directory touched. `BakeryInstall.install` then fetches the
    /// **pinned** commit, not today's HEAD, exactly as the CLI does.
    static func installFromBakery(
        bakery id: String, plugin: String, home: URL, install: BakeryInstall
    ) async -> BakeryInstallOutcome {
        let decision: InstallDecision
        do {
            decision = InstallDecision.decide(
                bakery: id, plugin: plugin, among: try FileSystemBakeries(home: home).bakeries()
            )
        } catch {
            return .failed("can't read the bakery registry: \(error)")
        }
        guard case .install(let bakery, let name) = decision else {
            // `refusal` is nil only for `.install`, which this guard
            // has already excluded.
            return .refused(decision.refusal ?? "refused")
        }

        do {
            let installed = try await install.install(
                ref: try BakeryRef.parse(bakery.url), requested: name
            )
            let dict: [String: Any] = [
                "installed": installed.map(\.name),
                "bakery": bakery.id,
                "commit": installed.first?.commit ?? bakery.commit,
            ]
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            return .ok(String(decoding: data, as: UTF8.self))
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - preview

    enum BakeryPreviewOutcome: Equatable {
        case ok(String)
        case failed(String)
    }

    static func previewBakery(reference: String, install: BakeryInstall) async -> BakeryPreviewOutcome {
        do {
            let ref = try BakeryRef.parse(reference)
            let preview = try await install.preview(ref)
            var dict: [String: Any] = [
                "commit": preview.commit,
                "alreadyTrusted": preview.alreadyTrusted,
                "url": ref.cloneURL,
                "plugins": preview.menu.entries.map { ["name": $0.name, "path": $0.path] },
            ]
            if let name = preview.menu.name { dict["name"] = name }
            if let description = preview.menu.description { dict["description"] = description }
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            return .ok(String(decoding: data, as: UTF8.self))
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - small shared helpers

    static func jsonResponse(_ json: String) -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(string: json))
        )
    }

    private static func jsonBody(_ request: Request) async throws -> [String: Any] {
        let buffer = try? await request.body.collect(upTo: 64 * 1024)
        let data = buffer.map { Data(buffer: $0) } ?? Data()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func stringField(_ request: Request, _ key: String) async throws -> String {
        (try await jsonBody(request))[key] as? String ?? ""
    }
}
