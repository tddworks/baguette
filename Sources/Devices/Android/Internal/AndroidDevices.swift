import BaguetteDevice
import Foundation

/// The Android family as a source of `Devices`: every emulator and phone
/// `adb devices -l` lists, read fresh on every call. A Mac without adb (see
/// `AdbLocation`) has none. Design: docs/features/android/design.md.
final class AndroidDevices: Devices, @unchecked Sendable {
    private let adb: Adb?
    private let runningEmulators: @Sendable () -> [RunningEmulator]

    init(adb: Adb? = Adb.installed,
         runningEmulators: @escaping @Sendable () -> [RunningEmulator] = { RunningEmulator.all() }) {
        self.adb = adb
        self.runningEmulators = runningEmulators
    }

    var all: [any Device] {
        guard let adb, let listing = try? adb.runAndWait(["devices", "-l"]) else { return [] }
        let running = runningEmulators()
        return AdbListing.entries(in: String(decoding: listing, as: UTF8.self)).map { entry in
            AndroidDevice(entry, emulator: running.first { $0.serial == entry.serial }, adb: adb)
        }
    }

    func find(id: DeviceID) throws -> (any Device)? {
        all.first { $0.id == id }
    }
}

/// An Android emulator or phone as a `Device`, by its adb serial. The one
/// place deciding what an Android device can do: an emulator whose control
/// API answers has its screen and touchscreen through it, its buttons and
/// keys through adb; anything else, nothing yet.
struct AndroidDevice: Device {
    private let entry: AdbListing.Entry
    private let emulator: RunningEmulator?
    private let adb: Adb

    init(_ entry: AdbListing.Entry, emulator: RunningEmulator?, adb: Adb) {
        self.entry = entry
        self.emulator = emulator
        self.adb = adb
    }

    var id: DeviceID { DeviceID(entry.serial) }
    var name: String { entry.name }
    var state: DeviceState { entry.state }
    var kind: DeviceKind { DeviceKind(platform: .android, reality: entry.reality, model: entry.model) }

    var abilities: Abilities {
        var abilities = Abilities(device: entry.name)
        guard let emulator else { return abilities }
        abilities.register(.screen) { EmulatorScreen(emulator: emulator) }
        // The touchscreen through the control API, made when the first role
        // asks — its screen's size and density asked of adb once; buttons and
        // keys through adb, which reaches every Android device.
        let (serial, adb) = (entry.serial, adb)
        let input = OneInput { EmulatorInput.reaching(emulator, serial: serial, adb: adb) }
        let keys = AdbKeys(serial: serial, adb: adb)
        abilities.register(.touch) { input.value }
        abilities.register(.press) { keys }
        abilities.register(.key) { keys }
        abilities.register(.scroll) { input.value }
        return abilities
    }
}

extension EmulatorInput {
    /// The input of `emulator`, its screen's pixels and density asked of adb;
    /// a Pixel's (1080 × 2400 at 2.625) when adb can't say.
    static func reaching(_ emulator: RunningEmulator, serial: String, adb: Adb) -> EmulatorInput {
        let ask = { (what: String) in
            (try? adb.runAndWait(["-s", serial, "shell", "wm", what])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        let screen = AndroidScreenSize.pixels(fromWmSize: ask("size")) ?? Size(width: 1080, height: 2400)
        let pixelsPerPoint = AndroidScreenSize.pixelsPerPoint(fromWmDensity: ask("density")) ?? 2.625
        return EmulatorInput(connection: EmulatorConnection(to: emulator), screen: screen, pixelsPerPoint: pixelsPerPoint)
    }
}

/// A value made the first time it is asked for, then shared.
private final class OneInput: @unchecked Sendable {
    private let make: @Sendable () -> EmulatorInput
    private let lock = NSLock()
    private var made: EmulatorInput?

    init(_ make: @escaping @Sendable () -> EmulatorInput) { self.make = make }

    var value: EmulatorInput {
        lock.withLock {
            if let made { return made }
            let input = make()
            made = input
            return input
        }
    }
}
