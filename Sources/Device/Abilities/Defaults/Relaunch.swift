import Foundation

/// Whether an edit relaunches the app so it sees the change.
///
/// A running app sees a write in one of two ways. A key it watches — SwiftUI
/// observes every `@AppStorage` key — updates the moment cfprefsd reports
/// the write, with the app left where it was (measured: Dark → Light, same
/// pid, same screen). A key it read once into a property at startup is seen
/// only after a relaunch. `whenNeeded` asks the running app which it is
/// (`PreferenceLookups`) and relaunches only for the second; when no app can
/// say, it relaunches, since an unneeded relaunch costs a restart and a
/// missed one shows the old value as if the write had failed.
public enum Relaunch: Equatable, Sendable {
    case never
    case always
    case whenNeeded

    /// From a request: `true` / `"1"` / `"true"` always, `false` / absent
    /// never, `"whenNeeded"` as needed; anything else isn't a choice.
    public init?(wire value: Any?) {
        switch value {
        case nil: self = .never
        case let flag as Bool: self = flag ? .always : .never
        case "whenNeeded" as String: self = .whenNeeded
        case let text as String where ["1", "true"].contains(text): self = .always
        case let text as String where ["0", "false", ""].contains(text): self = .never
        default: return nil
        }
    }

    /// Whether writing `keys` in `suite` needs the app relaunched, given
    /// what the running app said it reads (`nil`: it couldn't say).
    public func needed(for keys: [String], in suite: PreferenceSuite, lookups: PreferenceLookups?) -> Bool {
        switch self {
        case .never: return false
        case .always: return true
        case .whenNeeded:
            guard let lookups else { return true }
            return keys.contains { !lookups.isLive($0, in: suite) }
        }
    }
}
