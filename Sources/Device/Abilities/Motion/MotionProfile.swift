import Foundation

/// The per-kind constants that turn a `MotionKind` + speed into something
/// the injected dylib can integrate: how long a step is, how often one
/// lands, and how hard the device shakes while it happens.
///
/// ## Why the constants live here and not in the dylib
///
/// A pedometer accumulates monotonically and `CMMotionManager` delivers at
/// up to 100 Hz — neither can be fed sample-by-sample from the host
/// through a file. So the dylib synthesises locally. To keep that ObjC
/// side dumb (and therefore un-unit-testable only in the parts that don't
/// matter), **every judgement call lives in this value** and the dylib
/// does nothing but linear integration and a sine at the cadence it's
/// handed. Same division as the browser: the frontend sends, Swift decides.
public struct MotionProfile: Equatable, Sendable {

    /// Metres covered per step. Zero when the kind doesn't take steps —
    /// which is the signal to the dylib not to accrue any.
    public let strideMetres: Double

    /// Steps per second. Derived from speed and stride rather than fixed,
    /// so a brisk walk steps faster than an amble.
    public let cadenceHz: Double

    /// Peak synthetic acceleration, in g, layered onto the accelerometer /
    /// device-motion samples. Ordering across kinds is what matters: a run
    /// must read as more motion than a walk.
    public let gaitAmplitude: Double

    public init(kind: MotionKind, speed: Double) {
        let stride = Self.stride(for: kind)
        strideMetres = stride
        // A negative speed is CoreLocation's "unknown" — never let it drive
        // a negative cadence.
        cadenceHz = stride > 0 && speed > 0 ? speed / stride : 0
        gaitAmplitude = Self.amplitude(for: kind)
    }

    /// Stride length per kind. Cycling and driving deliberately take **no**
    /// steps: a pedometer counts neither pedal strokes nor road miles as
    /// steps, and an app charting a daily step total would be wrong if the
    /// simulator invented them.
    private static func stride(for kind: MotionKind) -> Double {
        switch kind {
        case .walking: return 0.75
        case .running: return 1.2
        case .stationary, .cycling, .automotive, .unknown: return 0
        }
    }

    /// Peak acceleration in g. Road vibration in a car is real but small;
    /// a device held still still registers a little hand tremor; "unknown"
    /// registers nothing at all, because inventing movement for a state we
    /// don't know is a lie the app can't detect.
    private static func amplitude(for kind: MotionKind) -> Double {
        switch kind {
        case .running: return 0.80
        case .walking: return 0.30
        case .cycling: return 0.15
        case .automotive: return 0.05
        case .stationary: return 0.01
        case .unknown: return 0
        }
    }
}
