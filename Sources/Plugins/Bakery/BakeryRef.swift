import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// A reference the user types to point at a bakery — the git repo a
/// plugin comes from — optionally naming one plugin inside it.
///
/// Accepted forms, in the order a person is most likely to type them:
///   - `owner/repo`                 GitHub shorthand (the common case)
///   - `owner/repo/plugin`          a specific plugin in a multi-plugin bakery
///   - `github:owner/repo`          the shorthand host made explicit
///   - `https://host/owner/repo`    any git host
///   - `git@host:owner/repo.git`    the SSH form GitHub prints
///   - `file:///path/to/repo`       a local checkout (and the test path)
///
/// Parsing is pure — no network, no git — so every form is unit-tested
/// by feeding a string and asserting the resolved clone URL.
struct BakeryRef: Equatable, Sendable {
    let host: String
    let owner: String
    let repo: String
    /// A named plugin within the bakery, when the reference carried a
    /// third segment. `nil` means "the whole bakery".
    let plugin: String?
    /// The URL handed to `git clone`. Kept verbatim for URL forms so a
    /// user's SSH keys / file paths carry through untouched.
    let cloneURL: String

    /// The bakery this reference names, stripped of any plugin
    /// selection. Adding a source is the same act whether or not a
    /// plugin was named, so identity ignores `plugin`.
    var bakery: BakeryRef {
        plugin == nil ? self : BakeryRef(host: host, owner: owner, repo: repo, plugin: nil, cloneURL: cloneURL)
    }

    /// Where the clone lives under `~/.baguette/bakeries/`. Host- and
    /// owner-scoped so `acme/tools` on GitHub and on GitLab can't
    /// clobber one another.
    var cacheSubpath: String {
        let scope = host.isEmpty ? "local" : host
        return "\(scope)/\(owner)/\(repo)"
    }

    // MARK: - parsing

    static func parse(_ raw: String) throws -> BakeryRef {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BakeryRefError.empty }

        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            return try parseWebURL(text)
        }
        if text.hasPrefix("file://") {
            return try parseFileURL(text)
        }
        if text.contains("@") && text.contains(":") && !text.contains("://") {
            return try parseSCP(text)
        }

        // Shorthand: [github:]owner/repo[/plugin]
        var shorthand = text
        if shorthand.hasPrefix("github:") { shorthand = String(shorthand.dropFirst("github:".count)) }
        let parts = shorthand.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }) else {
            throw BakeryRefError.malformed(reference: raw)
        }
        let owner = parts[0]
        let repo = dropDotGit(parts[1])
        let plugin = parts.count == 3 ? parts[2] : nil
        return BakeryRef(
            host: "github.com", owner: owner, repo: repo, plugin: plugin,
            cloneURL: "https://github.com/\(owner)/\(repo).git"
        )
    }

    // MARK: - private

    private static func parseWebURL(_ text: String) throws -> BakeryRef {
        guard let url = URL(string: text), let host = url.host else {
            throw BakeryRefError.malformed(reference: text)
        }
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2 else { throw BakeryRefError.malformed(reference: text) }
        let owner = segments[0]
        let repo = dropDotGit(segments[1])
        // Scheme and port are carried through rather than normalised to
        // `https://<host>`: a self-hosted git on `:8443`, or one that
        // only speaks http, is a different endpoint from the same
        // hostname on 443, and substituting one for the other fails in
        // a way that names a URL the user never typed.
        //
        // `host` itself stays portless — it's the identity of the
        // source, and `cacheSubpath` turns it into a directory name.
        let scheme = url.scheme ?? "https"
        let authority = url.port.map { "\(host):\($0)" } ?? host
        return BakeryRef(
            host: host, owner: owner, repo: repo, plugin: nil,
            cloneURL: "\(scheme)://\(authority)/\(owner)/\(repo).git"
        )
    }

    private static func parseSCP(_ text: String) throws -> BakeryRef {
        // git@host:owner/repo.git
        guard let atRange = text.range(of: "@"),
              let colonRange = text.range(of: ":", range: atRange.upperBound..<text.endIndex) else {
            throw BakeryRefError.malformed(reference: text)
        }
        let host = String(text[atRange.upperBound..<colonRange.lowerBound])
        let path = String(text[colonRange.upperBound...])
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2, !host.isEmpty else { throw BakeryRefError.malformed(reference: text) }
        return BakeryRef(
            host: host, owner: segments[0], repo: dropDotGit(segments[1]), plugin: nil,
            cloneURL: text
        )
    }

    private static func parseFileURL(_ text: String) throws -> BakeryRef {
        guard let url = URL(string: text) else { throw BakeryRefError.malformed(reference: text) }
        let name = dropDotGit(url.lastPathComponent)
        guard !name.isEmpty else { throw BakeryRefError.malformed(reference: text) }
        return BakeryRef(host: "", owner: "local", repo: name, plugin: nil, cloneURL: text)
    }

    private static func dropDotGit(_ s: String) -> String {
        s.hasSuffix(".git") ? String(s.dropLast(4)) : s
    }
}

enum BakeryRefError: Error, Equatable, CustomStringConvertible {
    case empty
    case malformed(reference: String)

    var description: String {
        switch self {
        case .empty:
            return "empty bakery reference"
        case .malformed(let reference):
            return """
                can't read \"\(reference)\" as a bakery — expected owner/repo, \
                owner/repo/plugin, or a git URL
                """
        }
    }
}
