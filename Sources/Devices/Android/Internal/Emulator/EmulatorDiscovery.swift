import Foundation

/// Where a running emulator's control API answers, from the file it writes
/// while it runs (`~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`):
/// its adb serial (`emulator-` + `port.serial`), its AVD, and its gRPC port
/// and token. An emulator started without gRPC has no endpoint, so none.
struct EmulatorDiscovery: Equatable, Sendable {
    let serial: String
    let avd: String
    let port: Int
    let token: String

    init(serial: String, avd: String, port: Int, token: String) {
        self.serial = serial
        self.avd = avd
        self.port = port
        self.token = token
    }

    init?(ini: String) {
        let values = Dictionary(ini.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            guard let equals = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<equals]), String(line[line.index(after: equals)...]))
        }, uniquingKeysWith: { first, _ in first })
        guard let console = values["port.serial"], let port = values["grpc.port"].flatMap(Int.init),
              let token = values["grpc.token"]
        else { return nil }
        self.init(serial: "emulator-\(console)", avd: values["avd.name"] ?? "", port: port, token: token)
    }
}
