import Foundation

/// How sure baguette claims to be about the motion it's reporting — the
/// value behind `CMMotionActivity.confidence`.
public enum MotionConfidence: String, Equatable, Sendable, CaseIterable {
    case low
    case medium
    case high

    /// `CMMotionActivityConfidence`'s raw value. Resolved here so the
    /// dylib copies a number rather than parsing a word.
    public var coreMotionValue: Int32 {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }
}

/// What baguette publishes into the simulator for the injected dylib to
/// read: *the device is doing this, at this speed, since this moment, and
/// this much had already accrued before it started.*
///
/// ## Why an intent and not a sample stream
///
/// `CMPedometer` counters must accumulate monotonically and
/// `CMMotionManager` delivers at up to 100 Hz. Neither can be fed
/// sample-by-sample from the host through a file, so the dylib integrates
/// locally from this description. `stepsBefore` / `distanceBefore` carry
/// the totals from earlier legs, which is what makes a pedometer
/// cumulative across a walk → stop → walk sequence instead of resetting
/// every time the joystick moves.
///
/// Everything the dylib needs is pre-resolved: `activityType` and
/// `confidence` are the raw CoreMotion numbers, and `profile` is the gait
/// policy. `kind` rides along as a word purely so the file is legible to
/// a human debugging it.
public struct MotionIntent: Equatable, Sendable {

    public let kind: MotionKind
    public let confidence: MotionConfidence
    /// Metres per second the device is being driven at.
    public let speed: Double
    /// Unix epoch seconds when this leg began. Host and guest share one
    /// wall clock, so the dylib can integrate against `NSDate`.
    public let startedAt: Double
    /// Steps accrued by earlier legs, before this one began.
    public let stepsBefore: Int
    /// Metres accrued by earlier legs, before this one began.
    public let distanceBefore: Double

    /// The gait constants for this kind and speed — derived, never stored,
    /// so the profile can't drift out of step with the kind.
    public var profile: MotionProfile { MotionProfile(kind: kind, speed: speed) }

    /// The raw `CLMotionActivity.type` the dylib writes into the struct.
    public var activityType: Int32 { kind.coreMotionType }

    /// What `motion stop` and a released joystick publish: not moving,
    /// while preserving everything already walked.
    public static func stationary(startedAt: Double, stepsBefore: Int,
                           distanceBefore: Double) -> MotionIntent {
        MotionIntent(kind: .stationary, confidence: .high, speed: 0,
                     startedAt: startedAt, stepsBefore: stepsBefore,
                     distanceBefore: distanceBefore)
    }

    public init(kind: MotionKind, confidence: MotionConfidence, speed: Double, startedAt: Double, stepsBefore: Int, distanceBefore: Double) {
        self.kind = kind
        self.confidence = confidence
        self.speed = speed
        self.startedAt = startedAt
        self.stepsBefore = stepsBefore
        self.distanceBefore = distanceBefore
    }
}

// MARK: - Wire encoding

public extension MotionIntent {

    private enum Key: String, CodingKey {
        case activityType, confidence, distanceBefore, kind, profile, speed
        case startedAt, stepsBefore
    }

    private enum ProfileKey: String, CodingKey {
        case cadenceHz, gaitAmplitude, strideMetres
    }

    /// Sorted-key JSON, so the bytes are stable and comparable in a test —
    /// the same discipline `SharedFrameLayout.encodeHeader` holds for the
    /// camera's binary header.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    init(decoding data: Data) throws {
        self = try JSONDecoder().decode(MotionIntent.self, from: data)
    }
}

extension MotionIntent: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(activityType, forKey: .activityType)
        try c.encode(confidence.coreMotionValue, forKey: .confidence)
        try c.encode(distanceBefore, forKey: .distanceBefore)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(speed, forKey: .speed)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(stepsBefore, forKey: .stepsBefore)
        var p = c.nestedContainer(keyedBy: ProfileKey.self, forKey: .profile)
        try p.encode(profile.cadenceHz, forKey: .cadenceHz)
        try p.encode(profile.gaitAmplitude, forKey: .gaitAmplitude)
        try p.encode(profile.strideMetres, forKey: .strideMetres)
    }
}

extension MotionIntent: Decodable {
    /// `profile` and `activityType` are deliberately **not** read back —
    /// they're derived from `kind` and `speed`, so a hand-edited file can't
    /// make the intent disagree with itself.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let kindWord = try c.decode(String.self, forKey: .kind)
        guard let kind = MotionKind(rawValue: kindWord) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown motion kind '\(kindWord)'")
        }
        let raw = try c.decode(Int32.self, forKey: .confidence)
        guard let confidence = MotionConfidence.allCases
            .first(where: { $0.coreMotionValue == raw }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .confidence, in: c, debugDescription: "unknown confidence '\(raw)'")
        }
        self.init(kind: kind,
                  confidence: confidence,
                  speed: try c.decode(Double.self, forKey: .speed),
                  startedAt: try c.decode(Double.self, forKey: .startedAt),
                  stepsBefore: try c.decode(Int.self, forKey: .stepsBefore),
                  distanceBefore: try c.decode(Double.self, forKey: .distanceBefore))
    }
}
