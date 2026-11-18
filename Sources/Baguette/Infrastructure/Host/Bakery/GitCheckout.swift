import Foundation

/// `Checkout` backed by `/usr/bin/git`. The only bakery code that talks
/// to the network. Integration-only for the real spawn; the argv
/// assembly + the clone-then-rev-parse handshake are unit-covered
/// through `MockSubprocess`, exactly as `SimctlLocation` covers its
/// `xcrun` calls.
///
/// Safety flags are not optional here:
///   - `--depth 1` — a bakery is a working tree, not history.
///   - **no** `--recurse-submodules` — a malicious repo must not be
///     able to drag in arbitrary submodule URLs.
///   - `GIT_TERMINAL_PROMPT=0` — a private or missing repo fails fast
///     instead of hanging on a credential prompt.
///   - a **deadline** — the flag above only rules out a *credential*
///     hang. A remote that accepts the connection and then stops
///     sending leaves git running with nothing to time it out, and
///     `POST /bakeries/preview` reaches `clone`, so one such remote
///     would hold a server task open for as long as it cared to.
final class GitCheckout: Checkout, @unchecked Sendable {
    /// How long one git invocation may run. Generous: a cold shallow
    /// clone of a large bakery over a slow link is a legitimate minute.
    static let timeout: Duration = .seconds(120)

    /// How long git gets between the polite stop and the signal it
    /// can't refuse — room to unwind a partial fetch cleanly.
    static let grace: Duration = .seconds(2)

    private let git: URL
    private let subprocess: @Sendable () -> any Subprocess
    private let timeout: Duration
    private let grace: Duration

    init(
        git: URL = URL(fileURLWithPath: "/usr/bin/git"),
        subprocess: @escaping @Sendable () -> any Subprocess = { HostSubprocess() },
        timeout: Duration = GitCheckout.timeout,
        grace: Duration = GitCheckout.grace
    ) {
        self.git = git
        self.subprocess = subprocess
        self.timeout = timeout
        self.grace = grace
    }

    func clone(_ ref: BakeryRef, into directory: URL, at commit: String?) async throws -> CheckoutResult {
        // Assembled beside the live directory and moved in once it's
        // finished — never written in place.
        //
        // Cloning straight into `directory` means emptying it first and
        // then leaving it half-written for the tens of seconds a clone
        // takes. A second clone of the same bakery arriving in that
        // window — the browser's preview and a terminal `bakery add`,
        // or one impatient second click on Preview — empties the
        // directory the first one is still writing into, and git dies
        // on its own vanished temp pack:
        //
        //   fatal: could not open '…/pack/tmp_pack_XXXXXX' for reading:
        //          No such file or directory
        //   fatal: fetch-pack: invalid index-pack output
        //
        // A staging directory per clone means no operation ever deletes
        // a checkout in progress: the racers land in directories of
        // their own and whoever finishes last wins the swap. It also
        // means a clone that fails leaves the checkout you already had,
        // instead of a network blip taking the working copy with it.
        let parent = directory.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            ".\(directory.lastPathComponent).incoming-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // A clone that threw left a partial tree behind; a clone that
        // succeeded already moved it away, and removing nothing is free.
        defer { try? FileManager.default.removeItem(at: staging) }

        // Failures are reported against the directory the caller asked
        // for. Staging is an implementation detail with a UUID in its
        // name that is deleted on the way out, and this message reaches
        // a browser modal — naming it sends the reader looking for a
        // path that, as far as they are concerned, never existed.
        do {
            try await run(["clone", "--depth", "1", ref.cloneURL, staging.path])
            let landed = try await settle(on: commit, in: staging)
            try Self.moveIntoPlace(staging, at: directory)
            return CheckoutResult(directory: directory, commit: landed)
        } catch let error as GitCheckoutError {
            throw error.naming(directory.path, insteadOf: staging.path)
        }
    }

    func pull(at directory: URL) async throws -> String {
        try await run(["-C", directory.path, "pull", "--depth", "1", "--ff-only"])
        return try await revParse(at: directory)
    }

    func head(of ref: BakeryRef) async throws -> String {
        // `ls-remote` is a single ref advertisement — no objects, no
        // working tree, no cache directory touched.
        let out = try await run(["ls-remote", ref.cloneURL, "HEAD"])
        // "<sha>\trefs/heads/main" — take the sha off the first line.
        // An empty answer means the remote advertised nothing, which is
        // a failure to resolve rather than an empty commit.
        let first = out.split(whereSeparator: \.isNewline).first ?? ""
        let sha = first.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard !sha.isEmpty else {
            throw GitCheckoutError.gitFailed(
                arguments: ["ls-remote", ref.cloneURL, "HEAD"], status: 0,
                output: "remote advertised no HEAD"
            )
        }
        return sha
    }

    // MARK: - private

    /// Land the checkout in `directory` on the pinned commit, and
    /// report the sha it ends up standing on.
    private func settle(on commit: String?, in directory: URL) async throws -> String {
        let head = try await revParse(at: directory)
        // Unpinned: first contact, so whatever the default branch points
        // at is the answer, and the caller records it. Already on the
        // pin: the branch hasn't moved since we trusted it.
        guard let commit, head != commit else { return head }

        // The branch moved. Ask for the pinned object by name; a shallow
        // clone doesn't contain it, so it has to be fetched.
        try await run(["-C", directory.path, "fetch", "--depth", "1", "origin", commit])
        try await run(["-C", directory.path, "checkout", "--detach", "FETCH_HEAD"])

        // Verify rather than trust: `checkout FETCH_HEAD` after a fetch
        // that resolved something else would land us somewhere plausible
        // and wrong, which is precisely the case this exists to catch.
        let landed = try await revParse(at: directory)
        guard landed == commit else {
            throw GitCheckoutError.pinUnavailable(commit: commit, got: landed)
        }
        return landed
    }

    /// Swap a finished checkout in for whatever was there.
    ///
    /// Move first and ask questions on failure, rather than checking
    /// whether the destination exists and branching on the answer.
    /// Testing first leaves a window: two clones of one bakery both see
    /// nothing there, both move, and the loser fails with "couldn't be
    /// moved" having done all the work. Since concurrent clones are the
    /// whole reason for staging, that window is not hypothetical — the
    /// two-clone test caught it.
    ///
    /// `replaceItemAt` is the atomic exchange when something does hold
    /// the name, so a reader sees the whole old tree or the whole new
    /// one and never a directory mid-delete. It needs an original to
    /// replace, which is exactly why it can't be the first move.
    private static func moveIntoPlace(_ staging: URL, at directory: URL) throws {
        let files = FileManager.default
        do {
            try files.moveItem(at: staging, to: directory)
        } catch {
            // Either a checkout was already there, or another clone
            // landed one while this one was still cloning. The finished
            // tree replaces it either way; a failure with nothing there
            // is a real one and stays thrown.
            guard files.fileExists(atPath: directory.path) else { throw error }
            _ = try files.replaceItemAt(directory, withItemAt: staging)
        }
    }

    private func revParse(at directory: URL) async throws -> String {
        let out = try await run(["-C", directory.path, "rev-parse", "HEAD"])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run one git invocation, collecting stdout, throwing on non-zero
    /// — or on the deadline, whichever lands first.
    @discardableResult
    private func run(_ arguments: [String]) async throws -> String {
        let child = subprocess()
        let collected = Collected()
        let deadline = Deadline()
        let timeout = self.timeout
        let grace = self.grace

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    do {
                        try child.run(
                            executable: self.git,
                            arguments: arguments,
                            workingDirectory: URL(
                                fileURLWithPath: FileManager.default.currentDirectoryPath
                            ),
                            environment: self.environment,
                            stdin: Data(),
                            onBytes: { collected.append($0) },
                            onExit: { status in
                                deadline.noteChildLeft()
                                if deadline.hasPassed {
                                    // Killed by us, not failed by git —
                                    // say so, or the user goes hunting
                                    // for a repo problem that isn't one.
                                    continuation.resume(throwing: GitCheckoutError.timedOut(
                                        arguments: arguments, after: timeout
                                    ))
                                } else if status == 0 {
                                    continuation.resume(returning: collected.string)
                                } else {
                                    continuation.resume(throwing: GitCheckoutError.gitFailed(
                                        arguments: arguments, status: status,
                                        output: collected.string
                                    ))
                                }
                            }
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                // Cancelled means git already answered; `group.next()`
                // has taken that result and this task's value is
                // discarded, so there is nothing to signal.
                guard (try? await Task.sleep(for: timeout)) != nil else { return "" }
                deadline.pass()
                child.terminate()
                // SIGTERM first, then the one git cannot trap — without
                // the escalation a wedged child never reaches its exit
                // handler and this continuation never resumes.
                try? await Task.sleep(for: grace)
                if !deadline.childHasLeft { child.kill() }
                throw GitCheckoutError.timedOut(arguments: arguments, after: timeout)
            }

            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Who reached the finish line first — the clock, or git.
    private final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private var passed = false
        private var childLeft = false

        func pass() { lock.lock(); defer { lock.unlock() }; passed = true }
        var hasPassed: Bool { lock.lock(); defer { lock.unlock() }; return passed }

        func noteChildLeft() { lock.lock(); defer { lock.unlock() }; childLeft = true }
        var childHasLeft: Bool { lock.lock(); defer { lock.unlock() }; return childLeft }
    }

    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; data.append(bytes) }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}

enum GitCheckoutError: Error, Equatable, CustomStringConvertible {
    case gitFailed(arguments: [String], status: Int32, output: String)
    /// The deadline passed and we stopped git — distinct from git
    /// failing, because the remote, not the repo, is the suspect.
    case timedOut(arguments: [String], after: Duration)
    /// The pinned commit isn't what we ended up on. Its own case
    /// because the honest reading is "this bakery is not what you
    /// trusted any more", not "git had a problem".
    case pinUnavailable(commit: String, got: String)

    /// The same failure, told in terms of the directory the caller
    /// asked about. Substituted in both the argv and git's own output,
    /// because git echoes the path it was handed ("Cloning into '…'").
    func naming(_ directory: String, insteadOf staging: String) -> GitCheckoutError {
        switch self {
        case .gitFailed(let arguments, let status, let output):
            return .gitFailed(
                arguments: arguments.map { $0 == staging ? directory : $0 },
                status: status,
                output: output.replacingOccurrences(of: staging, with: directory)
            )
        case .timedOut(let arguments, let after):
            return .timedOut(
                arguments: arguments.map { $0 == staging ? directory : $0 }, after: after
            )
        case .pinUnavailable:
            // Names commits, not paths.
            return self
        }
    }

    var description: String {
        switch self {
        case .gitFailed(let arguments, let status, let output):
            let tail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let cmd = "git " + arguments.joined(separator: " ")
            return tail.isEmpty ? "\(cmd) exited \(status)" : "\(cmd) exited \(status): \(tail)"
        case .timedOut(let arguments, let after):
            return "git \(arguments.joined(separator: " ")) timed out after \(after)"
        case .pinUnavailable(let commit, let got):
            return """
                this bakery no longer serves commit \(commit) (got \(got)) — \
                it may have been rewritten or force-pushed. Re-add the bakery \
                to trust its current contents.
                """
        }
    }
}
