import Foundation

/// A remote notification a developer wants delivered to one app on the
/// device — what APNs would hand the phone, minus APNs. The payload is
/// the developer's own JSON (`aps` plus any app-defined fields such as
/// `deep_link`) and reaches the app byte for byte.
///
/// The value owns three laws, so the CLI, the serve route and the
/// browser panel can't drift on them:
///
/// - **Acceptable payload** — a top-level object carrying an `aps`
///   object, 4096 bytes at most (the APNs limit `simctl push` enforces).
///   Checked here so a malformed payload is named precisely rather than
///   surfacing as simctl's terse refusal.
/// - **Addressee** — the app named explicitly, else the payload's own
///   `Simulator Target Bundle`. Named beats payload, as in simctl.
/// - **What the user will see** — `presentation` / `expectation`.
///   Delivery succeeding only means the simulator took the notification;
///   whether a banner appears depends on `aps`, the app's authorisation
///   and whether it's frontmost. Saying so is the point of the feature.
public struct RemoteNotification: Equatable, Sendable {

    /// What iOS does with the notification on arrival, read off `aps`.
    public struct Presentation: Equatable, Sendable {
        public struct Alert: Equatable, Sendable {
            public let title: String?
            public let subtitle: String?
            public let body: String?

            public init(title: String?, subtitle: String?, body: String?) {
                self.title = title
                self.subtitle = subtitle
                self.body = body
            }
        }

        public let alert: Alert?
        public let badge: Int?
        public let playsSound: Bool

        /// Nothing for the user to see or hear — a background
        /// notification, or an empty `aps`.
        public var isSilent: Bool { alert == nil && badge == nil && !playsSound }

        public init(alert: Alert?, badge: Int?, playsSound: Bool) {
            self.alert = alert
            self.badge = badge
            self.playsSound = playsSound
        }
    }

    /// The APNs payload limit `simctl push` enforces.
    public static let maxPayloadBytes = 4096

    /// The payload key simctl reads an addressee from when none is named.
    public static let targetKey = "Simulator Target Bundle"

    /// Bundle identifier of the app the notification is for.
    public let app: String
    public let payload: Data
    public let presentation: Presentation

    /// `content-available: 1` — iOS wakes the app in the background to
    /// handle the notification.
    public let wakesInBackground: Bool

    /// Read a payload as a notification for `app` (or for the app the
    /// payload itself targets when `app` is nil or blank).
    public static func from(json: Data, addressedTo app: String?) throws -> RemoteNotification {
        guard let parsed = try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]) else {
            throw RemoteNotificationError.notJSON
        }
        guard let object = parsed as? [String: Any] else { throw RemoteNotificationError.notAnObject }
        guard let aps = object["aps"] as? [String: Any] else { throw RemoteNotificationError.missingAPS }
        guard json.count <= maxPayloadBytes else { throw RemoteNotificationError.tooLarge(bytes: json.count) }

        let named = app?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targeted = (object[targetKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let addressee = [named, targeted].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            throw RemoteNotificationError.noApp
        }

        return RemoteNotification(
            app: addressee,
            payload: json,
            presentation: Presentation(
                alert: alert(in: aps["alert"]),
                badge: (aps["badge"] as? NSNumber)?.intValue,
                playsSound: aps["sound"] != nil
            ),
            wakesInBackground: (aps["content-available"] as? NSNumber)?.intValue == 1
        )
    }

    /// `aps.alert` is either the body text alone or a dictionary.
    private static func alert(in value: Any?) -> Presentation.Alert? {
        if let body = value as? String {
            return Presentation.Alert(title: nil, subtitle: nil, body: body)
        }
        guard let alert = value as? [String: Any] else { return nil }
        return Presentation.Alert(
            title: alert["title"] as? String,
            subtitle: alert["subtitle"] as? String,
            body: alert["body"] as? String
        )
    }

    /// What a developer should expect once delivery succeeds — the one
    /// explanation every surface repeats, because "delivered" is easily
    /// misread as "the banner showed" or "the tap navigated".
    public var expectation: String {
        let accepted = "Delivered: accepted by the simulator, not proof of what the app did. "
        if !presentation.isSilent {
            return accepted
                + "iOS shows it only if the app is authorized for notifications. "
                + "While the app is in the foreground no banner appears unless it presents one "
                + "(userNotificationCenter(_:willPresent:)); background the app first to tap it."
        }
        if wakesInBackground {
            return accepted
                + "A background notification shows nothing; iOS wakes the app to handle it "
                + "(application(_:didReceiveRemoteNotification:fetchCompletionHandler:)), possibly later."
        }
        return accepted
            + "It has no alert, badge or sound, and without content-available: 1 it doesn't wake "
            + "the app in the background either."
    }

    /// The machine-readable report of a delivery, shared by
    /// `baguette notify --json` and the serve route so they can't drift:
    /// the app, what the notification presents, and `expectation`.
    public var deliveredJSON: String {
        var shown: [String: Any] = [
            "silent": presentation.isSilent,
            "sound": presentation.playsSound,
            "wakesInBackground": wakesInBackground,
        ]
        if let alert = presentation.alert {
            shown["alert"] = [
                "title": alert.title, "subtitle": alert.subtitle, "body": alert.body,
            ].compactMapValues { $0 }
        }
        if let badge = presentation.badge { shown["badge"] = badge }
        let report: [String: Any] = [
            "ok": true, "app": app, "presentation": shown, "expectation": expectation,
        ]
        let encoded = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) }
        return encoded ?? #"{"ok":true}"#
    }

    /// The argv tail handed to `xcrun simctl [--set <set>] push <udid> <app> <file>`.
    /// The app is always passed explicitly, so simctl never second-guesses
    /// the addressee resolved above.
    public func deliverArguments(udid: String, deviceSetPath: String? = nil, payloadFile: URL) -> [String] {
        ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["push", udid, app, payloadFile.path]
    }

    /// Tell-don't-ask: the device's notifications deliver it to its
    /// addressee.
    public func deliver(to notify: any Notify) async throws {
        try await notify.deliver(self)
    }

    public init(app: String, payload: Data, presentation: Presentation, wakesInBackground: Bool) {
        self.app = app
        self.payload = payload
        self.presentation = presentation
        self.wakesInBackground = wakesInBackground
    }
}

/// Why a payload can't be delivered. Each is the client's fault (a 400
/// on the serve route), worded so the developer can fix the payload.
public enum RemoteNotificationError: Error, Equatable, CustomStringConvertible {
    case notJSON
    case notAnObject
    case missingAPS
    case tooLarge(bytes: Int)
    case noApp

    public var description: String {
        switch self {
        case .notJSON:
            return "payload is not valid JSON"
        case .notAnObject:
            return "payload must be a JSON object at the top level"
        case .missingAPS:
            return #"payload needs an "aps" object, e.g. {"aps":{"alert":"Hi"}}"#
        case .tooLarge(let bytes):
            return "payload is \(bytes) bytes; APNs allows at most \(RemoteNotification.maxPayloadBytes)"
        case .noApp:
            return #"no app to notify: pass a bundle id, or add "\#(RemoteNotification.targetKey)" to the payload"#
        }
    }
}
