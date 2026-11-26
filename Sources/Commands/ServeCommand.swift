import BaguetteDevice
import BaguetteDeviceFamilies
import ArgumentParser
import Foundation
import WebRTCKit

/// `baguette serve [--port 8421] [--host 127.0.0.1] [--device-set …]`
/// `             [--allowed-hosts …] [--plugin-dir …] [--no-plugins]`
/// `             [--webrtc-ports 8190-8194] [--stun stun:host:port]`
/// `             [--turn turn:host:port --turn-user … --turn-pass …]`
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

    @Flag(name: .customLong("share-mac"), help: "Also show this Mac's displays as devices, watched and driven from the page. Anyone who can reach --host:--port sees and controls this Mac.")
    var shareMac: Bool = false

    @Option(name: .customLong("mac-frames"), help: "The folder Mac frame pictures are installed in, as <frame name>.png (default ~/Library/Application Support/baguette/Frames).")
    var macFrames: String?

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

    @Option(
        name: .customLong("stun"),
        help: "A STUN server to learn each WebRTC viewer's public address from, e.g. stun:stun.l.google.com:19302.",
        transform: { written in
            guard let server = STUNServer(url: written, resolve: HostResolver.ipv4) else {
                throw ValidationError("--stun takes stun:host[:port], a host that resolves to IPv4")
            }
            return server
        })
    var stun: STUNServer?

    @Option(name: .customLong("turn"), help: "A TURN server to relay WebRTC viewers through, e.g. turn:turn.example.com:3478 (with --turn-user and --turn-pass).")
    var turnURL: String?

    @Option(name: .customLong("turn-user"), help: "The TURN server's username.")
    var turnUser: String?

    @Option(name: .customLong("turn-pass"), help: "The TURN server's password.")
    var turnPass: String?

    /// The TURN server, as the three options name it.
    var turn: TURNServer? {
        guard let turnURL, let turnUser, let turnPass else { return nil }
        return TURNServer(url: turnURL, credentials: TURNCredentials(username: turnUser, password: turnPass),
                          resolve: HostResolver.ipv4)
    }

    func validate() throws {
        guard let turnURL else { return }
        guard turnUser != nil, turnPass != nil else { throw ValidationError("--turn needs --turn-user and --turn-pass") }
        guard turn != nil else {
            throw ValidationError("--turn takes turn:host[:port][?transport=udp], a host that resolves to IPv4: \(turnURL)")
        }
    }

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
