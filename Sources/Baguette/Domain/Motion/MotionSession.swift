import Foundation

/// Owns the motion feature's state for one simulator: which kind is being
/// published, what the pedometer has accrued, and whether a location walk
/// is allowed to drive it.
///
/// Mirrors `CameraSession` — `@MainActor`, one `@Mockable` collaborator,
/// failures reported through `lastError` rather than thrown at the caller.
///
/// ## Why motion is opt-in
///
/// Publishing arms a **simulator-wide** `DYLD_INSERT_LIBRARIES` that only
/// takes effect on the next app launch. Doing that as a silent side effect
/// of moving the device would be a nasty surprise, so `drive` — the hook a
/// location walk or route calls — does nothing until motion has been turned
/// on explicitly. Once it is on, moving the device drives it.
@MainActor
final class MotionSession {

    enum Phase: Equatable {
        case idle
        case publishing(MotionKind)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastError: String?

    /// Steps accrued so far, including the leg in flight at the last
    /// publish. Surfaced for the browser's readout.
    var steps: Int { ledger.steps }
    /// Metres accrued so far, on the same basis as `steps`.
    var metres: Double { ledger.metres }

    /// The speed currently being reported, in metres per second. Surfaced
    /// alongside the kind so a readout can show *why* it says what it says.
    var speed: Double { current?.speed ?? 0 }

    /// The smallest speed change worth a republish. Each publish costs a
    /// `launchctl` spawn and the joystick sends a fresh vector several
    /// times a second; this is the same epsilon `sim-location.js` already
    /// throttles its own sends with (`SPEED_EPSILON`).
    static let speedEpsilon = 0.1

    private let motion: any Motion
    private let now: @Sendable () -> Double

    private var ledger: MotionLedger = .empty
    private var current: MotionIntent?
    private var armedSimulator: (any Simulator)?

    init(motion: any Motion, now: @escaping @Sendable () -> Double = {
        Date().timeIntervalSince1970
    }) {
        self.motion = motion
        self.now = now
    }

    /// Turn motion on, or change what's being reported.
    func set(kind: MotionKind, confidence: MotionConfidence, speed: Double,
             on simulator: any Simulator) async {
        await publish(kind: kind, confidence: confidence, speed: speed, on: simulator)
    }

    /// Drive motion from a location walk or route speed.
    ///
    /// A no-op while motion is off — see the note on opt-in above. The kind
    /// is classified from the speed, so the preset a user picked in the
    /// browser's Walk mode is the kind the app under test observes.
    func drive(speed: Double, on simulator: any Simulator) async {
        guard case .publishing = phase else { return }
        let kind = MotionKind.from(speed: speed)
        // Skip a republish that would tell an app nothing new.
        if let current, current.kind == kind,
           abs(current.speed - speed) < Self.speedEpsilon {
            return
        }
        await publish(kind: kind, confidence: current?.confidence ?? .high,
                      speed: speed, on: simulator)
    }

    /// Park the device and stop future app launches reading motion.
    ///
    /// Parks **before** disarming: an app already running still has the
    /// dylib loaded, so the last thing it reads must say "not moving"
    /// rather than a stale walk. The totals already walked survive, because
    /// a pedometer that reset to zero would make an app's chart jump
    /// backwards.
    /// - Returns: `true` when the device was parked **and** disarmed. On
    ///   `false` the session is left intact so the caller can retry: a failed
    ///   disarm means the dylib is still loading into every app launched on
    ///   that simulator, and answering "stopped" would hide that.
    ///
    /// An explicit stop always parks and disarms, even when this session
    /// never recorded a start: the guest keeps reading the published intent
    /// across a server restart, and a first publish that wrote the intent
    /// before failing left it armed. The totals then resume from what the
    /// guest can already see, so the pedometer never jumps backwards.
    @discardableResult
    func stop(on simulator: any Simulator) async -> Bool {
        let target = armedSimulator ?? simulator
        armedSimulator = target
        adoptPublished()
        if current == nil {
            ledger = .resuming(from: motion.published(), at: now())
        } else {
            bankCurrentLeg()
        }
        let parked = MotionIntent.stationary(startedAt: now(), stepsBefore: ledger.steps,
                                            distanceBefore: ledger.metres)
        do {
            try await motion.publish(parked, on: target)
            // Adopt the parked intent the moment it lands, before the disarm
            // is attempted. If the disarm then fails, the device really is
            // stationary — a retry must bank *that*, and banking the walk it
            // replaced would add steps for time spent standing still.
            current = parked
            phase = .publishing(.stationary)
            try await motion.clear(on: target)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        phase = .idle
        current = nil
        armedSimulator = nil
        lastError = nil
        return true
    }

    private func publish(kind: MotionKind, confidence: MotionConfidence, speed: Double,
                         on simulator: any Simulator) async {
        adoptPublished()
        bankCurrentLeg()
        let intent = ledger.intent(kind: kind, confidence: confidence, speed: speed,
                                  startedAt: now())
        // A publish can write the shared intent and arm the dylib before it
        // reports failure, so this session owns the cleanup from here on.
        armedSimulator = simulator
        do {
            try await motion.publish(intent, on: simulator)
        } catch {
            lastError = error.localizedDescription
            return
        }
        current = intent
        phase = .publishing(kind)
        lastError = nil
    }

    /// Takes the guest's view of the leg in flight when it is a different
    /// activity from this session's. A publish can write the shared intent
    /// and then fail, so after a failed park the guest reads "stationary"
    /// while `current` still says "walking"; banking that walk on the retry
    /// would add steps for time spent standing still, and a failed change
    /// of kind would bank the old activity. The published intent is what
    /// the app saw, from the moment it was written.
    ///
    /// Only the activity is compared. A publish that failed *before*
    /// writing leaves the same activity published, with the `startedAt`
    /// the leg began at, while `current` was restarted at its last bank;
    /// adopting that would count the banked seconds twice.
    private func adoptPublished() {
        guard let current, let published = motion.published(),
            (published.kind, published.confidence, published.speed)
                != (current.kind, current.confidence, current.speed)
        else { return }
        self.current = published
    }

    /// Rolls the leg in flight into the running totals, so the next intent
    /// carries them forward.
    ///
    /// Banking **re-bases** the current intent to start now. On the success
    /// path that's invisible, because the intent is replaced a moment later.
    /// It matters when the publish that follows *fails*: the device carries
    /// on reporting the old intent, so something is still running, but the
    /// seconds just banked must not be banked again. Leaving `startedAt`
    /// alone counted the same leg on every subsequent bank and inflated the
    /// step total for the rest of the session.
    private func bankCurrentLeg() {
        guard let current else { return }
        let at = now()
        ledger = ledger.banking(current, at: at)
        self.current = MotionIntent(
            kind: current.kind, confidence: current.confidence, speed: current.speed,
            startedAt: at, stepsBefore: ledger.steps, distanceBefore: ledger.metres)
    }
}
