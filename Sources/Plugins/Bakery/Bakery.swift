import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// A trusted bakery — a git repo the user accepted as a source of
/// plugins. One record in `~/.baguette/bakeries.json`.
///
/// `id` is the ref's host/owner/repo cache subpath, the stable key a
/// bakery is looked up and forgotten by. `commit` is what was pinned
/// when it was added or last updated; `addedAt` is an ISO-8601 string
/// (stored as text so the JSON is human-readable and needs no date
/// strategy).
struct Bakery: Equatable, Sendable, Codable {
    let id: String
    let url: String
    let commit: String
    let plugins: [String]
    let addedAt: String
}

/// Provenance for one installed plugin — which bakery it came from and
/// at what commit. One record in `~/.baguette/installed.json`, kept
/// apart from the sources list because it answers a different question
/// ("where did this plugin come from") and outlives its bakery being
/// forgotten.
struct InstalledPlugin: Equatable, Sendable, Codable {
    let name: String
    let bakery: String
    let commit: String
}
