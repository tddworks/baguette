/// Whether a framebuffer capture is already queued and waiting to run.
///
/// SimulatorKit composites frames faster than a capture can complete —
/// reading `framebufferSurface` is a synchronous XPC round-trip to
/// CoreSimulatorService, not a local property read. Scheduling one capture
/// per notification therefore builds an unbounded queue of duplicates that
/// each pay that round-trip, and the queue grows faster than it drains as
/// soon as the round-trip is slower than the frame interval.
///
/// Coalescing fixes that: while a capture is queued, further notifications
/// fold into it, because every capture reads *the latest* surface anyway —
/// a duplicate would fetch the same frame. Once the queued capture starts
/// running, the next notification schedules a fresh one, so a newer frame
/// is never dropped.
struct PendingCapture {
    private var scheduled = false

    /// `true` when the caller must schedule a capture — nothing is pending.
    /// Repeat requests return `false` and coalesce onto the pending one.
    mutating func request() -> Bool {
        if scheduled { return false }
        scheduled = true
        return true
    }

    /// The queued capture has started. Notifications from here on describe
    /// frames it may not have read, so they schedule again.
    mutating func begin() {
        scheduled = false
    }
}
