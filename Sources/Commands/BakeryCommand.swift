import BaguetteDevice
import ArgumentParser
import Foundation

/// `baguette bakery <add|list|outdated|remove|update>` — manage the
/// trusted sources plugins come from. A bakery is any git repo with a
/// `baguette.json` at its root.
///
/// Each subcommand's body is a static function over its collaborators
/// (installer, registry, checkout) and a `CommandOutput`; `run()` only
/// hands it the real ones.
struct BakeryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bakery",
        abstract: "Add and manage trusted sources of plugins",
        subcommands: [Add.self, List.self, Outdated.self, Remove.self, Update.self]
    )

    /// The `~/.baguette` root, shared by every subcommand and with the
    /// server + plugin scanner via `BaguetteHome`. A test hands a run a
    /// home of its own here.
    @TaskLocal static var home: URL = BaguetteHome.url

    static func installer() -> BakeryInstall {
        BakeryInstall(checkout: GitCheckout(), home: home)
    }

    static var registry: FileSystemBakeries { FileSystemBakeries(home: home) }

    // MARK: - add

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add", abstract: "Trust a bakery and record its menu"
        )

        @Argument(help: "owner/repo, owner/repo/plugin, or a git URL.") var reference: String
        @Flag(name: .customLong("yes"), help: "Accept the trust prompt without asking.")
        var accept = false

        func run() async throws {
            try await Self.add(
                reference: reference, accept: accept, using: BakeryCommand.installer(),
                confirm: TrustPrompt.confirm, output: .current)
        }

        static func add(
            reference: String, accept: Bool, using install: BakeryInstall,
            confirm: (String) -> Bool, output: CommandOutput
        ) async throws {
            let ref = try BakeryRef.parse(reference)

            // Clone + read the menu first so the user sees exactly what
            // they'd be trusting, and the prompt can show the real commit.
            let preview = try await install.preview(ref)
            output.say("\(preview.menu.name ?? reference) — offers: "
                + preview.menu.entries.map(\.name).joined(separator: ", "))

            switch TrustDecision.decide(alreadyTrusted: preview.alreadyTrusted, accepted: accept) {
            case .granted:
                break
            case .mustAsk:
                guard confirm(
                    TrustDecision.prompt(source: preview.menu.name ?? reference, commit: preview.commit)
                ) else {
                    output.warn("Not added.")
                    throw ExitCode.failure
                }
            }

            let bakery = try await install.add(ref)
            output.say("✓ added \(bakery.id) @ \(bakery.commit)")
            output.say("  install a plugin with: baguette plugin install \(preview.menu.entries.first?.name ?? "<name>")")
        }
    }

    // MARK: - list

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "List trusted bakeries"
        )

        func run() throws {
            try Self.list(registry: BakeryCommand.registry, output: .current)
        }

        static func list(registry: FileSystemBakeries, output: CommandOutput) throws {
            let bakeries = try registry.bakeries()
            guard !bakeries.isEmpty else {
                output.say("No bakeries added. Add one with: baguette bakery add owner/repo")
                return
            }
            for bakery in bakeries {
                output.say("\(bakery.id)  @\(bakery.commit)  offers: \(bakery.plugins.joined(separator: ", "))")
            }
        }
    }

    // MARK: - remove

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove", abstract: "Forget a bakery (installed plugins stay)"
        )

        @Argument(help: "owner/repo or a git URL.") var reference: String

        func run() throws {
            try Self.remove(reference: reference, registry: BakeryCommand.registry, output: .current)
        }

        static func remove(reference: String, registry: FileSystemBakeries, output: CommandOutput) throws {
            let ref = try BakeryRef.parse(reference)
            try registry.forget(bakeryID: ref.bakery.cacheSubpath)
            output.say("✓ forgot \(ref.bakery.cacheSubpath) (its installed plugins remain)")
        }
    }

    // MARK: - outdated

    struct Outdated: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "outdated",
            abstract: "Check trusted bakeries for commits newer than the ones you pinned"
        )

        func run() async throws {
            try await Self.outdated(registry: BakeryCommand.registry, checkout: GitCheckout(), output: .current)
        }

        static func outdated(
            registry: FileSystemBakeries, checkout: any Checkout, output: CommandOutput
        ) async throws {
            let trusted = try registry.bakeries()
            guard !trusted.isEmpty else { output.say("No bakeries added."); return }

            var updates: [BakeryUpdate] = []
            for bakery in trusted {
                // One unreachable remote must not stop the sweep — the
                // other bakeries still have answers worth printing.
                let head = try? await checkout.head(of: BakeryRef.parse(bakery.url))
                updates.append(
                    BakeryUpdate(id: bakery.id, pinned: bakery.commit, head: head)
                )
            }

            for update in updates { output.say(update.line) }

            let moved = updates.filter { $0.state == .available }
            guard !moved.isEmpty else { return }
            output.say("")
            output.say("Re-pin with: baguette bakery update <owner/repo>")
            output.say("Nothing changes on your machine until you do.")
        }
    }

    // MARK: - update

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update", abstract: "Re-pull bakeries and re-pin their commits"
        )

        @Argument(help: "owner/repo to update; omit to update all.") var reference: String?

        func run() async throws {
            try await Self.update(
                reference: reference, using: BakeryCommand.installer(),
                registry: BakeryCommand.registry, output: .current)
        }

        static func update(
            reference: String?, using install: BakeryInstall, registry: FileSystemBakeries,
            output: CommandOutput
        ) async throws {
            let targets: [Bakery]
            if let reference {
                let id = try BakeryRef.parse(reference).bakery.cacheSubpath
                targets = try registry.bakeries().filter { $0.id == id }
            } else {
                targets = try registry.bakeries()
            }
            guard !targets.isEmpty else { output.say("Nothing to update."); return }
            for bakery in targets {
                let updated = try await install.add(BakeryRef.parse(bakery.url))
                output.say("✓ \(updated.id) @ \(updated.commit)")
            }
        }
    }
}

/// A one-line y/N confirmation on stdin. Thin I/O — the *decision* is
/// `TrustDecision`; this just asks (`confirm`, in `Internal/System/`).
enum TrustPrompt {
    /// Whether an answer is consent: `y` or `yes`, in any case; no answer
    /// (end of input) is a refusal.
    static func accepts(_ answer: String?) -> Bool {
        guard let answer else { return false }
        return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
