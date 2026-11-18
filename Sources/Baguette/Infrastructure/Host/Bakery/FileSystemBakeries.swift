import Foundation

/// The `~/.baguette` registry — the trusted-bakeries list
/// (`bakeries.json`) and the installed-plugin provenance
/// (`installed.json`). Two files, one type, because they're written
/// and read together during install / remove.
///
/// `home` is injectable so the suite writes into a throwaway temp
/// directory, exactly as `FileSystemChromeStore` and `FileSystemPlugins`
/// take their roots. A missing file reads as empty — a fresh install
/// has neither, and that's the normal first-run state, not an error.
struct FileSystemBakeries {
    let home: URL

    /// Every mutator here is a read-modify-write over a whole file, and
    /// `baguette serve` handles requests concurrently — two overlapping
    /// installs would otherwise both read the old array, and the second
    /// write would silently drop the first. `.atomic` prevents a *torn*
    /// file; it does nothing about a lost update.
    ///
    /// Process-wide rather than per-instance because callers build a
    /// `FileSystemBakeries` at each use site, so an instance lock would
    /// guard nothing. Two separate `baguette` processes writing at once
    /// remain unserialised — that needs file locking, and the case this
    /// protects is concurrent requests inside one server.
    private static let registryLock = NSLock()

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".baguette")) {
        self.home = home
    }

    private var bakeriesFile: URL { home.appendingPathComponent("bakeries.json") }
    private var installedFile: URL { home.appendingPathComponent("installed.json") }

    // MARK: - trusted sources

    func bakeries() throws -> [Bakery] {
        try locked { try load([Bakery].self, from: bakeriesFile) }
    }

    /// Add or re-pin a bakery. Re-recording the same `id` updates it in
    /// place rather than stacking a duplicate, so an `update` re-pins
    /// cleanly.
    func record(_ bakery: Bakery) throws {
        try locked {
            var all = try load([Bakery].self, from: bakeriesFile).filter { $0.id != bakery.id }
            all.append(bakery)
            try save(all.sorted { $0.id < $1.id }, to: bakeriesFile)
        }
    }

    func forget(bakeryID: String) throws {
        try locked {
            let kept = try load([Bakery].self, from: bakeriesFile).filter { $0.id != bakeryID }
            try save(kept, to: bakeriesFile)
        }
    }

    // MARK: - installed-plugin provenance

    func installed() throws -> [InstalledPlugin] {
        try locked { try load([InstalledPlugin].self, from: installedFile) }
    }

    func recordInstalled(_ plugin: InstalledPlugin) throws {
        try locked {
            var all = try load([InstalledPlugin].self, from: installedFile)
                .filter { $0.name != plugin.name }
            all.append(plugin)
            try save(all.sorted { $0.name < $1.name }, to: installedFile)
        }
    }

    func forgetInstalled(name: String) throws {
        try locked {
            let kept = try load([InstalledPlugin].self, from: installedFile)
                .filter { $0.name != name }
            try save(kept, to: installedFile)
        }
    }

    // MARK: - private

    /// One read-modify-write, start to finish, with nobody else in the
    /// file. `load` / `save` are the unlocked halves so a mutator can
    /// hold the lock across both.
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        Self.registryLock.lock()
        defer { Self.registryLock.unlock() }
        return try body()
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T where T: RangeReplaceableCollection {
        // A *missing* file is the normal first-run state. A file that
        // exists but can't be read is not, and must never be reported
        // as empty: the next mutator writes back what it just read, so
        // one unreadable moment would erase every trusted bakery and
        // the whole installed-plugin provenance.
        guard FileManager.default.fileExists(atPath: url.path) else { return T() }
        return try JSONDecoder().decode(T.self, from: try Data(contentsOf: url))
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
