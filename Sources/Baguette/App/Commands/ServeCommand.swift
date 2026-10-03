import ArgumentParser
import Foundation

/// `baguette serve [--port 8421] [--host 127.0.0.1] [--device-set …]`
/// `             [--allowed-hosts …] [--plugin-dir …] [--no-plugins]`
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

    func run() async throws {
        // A device driven over `serve` is lost the moment Simulator.app
        // closes its window, which is easy to trigger by accident when
        // another toolchain opened Simulator.app for you. Warn, don't
        // rewrite Xcode's preferences behind the user's back.
        if let advisory = SimulatorAppPreferences.lifetime().advisory {
            warn(advisory)
        }

        let models = try LiveDeviceModels(rootURLs: DeviceModelRoots.standard())

        let plugins: any Plugins = noPlugins
            ? FileSystemPlugins(roots: [])
            : FileSystemPlugins.standard(extraRoots: pluginDirs.map { URL(fileURLWithPath: $0) })

        let simulators = CoreSimulators(deviceSetPath: deviceSet)
        // A camera owner whose disarm failed is released only once the
        // guest is confirmed gone from this device set.
        let cameraSessions = CameraSessions(guestTerminated: {
            try simulators.hasTerminated(udid: $0)
        })
        let server = Server(
            simulators: simulators,
            chromes: LiveChromes(
                store: FileSystemChromeStore(),
                rasterizer: CoreGraphicsPDFRasterizer()
            ),
            models: models,
            deviceRenderer: RealityKitDeviceRenderer(),
            plugins: plugins,
            host: host,
            port: port,
            allowedHosts: allowedHosts,
            cameraSessions: cameraSessions
        )
        for plugin in (try? plugins.all()) ?? [] {
            log("plugin: \(plugin.id) \(plugin.manifest.version)")
        }
        try await server.run()
    }
}
