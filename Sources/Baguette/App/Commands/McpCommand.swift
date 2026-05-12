import ArgumentParser
import Foundation

/// `baguette mcp --udid <UDID>`
///
/// Starts an MCP (Model Context Protocol) server on stdin/stdout using
/// line-delimited JSON-RPC. Exposes baguette's full capability set as
/// MCP tools — `describe_ui`, `tap`, `type_text`, `press_key`, `swipe`,
/// `press_button`, `screenshot` — so any MCP client can drive a simulator
/// session through a single persistent process.
///
/// Same lifecycle as `baguette input`: one long-lived process, one
/// simulator, line-by-line request/response. The difference is the
/// wire protocol — JSON-RPC 2.0 with typed tool schemas instead of
/// bare gesture JSON with `{"ok": true}` acks.
struct McpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Start an MCP server for a simulator (JSON-RPC on stdin/stdout)"
    )

    @OptionGroup var options: DeviceOption

    func run() async throws {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            throw ExitCode.failure
        }
        let handler = McpHandler(simulator: simulator)
        log("MCP server started for \(options.udid)")

        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let response = await handler.handle(line: trimmed) {
                print(response)
                fflush(stdout)
            }
        }
        log("stdin closed, MCP server ending")
    }
}
