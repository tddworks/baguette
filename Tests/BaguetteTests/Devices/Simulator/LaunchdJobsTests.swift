import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// `launchctl list` inside a simulator prints one job per line —
/// `pid<TAB>status<TAB>label`, with `-` for a job that isn't running.
/// Reclaiming the input surface restarts backboardd and needs to know
/// when SpringBoard has come back with a *new* pid, so this parses just
/// enough of that table.
@Suite("LaunchdJobs")
struct LaunchdJobsTests {

    private let listing = """
        PID\tStatus\tLabel
        42499\t0\tcom.apple.backboardd
        37293\t0\tcom.apple.SpringBoard
        -\t0\tcom.apple.coredevice.dthidd
        -\t-9\tcom.apple.Preferences
        """

    @Test func `should find the pid of a running job by its label`() {
        let jobs = LaunchdJobs.parsing(listing)
        #expect(jobs.pid(of: "com.apple.SpringBoard") == 37293)
        #expect(jobs.pid(of: "com.apple.backboardd") == 42499)
    }

    @Test func `should find no pid when the job is not running`() {
        #expect(LaunchdJobs.parsing(listing).pid(of: "com.apple.coredevice.dthidd") == nil)
    }

    @Test func `should find no pid when the label is unknown`() {
        #expect(LaunchdJobs.parsing(listing).pid(of: "com.apple.nothing") == nil)
    }

    @Test func `should find no jobs when the listing is empty or missing`() {
        #expect(LaunchdJobs.parsing(nil).pid(of: "com.apple.SpringBoard") == nil)
        #expect(LaunchdJobs.parsing("").pid(of: "com.apple.SpringBoard") == nil)
    }
}
