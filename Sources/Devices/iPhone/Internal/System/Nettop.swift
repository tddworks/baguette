import Foundation

/// `nettop`, asked for `remoted`'s TCP connections — among them the one it
/// holds open to each phone's service directory. Integration-only; reading
/// the port out is `ServiceDirectory.port(fromNettop:phone:)`.
enum Nettop {
    static func remotedConnections() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-L", "1", "-m", "tcp", "-n", "-x", "-p", "remoted", "-J", "state"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }
}
