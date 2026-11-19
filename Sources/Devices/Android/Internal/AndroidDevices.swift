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
        // The screen and touchscreen through the control API, when the
        // emulator has one — the touchscreen made when the first role asks,
        // its screen's size and density asked of adb once; buttons, keys and
        // typing through adb, which reaches every Android device.
        let adb = adb
        let keys = AdbKeys(serial: serial, adb: adb)
        let input = emulator.control == nil ? nil
            : OneInput { EmulatorInput.reaching(emulator, serial: serial, adb: adb) }
        if input != nil {
            abilities.register(.screen) { EmulatorScreen(emulator: emulator, screen: adb.screenPixels(of: serial)) }
        }
        if let input { abilities.register(.touch) { input.value } }
        abilities.register(.press) { keys }
        abilities.register(.key) { keys }
        if let input { abilities.register(.scroll) { input.value } }
        abilities.register(.typing) { keys }
        return abilities
    }
}
