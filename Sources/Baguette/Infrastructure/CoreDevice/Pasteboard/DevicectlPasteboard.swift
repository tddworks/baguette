import Foundation

/// A physical phone's general pasteboard, through `devicectl device
/// pasteboard`. `--quiet` keeps devicectl's progress lines out of what
/// `paste` prints.
struct DevicectlPasteboard: Pasteboard {
    let udid: String
    let devicectl: Devicectl

    func setText(_ text: String) async throws {
        _ = try await devicectl.run(verb(["copy"]), stdin: Data(text.utf8))
    }

    func text() async throws -> String {
        String(decoding: try await devicectl.run(verb(["paste"])), as: UTF8.self)
    }

    func syncFromHost() async throws {
        _ = try await devicectl.run(verb(["transfer", "to"]))
    }

    func syncToHost() async throws {
        _ = try await devicectl.run(verb(["transfer", "from"]))
    }

    private func verb(_ words: [String]) -> [String] {
        ["device", "pasteboard"] + words + ["--quiet", "--device", udid]
    }
}
