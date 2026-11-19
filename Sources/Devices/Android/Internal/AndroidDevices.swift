import BaguetteDevice
import Foundation

/// The Android family as a source of `Devices`: every emulator and phone
/// `adb devices -l` lists, and every installed AVD that isn't running (off),
/// read fresh on every call. An emulator is named by its AVD — the same across
/// boots, as a simulator's UDID — a phone by its serial. A Mac without adb has
/// none. Design: docs/features/android/design.md.
final class AndroidDevices: Devices, @unchecked Sendable {
    private let adb: AndroidTool?
    private let emulator: URL?
    private let runningEmulators: @Sendable () -> [RunningEmulator]
    private let installedAVDs: @Sendable () -> [String]

    init(adb: AndroidTool? = AndroidTool.adb,
         emulator: URL? = AndroidSDKLocation.emulator(),
         runningEmulators: @escaping @Sendable () -> [RunningEmulator] = { RunningEmulator.all() },
         installedAVDs: @escaping @Sendable () -> [String] = {
             (AndroidTool.emulator.flatMap { try? $0.runAndWait(["-list-avds"]) })
                 .map { AVDListing.names(in: String(decoding: $0, as: UTF8.self)) } ?? []
         }) {
        self.adb = adb
        self.emulator = emulator
        self.runningEmulators = runningEmulators
        self.installedAVDs = installedAVDs
    }

    var all: [any Device] {
        guard let adb, let listing = try? adb.runAndWait(["devices", "-l"]) else { return [] }
        let running = runningEmulators()
        let attached = AdbListing.entries(in: String(decoding: listing, as: UTF8.self)).map { entry in
            AndroidDevice(attached: entry, emulator: running.first { $0.serial == entry.serial },
                          adb: adb, emulatorTool: emulator)
        }
        let on = Set(attached.compactMap(\.avd))
        let off = installedAVDs().filter { !on.contains($0) }.map {
            AndroidDevice(off: $0, adb: adb, emulatorTool: emulator)
        }
        return attached + off
    }

    func find(id: DeviceID) throws -> (any Device)? {
        all.first { $0.id == id }
    }
}

/// An Android emulator or phone as a `Device`. The one place deciding what an
/// Android device can do: an emulator can be turned on and off; one whose
/// control API answers also has its screen and touchscreen through it, and
/// its buttons and keys through adb. A phone, nothing yet.
struct AndroidDevice: Device {
    let id: DeviceID
    let name: String
    let state: DeviceState
    let kind: DeviceKind
    /// The emulator's AVD; nil for a phone.
    let avd: String?
    private let serial: String?
    private let emulator: RunningEmulator?
    private let adb: AndroidTool
    private let emulatorTool: URL?

    /// A device adb lists: an emulator by its AVD when its discovery file names
    /// one, anything else by its serial.
    init(attached entry: AdbListing.Entry, emulator: RunningEmulator?, adb: AndroidTool, emulatorTool: URL?) {
        id = DeviceID(emulator?.avd ?? entry.serial)
        name = entry.name
        state = entry.state
        kind = DeviceKind(platform: .android, reality: entry.reality, model: entry.model)
        avd = emulator?.avd
        serial = entry.serial
        self.emulator = emulator
        self.adb = adb
        self.emulatorTool = emulatorTool
    }

    /// An installed AVD that isn't running.
    init(off avd: String, adb: AndroidTool, emulatorTool: URL?) {
        id = DeviceID(avd)
        name = avd
        state = .off
        kind = DeviceKind(platform: .android, reality: .emulated, model: avd)
        self.avd = avd
        serial = nil
        emulator = nil
        self.adb = adb
        self.emulatorTool = emulatorTool
    }

    var abilities: Abilities {
        var abilities = Abilities(device: name)
        if let avd, let emulatorTool {
            let (serial, adb) = (serial, adb)
            abilities.register(.power) { EmulatorPower(avd: avd, serial: serial, emulator: emulatorTool, adb: adb) }
        }
        guard let emulator, let serial else { return abilities }
        abilities.register(.screen) { EmulatorScreen(emulator: emulator) }
        // The touchscreen through the control API, made when the first role
        // asks — its screen's size and density asked of adb once; buttons and
        // keys through adb, which reaches every Android device.
        let adb = adb
        let input = OneInput { EmulatorInput.reaching(emulator, serial: serial, adb: adb) }
        let keys = AdbKeys(serial: serial, adb: adb)
        abilities.register(.touch) { input.value }
        abilities.register(.press) { keys }
        abilities.register(.key) { keys }
        abilities.register(.scroll) { input.value }
        abilities.register(.typing) { keys }
        return abilities
    }
}

extension EmulatorInput {
    /// The input of `emulator`, its screen's pixels and density asked of adb;
    /// a Pixel's (1080 × 2400 at 2.625) when adb can't say.
    static func reaching(_ emulator: RunningEmulator, serial: String, adb: AndroidTool) -> EmulatorInput {
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
