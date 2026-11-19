import Foundation

/// A running emulator, as the discovery file it writes while it runs
/// describes it (`~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`):
/// its adb serial (`emulator-` + `port.serial`), its AVD, and where its control
/// API answers — the gRPC port and token. An emulator started without gRPC
/// has no control API, so none.
struct RunningEmulator: Equatable, Sendable {
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
