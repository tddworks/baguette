import ArgumentParser
import Foundation

/// `baguette notify --udid <UDID> [--bundle-id <id>] (--file <path> | --stdin) [--json]`
///
/// Delivers a remote notification to an app on a booted simulator, as if
/// APNs had sent it — the first step of a notification-driven test, before
/// `tap` opens it and `describe-ui` checks where the app landed.
///
/// Success is reported as what it is: the simulator accepted the
/// notification. `RemoteNotification.expectation` says what the user
/// should now see, because a foregrounded or unauthorised app shows no
/// banner at all and "delivered" is easily misread as "it worked".
struct NotifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "Deliver a remote notification to an app on the booted simulator"
    )

    @OptionGroup var options: DeviceOption

    @Option(name: .customLong("bundle-id"),
            help: "The app to notify (optional when the payload has \"Simulator Target Bundle\")")
    var bundleId: String?

    @Option(name: .long, help: "Path to the JSON payload")
    var file: String?

    @Flag(name: .long, help: "Read the JSON payload from standard input")
    var stdin = false

    @Flag(name: .long, help: "Emit the result as JSON on stdout")
    var json = false

    func validate() throws {
        guard (file != nil) != stdin else {
            throw ValidationError("Pass exactly one of --file <path> or --stdin")
        }
    }

    func run() async throws {
        let payload: Data
        if let file {
            guard let read = FileManager.default.contents(atPath: file) else {
                fail("cannot read \(file)")
            }
            payload = read
        } else {
            payload = FileHandle.standardInput.readDataToEndOfFile()
        }

        let notification: RemoteNotification
        do {
            notification = try RemoteNotification.from(json: payload, addressedTo: bundleId)
        } catch {
            fail(String(describing: error))
        }

        let device: any Device
        let notify: any Notify
        do {
            device = try options.devices.device(DeviceID(options.udid))
            notify = try device.require(.notify)
        } catch {
            fail(String(describing: error))
        }

        do {
            try await notification.deliver(to: notify)
        } catch {
            fail("notify failed: \(error)")
        }

        if json {
            print(notification.deliveredJSON)
        } else {
            log("Notified \(notification.app) on \(device.name). \(notification.expectation)")
        }
    }

    /// Report a failure on the channel the caller reads, then exit non-zero.
    private func fail(_ message: String) -> Never {
        if json {
            print(#"{"ok":false,"error":"\#(GestureDispatcher.jsonEscape(message))"}"#)
        } else {
            log(message)
        }
        Self.exit(withError: ExitCode.failure)
    }
}
