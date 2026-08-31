import Foundation

/// The ordered conversation one companion socket holds with the host:
/// a `hello` must come first, attitude samples flow only after it, and
/// binary video frames flow only after a `format` declaration. A pure
/// state machine — the server feeds it text/binary and forwards the
/// events; every protocol violation surfaces as `.rejected` with a
/// reason instead of a silent drop.
struct TwinSession: Sendable {
    enum Event: Equatable, Sendable {
        case registered(TwinHello)
        case attitude(AttitudeSample)
        case streamOpened(VideoFormat)
        case frame(Data)
        case rejected(reason: String)
    }

    private(set) var hello: TwinHello?
    private(set) var format: VideoFormat?

    mutating func receive(text: String) -> Event {
        let envelope: TwinEnvelope
        do {
            envelope = try TwinEnvelope.parse(line: text)
        } catch {
            return .rejected(reason: "\(error)")
        }
        switch envelope {
        case .hello(let incoming):
            guard hello == nil else {
                return .rejected(reason: "already registered as \(hello!.udid)")
            }
            hello = incoming
            return .registered(incoming)
        case .attitude(let sample):
            guard hello != nil else {
                return .rejected(reason: "attitude before hello")
            }
            return .attitude(sample)
        case .format(let incoming):
            guard hello != nil else {
                return .rejected(reason: "format before hello")
            }
            format = incoming
            return .streamOpened(incoming)
        }
    }

    mutating func receive(binary data: Data) -> Event {
        guard hello != nil else {
            return .rejected(reason: "binary frame before hello")
        }
        guard format != nil else {
            return .rejected(reason: "binary frame before format")
        }
        return .frame(data)
    }
}
