import BaguetteDevice
import Foundation

/// The Android family as a source of `Devices`: every emulator and phone
/// `adb devices -l` lists, read fresh on every call. A Mac without adb (see
/// `AdbLocation`) has none. Design: docs/features/android/design.md.
final class AndroidDevices: Devices, @unchecked Sendable {
    private let adb: Adb?

    init(adb: Adb? = Adb.installed) {
        self.adb = adb
    }

    var all: [any Device] {
        guard let adb, let listing = try? adb.runAndWait(["devices", "-l"]) else { return [] }
        return AdbListing.entries(in: String(decoding: listing, as: UTF8.self)).map(AndroidDevice.init)
    }

    func find(id: DeviceID) throws -> (any Device)? {
        all.first { $0.id == id }
    }
}

/// An Android emulator or phone as a `Device`, by its adb serial. The one
/// place deciding what an Android device can do — nothing yet: its screen and
/// input wait on the transport decided in docs/features/android/design.md.
struct AndroidDevice: Device {
    private let entry: AdbListing.Entry

    init(_ entry: AdbListing.Entry) {
        self.entry = entry
    }

    var id: DeviceID { DeviceID(entry.serial) }
    var name: String { entry.name }
    var state: DeviceState { entry.state }
    var kind: DeviceKind { DeviceKind(platform: .android, reality: entry.reality, model: entry.model) }
    var abilities: Abilities { Abilities(device: entry.name) }
}
