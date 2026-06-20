import ArgumentParser
import Foundation

/// `baguette logs --udid <UDID> [--level …] [--style …] [--predicate …] [--bundle-id …]`
///
/// Streams the booted simulator's unified log to stdout, line by
/// line, until SIGINT (Ctrl-C). Spawns `/usr/bin/log stream` inside
/// the simulator via `SimDevice.spawn…` — no `serve`, no
/// WebSocket, just a long-running pipe.
///
/// Composition: `baguette logs --udid X | grep Foo`,
/// `… > /tmp/sim.log`, `… | head -c 4096`, etc., all behave as
/// expected; stdout is line-buffered through `print`.
struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Stream the booted simulator's unified log to stdout"
    )

    @OptionGroup var options: DeviceOption

    @Option(help: "Minimum log level: debug | info | notice | error | fault")
    var level: String = "info"

    @Option(help: "Output style: default | compact | json | syslog")
    var style: String = "default"

    @Option(help: "NSPredicate string passed to `log stream --predicate` verbatim")
    var predicate: String?

    @Option(name: .customLong("bundle-id"),
            help: "Convenience: filter to a specific process by bundle / image name. ANDs with --predicate when both given.")
    var bundleId: String?

    func run() async throws {
        guard let lvl = LogFilter.Level(wire: level) else {
            log("logs: invalid --level '\(level)' (use debug | info | notice | error | fault)")
            throw ExitCode.failure
        }
        guard let sty = LogFilter.Style(wire: style) else {
            log("logs: invalid --style '\(style)' (use default | compact | json | syslog)")
            throw ExitCode.failure
        }

        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            throw ExitCode.failure
        }

        let filter = LogFilter(
            level: lvl, style: sty,
            predicate: predicate, bundleId: bundleId
        )
        let stream = simulator.logs()

        // SIGINT handler: clean stop + exit 0. We install a
        // DispatchSourceSignal so the default handler doesn't kill
        // us mid-pipe.
        signal(SIGINT, SIG_IGN)
        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())

        // One-shot continuation: whichever wakes first (SIGINT,
        // termination handler, or onTerminate) ends the await. The
        // `Once` helper enforces single-resume so we don't trip
        // the "continuation resumed twice" runtime trap.
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            private var cont: CheckedContinuation<Void, Never>?
            func install(_ c: CheckedContinuation<Void, Never>) {
                lock.lock(); defer { lock.unlock() }
                if fired { c.resume() } else { cont = c }
            }
            func fire() {
                lock.lock()
                if fired { lock.unlock(); return }
                fired = true
                let c = cont; cont = nil
                lock.unlock()
                c?.resume()
            }
        }
        let once = Once()

        sigSource.setEventHandler { [stream] in
            stream.stop()
            once.fire()
        }
        sigSource.resume()

        do {
            try stream.start(
                filter: filter,
                onLine: { line in
                    // Use FileHandle directly — `print` adds a
                    // trailing newline that doubles up after our
                    // line split.
                    if let data = (line + "\n").data(using: .utf8) {
                        try? FileHandle.standardOutput.write(contentsOf: data)
                    }
                },
                onTerminate: { error in
                    if let error {
                        log("logs: stream ended: \(error)")
                    }
                    once.fire()
                }
            )
        } catch {
            log("logs: \(error)")
            throw ExitCode.failure
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            once.install(c)
        }
    }
}
