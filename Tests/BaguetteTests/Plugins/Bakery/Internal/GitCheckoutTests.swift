import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Orchestration coverage for `GitCheckout` — argv assembly, the
/// non-interactive / no-submodule safety flags, and the
/// clone-then-rev-parse handshake. The real `git` spawn lives in
/// `HostSubprocess` (integration-only); every branch here runs through
/// `MockSubprocess`, mirroring `SimctlLocationTests`.
@Suite("GitCheckout")
struct GitCheckoutTests {

    final class Captures: @unchecked Sendable {
        var calls: [[String]] = []          // arguments of each spawn, in order
        var environments: [[String: String]?] = []
    }

    /// A mock that answers each spawn: clone exits 0, `rev-parse`
    /// prints the commit. Matched by whether the argv contains
    /// "rev-parse".
    /// `pinnedHead` models a clone whose default branch already sits on
    /// the pinned sha, so no extra fetch is needed. Leave it nil and
    /// `rev-parse` always answers `commit`.
    ///
    /// A successful clone creates the directory it was handed and puts
    /// a menu in it, because the real one does — and `GitCheckout` then
    /// has a tree to move into place.
    private func makeCheckout(
        commit: String = "abc123", cloneExit: Int32 = 0, pinnedHead: String? = nil
    ) -> (GitCheckout, Captures) {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any, workingDirectory: .any,
            environment: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willProduce { _, args, _, env, _, onBytes, onExit in
            captures.calls.append(args)
            captures.environments.append(env)
            if args.contains("rev-parse") {
                onBytes(Data("\(pinnedHead ?? commit)\n".utf8))
                onExit(0)
            } else {
                if args.first == "clone", cloneExit == 0, let target = args.last {
                    try? FileManager.default.createDirectory(
                        atPath: target, withIntermediateDirectories: true)
                    FileManager.default.createFile(
                        atPath: target + "/baguette.json", contents: Data("{}".utf8))
                }
                onExit(cloneExit)
            }
        }
        given(sub).terminate().willReturn()
        given(sub).kill().willReturn()
        return (GitCheckout(subprocess: { sub }), captures)
    }

    @Test func `should shallow-clone the bakery's url with no submodules`() async throws {
        let (git, captures) = makeCheckout()
        let ref = try BakeryRef.parse("acme/tools")
        let cache = try TempCache()
        let dest = cache.url.appendingPathComponent("github.com/acme/tools")
        _ = try await git.clone(ref, into: dest, at: nil)

        let clone = try #require(captures.calls.first)
        #expect(clone.contains("clone"))
        #expect(clone.contains("--depth"))
        #expect(clone.contains("1"))
        #expect(clone.contains(ref.cloneURL))
        // Never the live directory — see the staging tests below.
        #expect(!clone.contains(dest.path))
        // No submodule recursion — a bakery must not drag in arbitrary
        // submodule URLs.
        #expect(!clone.contains("--recurse-submodules"))
    }

    // MARK: - staging
    //
    // A clone that writes straight into the cache directory has to
    // empty it first and then leaves it half-written for the tens of
    // seconds a clone takes. A second add of the same bakery arriving
    // in that window deletes the tree the first clone is still writing
    // into, and git dies on its own vanished temp pack:
    //
    //   fatal: could not open '…/pack/tmp_pack_XXXXXX' for reading: …
    //   fatal: fetch-pack: invalid index-pack output
    //
    // So nothing may touch the live directory until there is a finished
    // checkout to put there.

    @Test func `should assemble a clone elsewhere and only then move it into place`() async throws {
        let home = try TempCache()
        let dest = home.url.appendingPathComponent("github.com/acme/tools")
        let (git, captures) = makeCheckout()

        let result = try await git.clone(try BakeryRef.parse("acme/tools"), into: dest, at: nil)

        let staged = try #require(captures.calls.first?.last)
        #expect(staged != dest.path)
        // Beside the destination, so the move in is a rename on one
        // volume rather than a copy.
        #expect(URL(fileURLWithPath: staged).deletingLastPathComponent().path
                == dest.deletingLastPathComponent().path)
        // The caller is handed the live directory, holding the clone.
        #expect(result.directory == dest)
        #expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("baguette.json").path))
        // And the staging directory is not left behind.
        #expect(!FileManager.default.fileExists(atPath: staged))
    }

    @Test func `should never let two clones of one bakery write into each other's checkout`() async throws {
        // The failure this whole arrangement exists to prevent: the
        // browser's preview and a terminal `bakery add` reaching the
        // same cache directory at once.
        let home = try TempCache()
        let dest = home.url.appendingPathComponent("github.com/acme/tools")
        let (first, firstCalls) = makeCheckout()
        let (second, secondCalls) = makeCheckout()
        let ref = try BakeryRef.parse("acme/tools")

        async let one = first.clone(ref, into: dest, at: nil)
        async let two = second.clone(ref, into: dest, at: nil)
        _ = try await (one, two)

        #expect(try #require(firstCalls.calls.first?.last)
                != #require(secondCalls.calls.first?.last))
        #expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("baguette.json").path))
    }

    @Test func `should replace the existing checkout when a bakery is cloned again`() async throws {
        // The ordinary second add. The new tree wins, and none of the
        // old one survives alongside it.
        let home = try TempCache()
        let dest = home.url.appendingPathComponent("github.com/acme/tools")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dest.appendingPathComponent("stale.txt").path, contents: Data())
        let (git, _) = makeCheckout()

        _ = try await git.clone(try BakeryRef.parse("acme/tools"), into: dest, at: nil)

        #expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("baguette.json").path))
        #expect(!FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("stale.txt").path))
    }

    @Test func `should name the requested directory, not the staging one, when a clone fails`() async throws {
        // The staging directory is an implementation detail with a
        // UUID in its name, and it's deleted on the way out. Reporting
        // it sends the reader looking for a path that never existed as
        // far as they're concerned — and this message lands in a
        // browser modal, not just a terminal.
        let cache = try TempCache()
        let dest = cache.url.appendingPathComponent("github.com/acme/tools")
        let sub = MockSubprocess()
        given(sub).run(
            executable: .any, arguments: .any, workingDirectory: .any,
            environment: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willProduce { _, args, _, _, _, onBytes, onExit in
            // git names the directory it was given in its own output.
            onBytes(Data("Cloning into '\(args.last ?? "")'...\nfatal: repository not found\n".utf8))
            onExit(128)
        }
        given(sub).terminate().willReturn()
        given(sub).kill().willReturn()
        let git = GitCheckout(subprocess: { sub })

        await #expect(throws: (any Error).self) {
            _ = try await git.clone(try BakeryRef.parse("acme/tools"), into: dest, at: nil)
        }
        do {
            _ = try await git.clone(try BakeryRef.parse("acme/tools"), into: dest, at: nil)
        } catch {
            let message = String(describing: error)
            #expect(!message.contains("incoming-"))
            #expect(message.contains(dest.path))
            #expect(message.contains("repository not found"))
        }
    }

    @Test func `should leave the existing checkout in place when a clone fails`() async throws {
        // Deleting first meant a network blip took the working copy
        // with it, so the next command reported a missing bakery
        // rather than a failed fetch.
        let home = try TempCache()
        let dest = home.url.appendingPathComponent("github.com/acme/tools")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dest.appendingPathComponent("baguette.json").path, contents: Data("{}".utf8))
        let (git, _) = makeCheckout(cloneExit: 128)

        await #expect(throws: (any Error).self) {
            _ = try await git.clone(try BakeryRef.parse("acme/tools"), into: dest, at: nil)
        }
        #expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("baguette.json").path))
    }

    /// A throwaway `~/.baguette/bakeries` to clone into, so these tests
    /// touch a real filesystem without touching the user's.
    final class TempCache {
        let url: URL
        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("baguette-bakeries-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    @Test func `should run git non-interactively so a bad url fails fast`() async throws {
        // GIT_TERMINAL_PROMPT=0 turns a private/missing repo into an
        // immediate failure instead of a hang on a credential prompt.
        let (git, captures) = makeCheckout()
        let cache = try TempCache()
        _ = try await git.clone(
            try BakeryRef.parse("acme/tools"), into: cache.url.appendingPathComponent("tools"), at: nil
        )
        #expect(captures.environments.first??["GIT_TERMINAL_PROMPT"] == "0")
    }

    @Test func `should pin the cloned commit as git rev-parse reports it`() async throws {
        let (git, captures) = makeCheckout(commit: "deadbeef")
        let cache = try TempCache()
        let result = try await git.clone(
            try BakeryRef.parse("acme/tools"), into: cache.url.appendingPathComponent("tools"), at: nil
        )
        #expect(result.commit == "deadbeef")
        // Second call resolves HEAD in the freshly cloned dir.
        #expect(captures.calls.last?.contains("rev-parse") == true)
    }

    @Test func `should fail rather than report a bogus commit when a clone fails`() async throws {
        let (git, _) = makeCheckout(cloneExit: 128)
        let cache = try TempCache()
        await #expect(throws: (any Error).self) {
            _ = try await git.clone(
                try BakeryRef.parse("acme/tools"), into: cache.url.appendingPathComponent("tools"), at: nil
            )
        }
    }

    // MARK: - pull

    @Test func `should fast-forward a pulled bakery in place and report the new commit`() async throws {
        // What `bakery update` runs. `--ff-only` so an update can never
        // produce a merge commit in a cache directory nobody looks at,
        // and `-C` so it operates on the clone rather than the cwd.
        let (git, captures) = makeCheckout(commit: "deadbee")
        let commit = try await git.pull(at: URL(fileURLWithPath: "/tmp/cache/acme/tools"))

        #expect(commit == "deadbee")
        #expect(captures.calls.first == [
            "-C", "/tmp/cache/acme/tools", "pull", "--depth", "1", "--ff-only",
        ])
        #expect(captures.calls.last == ["-C", "/tmp/cache/acme/tools", "rev-parse", "HEAD"])
    }

    @Test func `should fail rather than pin the old commit when a pull cannot fast-forward`() async throws {
        // A force-push upstream fails `--ff-only`. Reporting the stale
        // commit would record an update that didn't happen.
        let sub = MockSubprocess()
        given(sub).run(
            executable: .any, arguments: .any, workingDirectory: .any,
            environment: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willProduce { _, args, _, _, _, _, onExit in
            onExit(args.contains("pull") ? 1 : 0)
        }
        given(sub).terminate().willReturn()
        let git = GitCheckout(subprocess: { sub })

        await #expect(throws: (any Error).self) {
            _ = try await git.pull(at: URL(fileURLWithPath: "/tmp/cache/acme/tools"))
        }
    }

    // MARK: - asking the remote without cloning

    @Test func `should read the remote's head commit from git ls-remote`() async throws {
        // `bakery outdated` needs the remote's current commit, and
        // cloning every trusted bakery to find out would be absurd.
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any, workingDirectory: .any,
            environment: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willProduce { _, args, _, _, _, onBytes, onExit in
            captures.calls.append(args)
            onBytes(Data("9f8e7d6c5b4a\trefs/heads/main\n".utf8))
            onExit(0)
        }
        given(sub).terminate().willReturn()
        given(sub).kill().willReturn()
        let git = GitCheckout(subprocess: { sub })

        let head = try await git.head(of: try BakeryRef.parse("acme/tools"))
        #expect(head == "9f8e7d6c5b4a")
        let call = try #require(captures.calls.first)
        #expect(call.contains("ls-remote"))
        #expect(call.contains("https://github.com/acme/tools.git"))
    }

    // MARK: - the pin

    @Test func `should report whatever HEAD was when a clone is unpinned`() async throws {
        // First contact with a bakery: there's nothing to demand yet, so
        // we take the default branch and record what we got. That
        // recorded sha is what every later fetch is held to.
        let (git, captures) = makeCheckout(commit: "deadbeef")
        let cache = try TempCache()
        let result = try await git.clone(
            try BakeryRef.parse("acme/tools"), into: cache.url.appendingPathComponent("tools"), at: nil
        )
        #expect(result.commit == "deadbeef")
        #expect(captures.calls.allSatisfy { !$0.contains("checkout") })
    }

    @Test func `should fetch the pinned commit by name when the pinned branch has moved`() async throws {
        // The recorded commit has to *constrain* what we fetch, not just
        // describe it. A shallow clone of a moving branch hands back
        // whatever HEAD is today, so the pin is asked for by name and
        // checked out.
        let captures = Captures()
        let sub = MockSubprocess()
        let revParseCount = Counter()
        given(sub).run(
            executable: .any, arguments: .any, workingDirectory: .any,
            environment: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willProduce { _, args, _, _, _, onBytes, onExit in
            captures.calls.append(args)
            if args.contains("rev-parse") {
                // The branch has moved on; only after checking the pin
                // out are we standing on it.
                let landed = revParseCount.next() == 0 ? "f00d999" : "aaaa111"
                onBytes(Data("\(landed)\n".utf8))
            } else if args.first == "clone", let target = args.last {
                try? FileManager.default.createDirectory(
                    atPath: target, withIntermediateDirectories: true)
            }
            onExit(0)
        }
        given(sub).terminate().willReturn()
        given(sub).kill().willReturn()
        let git = GitCheckout(subprocess: { sub })
        let cache = try TempCache()

        let result = try await git.clone(
            try BakeryRef.parse("acme/tools"), into: cache.url.appendingPathComponent("tools"), at: "aaaa111"
        )
        #expect(result.commit == "aaaa111")
        let fetch = try #require(captures.calls.first { $0.contains("fetch") })
        #expect(fetch.contains("aaaa111"))
        #expect(captures.calls.contains { $0.contains("checkout") })
    }

    @Test func `should fetch nothing extra when a pinned clone already sits on the pin`() async throws {
        // The common case — the bakery hasn't moved since it was
        // trusted. Paying for a second network round-trip to confirm
        // what the clone already told us would be waste.
        let (git, captures) = makeCheckout(commit: "aaaa111", pinnedHead: "aaaa111")
        let cache = try TempCache()
        let result = try await git.clone(
            try BakeryRef.parse("acme/tools"), into: cache.url.appendingPathComponent("tools"), at: "aaaa111"
        )
        #expect(result.commit == "aaaa111")
        #expect(captures.calls.allSatisfy { !$0.contains("fetch") })
        #expect(captures.calls.allSatisfy { !$0.contains("checkout") })
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            let current = value
            value += 1
            return current
        }
    }

    @Test func `should fail rather than silently take HEAD when the remote won't serve the pin`() async throws {
        // The dangerous failure: the bakery force-pushed the pinned
        // commit away, and we quietly install whatever replaced it.
        let sub = MockSubprocess()
        given(sub).run(
            executable: .any, arguments: .any, workingDirectory: .any,
            environment: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willProduce { _, args, _, _, _, onBytes, onExit in
            if args.contains("rev-parse") {
                onBytes(Data("f00d999\n".utf8))   // never the pinned sha
                onExit(0)
            } else if args.contains("fetch") {
                onExit(128)                       // remote refuses the sha
            } else {
                onExit(0)
            }
        }
        given(sub).terminate().willReturn()
        given(sub).kill().willReturn()
        let git = GitCheckout(subprocess: { sub })

        await #expect(throws: GitCheckoutError.self) {
            _ = try await git.clone(
                try BakeryRef.parse("acme/tools"),
                into: URL(fileURLWithPath: "/tmp/x"), at: "aaaa111"
            )
        }
    }

    // MARK: - the deadline

    @Test func `should stop and report a git that stalls past its deadline`() async throws {
        // GIT_TERMINAL_PROMPT=0 only rules out a *credential* hang. A
        // remote that accepts the connection and then stops sending
        // leaves git running and this continuation unresumed — and
        // `POST /bakeries/preview` reaches clone, so one such remote
        // would hold a server task open indefinitely.
        let child = StalledChild()
        let git = GitCheckout(
            subprocess: { child },
            timeout: .milliseconds(20),
            grace: .milliseconds(20)
        )

        await #expect(throws: GitCheckoutError.self) {
            _ = try await git.pull(at: URL(fileURLWithPath: "/tmp/cache/acme/tools"))
        }
        #expect(child.terminated)
        #expect(child.killed)
    }

    /// A git that never finishes and ignores SIGTERM — the shape a
    /// stalled network fetch actually takes.
    final class StalledChild: Subprocess, @unchecked Sendable {
        private let lock = NSLock()
        private var onExit: (@Sendable (Int32) -> Void)?
        private(set) var terminated = false
        private(set) var killed = false

        func run(
            executable: URL, arguments: [String],
            onBytes: @escaping @Sendable (Data) -> Void,
            onExit: @escaping @Sendable (Int32) -> Void
        ) throws { store(onExit) }

        func run(
            executable: URL, arguments: [String], stdin: Data,
            onBytes: @escaping @Sendable (Data) -> Void,
            onExit: @escaping @Sendable (Int32) -> Void
        ) throws { store(onExit) }

        func run(
            executable: URL, arguments: [String], workingDirectory: URL,
            environment: [String: String], stdin: Data,
            onBytes: @escaping @Sendable (Data) -> Void,
            onExit: @escaping @Sendable (Int32) -> Void
        ) throws { store(onExit) }

        private func store(_ handler: @escaping @Sendable (Int32) -> Void) {
            lock.lock(); defer { lock.unlock() }
            onExit = handler
        }

        func terminate() {
            lock.lock(); defer { lock.unlock() }
            terminated = true
        }

        func kill() {
            lock.lock()
            killed = true
            let handler = onExit
            onExit = nil
            lock.unlock()
            handler?(-9)
        }
    }

    @Test func `should surface the spawn error when git cannot be started`() async throws {
        // Distinct from a non-zero exit — git never ran.
        struct SpawnRefused: Error {}
        let sub = MockSubprocess()
        given(sub).run(
            executable: .any, arguments: .any, workingDirectory: .any,
            environment: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willThrow(SpawnRefused())
        given(sub).terminate().willReturn()
        let git = GitCheckout(subprocess: { sub })

        await #expect(throws: SpawnRefused.self) {
            _ = try await git.pull(at: URL(fileURLWithPath: "/tmp/cache/acme/tools"))
        }
    }
}
