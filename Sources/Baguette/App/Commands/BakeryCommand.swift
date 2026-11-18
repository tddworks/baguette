import BaguetteDevice
import ArgumentParser
import Foundation

/// `baguette bakery <add|list|outdated|remove|update>` — manage the
/// trusted sources plugins come from. A bakery is any git repo with a
/// `baguette.json` at its root.
struct BakeryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bakery",
        abstract: "Add and manage trusted sources of plugins",
        subcommands: [Add.self, List.self, Outdated.self, Remove.self, Update.self]
    )

    /// The `~/.baguette` root, shared by every subcommand and with the
    /// server + plugin scanner via `BaguetteHome`.
    static var home: URL { BaguetteHome.url }

    static func installer() -> BakeryInstall {
        BakeryInstall(checkout: GitCheckout(), home: home)
    }

    // MARK: - add

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add", abstract: "Trust a bakery and record its menu"
        )

        @Argument(help: "owner/repo, owner/repo/plugin, or a git URL.") var reference: String
        @Flag(name: .customLong("yes"), help: "Accept the trust prompt without asking.")
        var accept = false

        func run() async throws {
            let ref = try BakeryRef.parse(reference)
            let install = BakeryCommand.installer()

            // Clone + read the menu first so the user sees exactly what
            // they'd be trusting, and the prompt can show the real commit.
            let preview = try await install.preview(ref)
            print("\(preview.menu.name ?? reference) — offers: "
                  + preview.menu.entries.map(\.name).joined(separator: ", "))

            switch TrustDecision.decide(alreadyTrusted: preview.alreadyTrusted, accepted: accept) {
            case .granted:
                break
            case .mustAsk:
                guard TrustPrompt.confirm(
                    TrustDecision.prompt(source: preview.menu.name ?? reference, commit: preview.commit)
                ) else {
                    log("Not added.")
                    throw ExitCode.failure
                }
            }

            let bakery = try await install.add(ref)
            print("✓ added \(bakery.id) @ \(bakery.commit)")
            print("  install a plugin with: baguette plugin install \(preview.menu.entries.first?.name ?? "<name>")")
        }
    }

    // MARK: - list

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "List trusted bakeries"
        )

        func run() throws {
            let bakeries = try FileSystemBakeries(home: BakeryCommand.home).bakeries()
            guard !bakeries.isEmpty else {
                print("No bakeries added. Add one with: baguette bakery add owner/repo")
                return
            }
            for bakery in bakeries {
                print("\(bakery.id)  @\(bakery.commit)  offers: \(bakery.plugins.joined(separator: ", "))")
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
            let ref = try BakeryRef.parse(reference)
            try FileSystemBakeries(home: BakeryCommand.home).forget(bakeryID: ref.bakery.cacheSubpath)
            print("✓ forgot \(ref.bakery.cacheSubpath) (its installed plugins remain)")
        }
    }

    // MARK: - outdated

    struct Outdated: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "outdated",
            abstract: "Check trusted bakeries for commits newer than the ones you pinned"
        )

        func run() async throws {
            let registry = FileSystemBakeries(home: BakeryCommand.home)
            let checkout = GitCheckout()
            let trusted = try registry.bakeries()
            guard !trusted.isEmpty else { print("No bakeries added."); return }

            var updates: [BakeryUpdate] = []
            for bakery in trusted {
                // One unreachable remote must not stop the sweep — the
                // other bakeries still have answers worth printing.
                let head = try? await checkout.head(of: BakeryRef.parse(bakery.url))
                updates.append(
                    BakeryUpdate(id: bakery.id, pinned: bakery.commit, head: head)
                )
            }

            for update in updates { print(update.line) }

            let moved = updates.filter { $0.state == .available }
            guard !moved.isEmpty else { return }
            print("")
            print("Re-pin with: baguette bakery update <owner/repo>")
            print("Nothing changes on your machine until you do.")
        }
    }

    // MARK: - update

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update", abstract: "Re-pull bakeries and re-pin their commits"
        )

        @Argument(help: "owner/repo to update; omit to update all.") var reference: String?

        func run() async throws {
            let install = BakeryCommand.installer()
            let registry = FileSystemBakeries(home: BakeryCommand.home)
            let targets: [Bakery]
            if let reference {
                let id = try BakeryRef.parse(reference).bakery.cacheSubpath
                targets = try registry.bakeries().filter { $0.id == id }
            } else {
                targets = try registry.bakeries()
            }
            guard !targets.isEmpty else { print("Nothing to update."); return }
            for bakery in targets {
                let updated = try await install.add(BakeryRef.parse(bakery.url))
                print("✓ \(updated.id) @ \(updated.commit)")
            }
        }
    }
}

/// A one-line y/N confirmation on stdin. Thin I/O — the *decision* is
/// `TrustDecision`; this just asks.
enum TrustPrompt {
    static func confirm(_ message: String) -> Bool {
        print(message)
        print("Add it? [y/N] ", terminator: "")
        guard let line = readLine() else { return false }
        return ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
