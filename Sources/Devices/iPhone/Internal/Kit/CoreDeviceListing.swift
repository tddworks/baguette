import Foundation

/// Finding a device in CoreDevice's list. CoreDevice fills its list shortly
/// after the manager is made, and its "fully initialized" flag can stay
/// down for seconds after the phone is listed: take the phone as soon as
/// it appears, and wait (fifty looks, a tenth of a second apart) only
/// while it hasn't and the list isn't complete.
enum CoreDeviceListing {
    static func find<Device>(
        where matches: (Device) -> Bool,
        listed: () -> [Device],
        isComplete: () -> Bool,
        looks: Int = 50,
        pause: () -> Void = { usleep(100_000) }
    ) -> Device? {
        for _ in 0..<looks {
            if let found = listed().first(where: matches) { return found }
            if isComplete() { return nil }
            pause()
        }
        return nil
    }
}
