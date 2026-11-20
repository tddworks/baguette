import BaguetteDevice
import ArgumentParser
import Foundation

/// `baguette serve [--port 8421] [--host 127.0.0.1] [--device-set …]`
/// `             [--allowed-hosts …] [--plugin-dir …] [--no-plugins]`
/// `             [--webrtc-ports 8190-8194]`
///
/// Boots the standalone simulator UI. Open `http://<host>:<port>/`
/// in a browser and the simulator picker loads — no SPA dependency,
/// no asc-cli host required.
struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the standalone simulator UI server"
    )

    @Option(name: .long, help: "Port to listen on")
    var port: Int = 8421

    @Option(name: .long, help: "Host / interface to bind to")
    var host: String = "127.0.0.1"

    @Option(name: .long, help: "Custom CoreSimulator device-set path")
    var deviceSet: String?

    @Option(name: .long, help: "Additional Host/Origin value to trust (repeatable; \"*.example.com\" matches subdomains)")
    var allowedHosts: [String] = []

    @Option(
        name: .customLong("plugin-dir"),
        help: "Extra directory of plugins; repeatable. Shadows installed plugins of the same name."
    )
    var pluginDirs: [String] = []

    @Flag(name: .customLong("no-plugins"), help: "Ignore every installed plugin, including bundled ones.")
    var noPlugins = false

    @Option(
        name: .customLong("webrtc-ports"),
        help: "UDP ports WebRTC viewers' media may use, e.g. 8190-8194 (default: any free port).",
        transform: { written in
            guard let ports = MediaPorts(parsing: written) else {
                throw ValidationError("--webrtc-ports takes a port or a range, like 8190-8194")
            }
            return ports
        })
    var mediaPorts: MediaPorts = .any

    func run() async throws {
        // Someone reads this log while driving a page, and no agent pays for it.
        setenv(Trace.variable, "1", 0)
        // A device driven over `serve` is lost the moment Simulator.app
        // closes its window, which is easy to trigger by accident when
        // another toolchain opened Simulator.app for you. Warn, don't
        // rewrite Xcode's preferences behind the user's back.
        if let advisory = SimulatorAppSettings.current.lifetime().advisory {
            warn(advisory)
        }
        try await serve(plugins: plugins)
    }

    /// The plugins this server offers: none with `--no-plugins`, else the
    /// bundled, installed and per-project ones, shadowed by `--plugin-dir`.
    var plugins: any Plugins {
        noPlugins
            ? FileSystemPlugins(roots: [])
            : FileSystemPlugins.standard(
                installedRoot: BakeryCommand.home.appendingPathComponent("plugins"),
                extraRoots: pluginDirs.map { URL(fileURLWithPath: $0) })
    }

    /// Say which plugins the server offers, one line each.
    static func announce(_ plugins: any Plugins) {
        for plugin in (try? plugins.all()) ?? [] {
            tell("plugin: \(plugin.id) \(plugin.manifest.version)")
        }
    }
}
