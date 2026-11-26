import BaguetteDevice
import BaguetteDeviceFamilies
import ArgumentParser
import Foundation

/// `baguette plugin <list|show|validate|run>`
///
/// Named `PluginsCommand` because it operates on the installed
/// collection; the CLI verb stays singular (`baguette plugin …`) to
/// match `git remote` / `docker plugin`. The Domain's `PluginCommand`
/// is a different thing — one contribution inside a manifest.
struct PluginsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Inspect and run installed plugins",
        subcommands: [List.self, Show.self, Validate.self, Run.self,
                      Install.self, Remove.self, Update.self]
    )

    /// Shared `--plugin-dir` for local authoring: point baguette at a
    /// directory of plugins without installing them. Mirrors Claude
    /// Code's own flag, which is the difference between a plugin
    /// system people can iterate against and one they can't.
    struct RootsOption: ParsableArguments {
        @Option(
            name: .customLong("plugin-dir"),
            help: "Extra directory of plugins; repeatable. Shadows installed plugins of the same name."
        )
        var pluginDirs: [String] = []

        var plugins: FileSystemPlugins {
            FileSystemPlugins.standard(
                installedRoot: BakeryCommand.home.appendingPathComponent("plugins"),
                extraRoots: pluginDirs.map { URL(fileURLWithPath: $0) }
            )
        }
    }

    // MARK: - subcommands

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "List installed plugins"
        )

        @OptionGroup var roots: RootsOption

        func run() throws {
            say(PluginsCommand.listing(try roots.plugins.all()))
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print what a plugin contributes, without running it"
        )

        @OptionGroup var roots: RootsOption
        @Argument(help: "Plugin name.") var name: String

        func run() throws {
            try Self.show(name: name, in: roots.plugins, output: .current)
        }

        static func show(name: String, in plugins: any Plugins, output: CommandOutput) throws {
            guard let plugin = try plugins.plugin(named: name) else {
                output.warn("No plugin named \(name)")
                throw ExitCode.failure
            }
            output.say(PluginsCommand.detail(plugin))
        }
    }

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "validate",
            abstract: "Check a plugin directory's manifest and say what's wrong"
        )

        @Argument(help: "Path to the plugin directory.") var path: String

        func run() throws {
            try Self.validate(directory: path, output: .current)
        }

        static func validate(directory path: String, output: CommandOutput) throws {
            let manifest = URL(fileURLWithPath: path)
                .appendingPathComponent(FileSystemPlugins.manifestFilename)
            guard let data = try? Data(contentsOf: manifest) else {
                output.warn("No \(FileSystemPlugins.manifestFilename) at \(path)")
                throw ExitCode.failure
            }
            switch PluginsCommand.validate(json: data) {
            case .valid(let name, let commands, let panels, let warnings):
                output.say("\(name) is valid — \(commands) command(s), \(panels) panel(s)")
                // Not a failure — the plugin works — but the author
                // asked what's wrong with it, and this is the answer.
                for warning in warnings { output.warn("warning: \(warning)") }
            case .invalid(let reason):
                output.warn("Invalid manifest: \(reason)")
                throw ExitCode.failure
            }
        }
    }

    /// `baguette plugin run a11y:audit --udid <UDID>`
    ///
    /// The same path the serve route takes, so a plugin can be
    /// developed and debugged entirely from the terminal before any
    /// browser is involved.
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run", abstract: "Run a plugin command by its namespaced id"
        )

        @OptionGroup var roots: RootsOption
        @Argument(help: "Namespaced command id, e.g. a11y:audit.") var command: String
        @Option(help: "Device the command targets.") var udid: String?
        @Option(help: "Origin of a running `baguette serve`.")
        var url: String = "http://127.0.0.1:8421"

        func run() async throws {
            let outcome = await PluginDispatch.run(
                qualifiedCommand: command,
                context: PluginDispatch.Context(
                    serverURL: url,
                    udid: udid,
                    // No serve session to mint against from the CLI;
                    // the plugin API rejects this, which is correct —
                    // a CLI-run plugin should be pointed at a real
                    // server with `--url` and its printed token.
                    token: ProcessInfo.processInfo.environment["BAGUETTE_TOKEN"] ?? ""
                ),
                plugins: roots.plugins
            )
            try Self.report(outcome, output: .current)
        }

        /// The plugin's answer on stdout — failing when it reported
        /// failure — or why it gave none.
        static func report(_ outcome: PluginDispatch.Outcome, output: CommandOutput) throws {
            switch outcome {
            case .ok(let result):
                output.say(result.json)
                if !result.ok { throw ExitCode.failure }
            default:
                output.warn(outcome.errorText ?? "plugin failed")
                throw ExitCode.failure
            }
        }
    }

    /// `baguette plugin install <name | owner/repo[/name]>`
    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install a plugin — a bare name from a trusted bakery, or owner/repo[/name] directly"
        )

        @Argument(help: "A plugin name, or owner/repo[/plugin] / a git URL.") var target: String
        @Flag(name: .customLong("yes"), help: "Accept the trust prompt for a new bakery without asking.")
        var accept = false

        func run() async throws {
            try await Self.install(
                target: target, accept: accept, using: BakeryCommand.installer(),
                confirm: TrustPrompt.confirm, output: .current)
        }

        static func install(
            target: String, accept: Bool, using install: BakeryInstall,
            confirm: (String) -> Bool, output: CommandOutput
        ) async throws {
            // A bare name (no `/`, not a URL) resolves across bakeries
            // already trusted — no new consent. Anything with a slash is
            // a direct reference, which may add a new bakery.
            let looksBare = !target.contains("/") && !target.contains(":")
            let installed: [InstalledPlugin]
            if looksBare {
                installed = try await install.installByName(target)
            } else {
                let ref = try BakeryRef.parse(target)
                let preview = try await install.preview(ref)
                switch TrustDecision.decide(alreadyTrusted: preview.alreadyTrusted, accepted: accept) {
                case .granted: break
                case .mustAsk:
                    guard confirm(
                        TrustDecision.prompt(source: preview.menu.name ?? target, commit: preview.commit)
                    ) else { output.warn("Not installed."); throw ExitCode.failure }
                }
                installed = try await install.install(ref: ref, requested: ref.plugin)
            }

            for plugin in installed {
                output.say("✓ installed \(plugin.name) @ \(plugin.commit) (from \(plugin.bakery))")
            }
            output.say("  refresh the browser to see it in the plugins rail")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove", abstract: "Uninstall a plugin"
        )

        @Argument(help: "Installed plugin name.") var name: String

        func run() throws {
            try BakeryCommand.installer().remove(name: name)
            say("✓ removed \(name)")
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update", abstract: "Re-install plugins from their bakery at its latest commit"
        )

        @Argument(help: "Plugin name to update; omit to update all installed plugins.") var name: String?

        func run() async throws {
            try await Self.update(
                name: name, using: BakeryCommand.installer(), registry: BakeryCommand.registry,
                output: .current)
        }

        static func update(
            name: String?, using install: BakeryInstall, registry: FileSystemBakeries,
            output: CommandOutput
        ) async throws {
            let targets = try registry.installed().filter { name == nil || $0.name == name }
            guard !targets.isEmpty else { output.say("Nothing to update."); return }

            let bakeries = try registry.bakeries()
            for plugin in targets {
                guard let bakery = bakeries.first(where: { $0.id == plugin.bakery }) else {
                    output.warn("skipping \(plugin.name): its bakery \(plugin.bakery) is no longer trusted")
                    continue
                }
                let ref = try BakeryRef.parse(bakery.url)
                let installed = try await install.install(ref: ref, requested: plugin.name)
                for p in installed { output.say("✓ \(p.name) @ \(p.commit)") }
            }
        }
    }

    // MARK: - text projections (pure)

    static func listing(_ plugins: [Plugin]) -> String {
        guard !plugins.isEmpty else {
            return """
                No plugins installed.

                Plugins are directories containing \(FileSystemPlugins.manifestFilename), \
                discovered from:
                  ~/.baguette/plugins/        installed
                  ./.baguette/plugins/        checked into this repo
                  --plugin-dir <path>         local authoring
                """
        }
        return plugins.map { plugin in
            let contributions = [
                plugin.manifest.commands.isEmpty
                    ? nil : "\(plugin.manifest.commands.count) command(s)",
                plugin.manifest.panels.isEmpty
                    ? nil : "\(plugin.manifest.panels.count) panel(s)",
            ].compactMap { $0 }.joined(separator: ", ")
            let summary = plugin.manifest.description.map { " — \($0)" } ?? ""
            return "\(plugin.id)  \(plugin.manifest.version)  \(contributions)\(summary)"
        }.joined(separator: "\n")
    }

    static func detail(_ plugin: Plugin) -> String {
        var lines = ["\(plugin.id) \(plugin.manifest.version)"]
        if let description = plugin.manifest.description { lines.append(description) }
        lines.append("root: \(plugin.root.path)")
        // The security-relevant line: exactly what this plugin may ask
        // baguette to do. Shown before you trust it.
        lines.append(
            "capabilities: "
            + (plugin.manifest.capabilities.isEmpty
                ? "none"
                : plugin.manifest.capabilities.map(\.rawValue).joined(separator: ", "))
        )

        if !plugin.manifest.commands.isEmpty {
            lines.append("")
            lines.append("commands:")
            for command in plugin.manifest.commands {
                lines.append(
                    "  \(plugin.qualified(command.id))  \(command.title)"
                    + "  [\(command.run.joined(separator: " "))]"
                )
            }
        }
        if !plugin.manifest.panels.isEmpty {
            lines.append("")
            lines.append("panels:")
            for panel in plugin.manifest.panels {
                let when = panel.when.map { " when \($0.rawValue)" } ?? ""
                lines.append("  \(plugin.qualified(panel.id))  \(panel.title)  [\(panel.icon.rawValue)]\(when)")
            }
        }
        return lines.joined(separator: "\n")
    }

    enum Validation: Equatable {
        /// Parsed. `warnings` are the non-fatal problems worth telling
        /// the author about — a mistyped icon still renders, as the
        /// default glyph, so this is the only place they'd find out.
        case valid(name: String, commands: Int, panels: Int, warnings: [String] = [])
        case invalid(reason: String)
    }

    static func validate(json data: Data) -> Validation {
        do {
            let manifest = try PluginManifest.parsing(json: data)
            return .valid(
                name: manifest.name,
                commands: manifest.commands.count,
                panels: manifest.panels.count,
                warnings: manifest.warnings.map(\.description)
            )
        } catch let error as PluginManifestError {
            return .invalid(reason: error.description)
        } catch {
            return .invalid(reason: "\(error)")
        }
    }
}

