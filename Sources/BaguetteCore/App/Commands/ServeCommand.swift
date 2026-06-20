import ArgumentParser
import Foundation

/// `baguette serve [--port 8421] [--host 127.0.0.1] [--device-set …]`
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

    func run() async throws {
        let server = Server(
            simulators: CoreSimulators(deviceSetPath: deviceSet),
            chromes: LiveChromes(
                store: FileSystemChromeStore(),
                rasterizer: CoreGraphicsPDFRasterizer()
            ),
            host: host,
            port: port
        )
        try await server.run()
    }
}
