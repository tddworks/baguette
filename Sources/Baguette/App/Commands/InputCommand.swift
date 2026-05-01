import ArgumentParser
import Foundation

struct InputCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "input",
        abstract: "Read newline-delimited JSON gestures from stdin, ack each on stdout"
    )

    @OptionGroup var options: DeviceOption

    func run() {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            Foundation.exit(1)
        }
        let dispatcher = GestureDispatcher(input: simulator.input())
        log("Input session started, reading from stdin")
        while let line = readLine() {
            print(dispatcher.dispatch(line: line))
            fflush(stdout)
        }
        log("stdin closed, input session ending")
    }
}
