import Foundation

/// The screen a caller observed with `describe-ui`, handed back on
/// `input --expected-screen` so coordinate input is pinned to that
/// observation. Live dispatch still resolves the actual native binding;
/// the expectation only decides whether a fresh observation still
/// matches it.
struct ExpectedScreen: Sendable {
    let screen: AXScreen

    init(json: String) throws {
        let value = try JSONDecoder().decode(Wire.self, from: Data(json.utf8))
        guard let orientation = DeviceOrientation(wireName: value.orientation),
            value.width.isFinite, value.width > 0, value.height.isFinite, value.height > 0,
            value.target.pixelSize.width > 0, value.target.pixelSize.height > 0
        else { throw Failure.invalid }
        let panel: IntegratedPanel?
        switch value.target.litPanel {
        case nil: panel = nil
        case "primary": panel = .primary
        case "secondary": panel = .secondary
        default: throw Failure.invalid
        }
        screen = AXScreen(
            width: value.width, height: value.height, orientation: orientation,
            target: ScreenTarget(
                screenId: value.target.screenId, litPanel: panel,
                pixelSize: Size(
                    width: Double(value.target.pixelSize.width), height: Double(value.target.pixelSize.height))))
    }

    func requireMatches(_ current: AXScreen) throws {
        guard current == screen else { throw Failure.changed }
    }

    /// A gesture envelope that names its own `width` / `height` must
    /// name the observed native panel, or its coordinates are in some
    /// other space.
    func validateEnvelope(_ dict: [String: Any]) throws {
        guard dict["width"] != nil || dict["height"] != nil else { return }
        guard try Field.requiredSize(dict) == Size(width: screen.width, height: screen.height) else {
            throw Failure.coordinateSize
        }
    }

    enum Failure: LocalizedError, Equatable {
        case invalid, changed, coordinateSize

        var errorDescription: String? {
            switch self {
            case .invalid: return "expected screen must contain valid native points, orientation and an observed target"
            case .changed: return "screen target changed; observe again before sending new input"
            case .coordinateSize: return "input dimensions must match the observed native panel points"
            }
        }
    }

    private struct Wire: Decodable {
        let width: Double
        let height: Double
        let orientation: String
        let target: Target

        struct Target: Decodable {
            let screenId: UInt32
            let litPanel: String?
            let pixelSize: Pixels
        }

        struct Pixels: Decodable {
            let width: UInt32
            let height: UInt32
        }
    }
}

/// Serial input-session state: re-observes the screen before a contact
/// goes down or moves, and never before it lifts, so a contact that is
/// already down always releases on the binding that received it.
final class InputScreenGuard: @unchecked Sendable {
    let expected: ExpectedScreen
    private let observe: () throws -> AXScreen
    private(set) var errorDescription: String?

    init(expected: ExpectedScreen, observe: @escaping () throws -> AXScreen) {
        self.expected = expected
        self.observe = observe
    }

    func allows(_ phase: GesturePhase) -> Bool {
        if phase == .up { return true }
        do {
            try expected.requireMatches(observe())
            errorDescription = nil
            return true
        } catch {
            errorDescription = error.localizedDescription
            return false
        }
    }
}
