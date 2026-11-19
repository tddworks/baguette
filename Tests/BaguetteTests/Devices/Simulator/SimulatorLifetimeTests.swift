import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// `SimulatorLifetime` is the value-typed reading of Simulator.app's
/// device lifetime policy — the two preferences Apple groups under
/// "Simulator lifetime" in `Simulator.app/Contents/Resources/
/// Settings.bundle/Root.plist`:
///
///   DetachOnWindowClose — "When closing a simulator's window leave it running"
///   DetachOnAppQuit     — "When quitting leave simulators running"
///
/// Both default to `false`, which is why a device booted headlessly by
/// baguette dies the moment someone closes its window in Simulator.app.
///
/// This is AGENTS.md's one-shot-fetch split: the irreducible call is a
/// pair of `CFPreferences` reads/writes in Infrastructure, and
/// everything downstream of the fetched plist lives here as a pure
/// factory — so no `@Mockable` collaborator is needed.
@Suite("SimulatorLifetime")
struct SimulatorLifetimeTests {

    // MARK: - Reading

    @Test func `should read Apple's shutdown default when no preference is set`() {
        // A machine that has never touched these keys has no entry at
        // all — not `false`. Absence must read as shutdown, because
        // that is what Simulator.app actually does.
        let lifetime = SimulatorLifetime.from(plist: [:])
        #expect(lifetime == .appleDefault)
        #expect(lifetime.detachOnWindowClose == false)
        #expect(lifetime.detachOnAppQuit == false)
    }

    @Test func `should read fully detached when both preferences are set`() {
        let lifetime = SimulatorLifetime.from(plist: [
            "DetachOnWindowClose": NSNumber(value: true),
            "DetachOnAppQuit": NSNumber(value: true),
        ])
        #expect(lifetime == .detached)
    }

    @Test func `should read a defaults-write boolean preference either way`() {
        // `defaults write … -bool YES` stores a CFBoolean, which bridges
        // to NSNumber on the way back out of CFPreferences.
        let on = SimulatorLifetime.from(plist: ["DetachOnWindowClose": NSNumber(value: true)])
        #expect(on.detachOnWindowClose == true)

        let off = SimulatorLifetime.from(plist: ["DetachOnWindowClose": NSNumber(value: false)])
        #expect(off.detachOnWindowClose == false)
    }

    @Test func `should read a string preference written without -bool the way Simulator app would`() {
        // `defaults write … DetachOnAppQuit YES` (no -bool) stores the
        // *string* "YES". `-[NSUserDefaults boolForKey:]` still reads
        // that as true, so reporting it as false would misdescribe what
        // Simulator.app is going to do.
        for truthy in ["YES", "true", "1"] {
            #expect(SimulatorLifetime.from(plist: ["DetachOnAppQuit": truthy]).detachOnAppQuit == true,
                    "expected \(truthy) to read as true")
        }
        for falsy in ["NO", "false", "0"] {
            #expect(SimulatorLifetime.from(plist: ["DetachOnAppQuit": falsy]).detachOnAppQuit == false,
                    "expected \(falsy) to read as false")
        }
    }

    @Test func `should fall back to shutdown when a preference holds an unreadable value`() {
        // Garbage in the domain shouldn't be reported as "you're safe".
        let lifetime = SimulatorLifetime.from(plist: ["DetachOnWindowClose": ["nested": 1]])
        #expect(lifetime.detachOnWindowClose == false)
    }

    @Test func `should read each lifetime preference independently`() {
        let lifetime = SimulatorLifetime.from(plist: ["DetachOnWindowClose": NSNumber(value: true)])
        #expect(lifetime.detachOnWindowClose == true)
        #expect(lifetime.detachOnAppQuit == false)
    }

    // MARK: - Surviving Simulator.app

    @Test func `should keep a device alive past Simulator app only when both routes detach`() {
        #expect(SimulatorLifetime.detached.survivesSimulatorApp == true)
        #expect(SimulatorLifetime.appleDefault.survivesSimulatorApp == false)

        // Detaching on one route alone still loses the device by the
        // other — closing the window and quitting the app are separate
        // ways to lose a booted simulator.
        let closeOnly = SimulatorLifetime(detachOnWindowClose: true, detachOnAppQuit: false)
        #expect(closeOnly.survivesSimulatorApp == false)

        let quitOnly = SimulatorLifetime(detachOnWindowClose: false, detachOnAppQuit: true)
        #expect(quitOnly.survivesSimulatorApp == false)
    }

    // MARK: - Writing

    @Test func `should write both preferences under Simulator app's own key names`() {
        // These spellings are the contract with Simulator.app; a typo
        // here writes a key nothing reads.
        let patch = SimulatorLifetime.detached.plistPatch
        #expect(patch["DetachOnWindowClose"] == true)
        #expect(patch["DetachOnAppQuit"] == true)
        #expect(patch.count == 2)
    }

    @Test func `should write both preferences explicitly as false when reverting`() {
        // Reverting must write `false`, not remove the keys — a user who
        // opted in should see the revert land in `defaults read`.
        let patch = SimulatorLifetime.appleDefault.plistPatch
        #expect(patch["DetachOnWindowClose"] == false)
        #expect(patch["DetachOnAppQuit"] == false)
    }

    @Test func `should read back the same policy that was written`() {
        for lifetime in [SimulatorLifetime.detached,
                         .appleDefault,
                         SimulatorLifetime(detachOnWindowClose: true, detachOnAppQuit: false)] {
            let round = SimulatorLifetime.from(plist: lifetime.plistPatch)
            #expect(round == lifetime)
        }
    }

    // MARK: - Changing the policy

    @Test func `should write nothing when the requested policy is already in place`() {
        let change = SimulatorLifetime.detached.change(
            to: .detached,
            simulatorAppRunning: false
        )
        #expect(change == .unchanged)
    }

    @Test func `should apply the policy when a different one is requested`() {
        let change = SimulatorLifetime.appleDefault.change(
            to: .detached,
            simulatorAppRunning: false
        )
        #expect(change == .applied(restartSimulatorApp: false))
    }

    @Test func `should ask for a Simulator app restart when applying while it runs`() {
        // A running Simulator.app may hold a cached copy of these keys
        // and flush it back over the write when it quits, so the user
        // has to be told the change isn't reliably live yet.
        let change = SimulatorLifetime.appleDefault.change(
            to: .detached,
            simulatorAppRunning: true
        )
        #expect(change == .applied(restartSimulatorApp: true))
    }

    @Test func `should not ask for a restart when nothing changes`() {
        // Nothing was written, so there is nothing for a running
        // Simulator.app to clobber.
        let change = SimulatorLifetime.detached.change(
            to: .detached,
            simulatorAppRunning: true
        )
        #expect(change == .unchanged)
    }

    @Test func `should apply a revert to Apple's default like any other change`() {
        let change = SimulatorLifetime.detached.change(
            to: .appleDefault,
            simulatorAppRunning: false
        )
        #expect(change == .applied(restartSimulatorApp: false))
    }

    @Test func `should apply detached when only one route is detached so far`() {
        let partial = SimulatorLifetime(detachOnWindowClose: true, detachOnAppQuit: false)
        let change = partial.change(to: .detached, simulatorAppRunning: false)
        #expect(change == .applied(restartSimulatorApp: false))
    }

    // MARK: - Advising the user

    @Test func `should advise baguette lifetime --detach when the policy loses devices`() throws {
        // `serve` prints this at startup; it has to name the command
        // that fixes it, or it is just noise.
        let advisory = try #require(SimulatorLifetime.appleDefault.advisory)
        #expect(advisory.contains("baguette lifetime --detach"))
    }

    @Test func `should name both the window and quit routes under Apple's default`() throws {
        let advisory = try #require(SimulatorLifetime.appleDefault.advisory)
        #expect(advisory.contains("window"))
        #expect(advisory.contains("quits"))
    }

    @Test func `should name only the quit route when window close already detaches`() throws {
        // Closing the window no longer shuts this device down, so saying
        // it does would misdescribe what Simulator.app will actually do.
        // Reachable from Simulator → Settings, where the two keys are
        // independent checkboxes.
        let partial = SimulatorLifetime(detachOnWindowClose: true, detachOnAppQuit: false)
        let advisory = try #require(partial.advisory)
        #expect(advisory.contains("quits"))
        #expect(!advisory.contains("window"))
    }

    @Test func `should name only the window route when quitting already detaches`() throws {
        let partial = SimulatorLifetime(detachOnWindowClose: false, detachOnAppQuit: true)
        let advisory = try #require(partial.advisory)
        #expect(advisory.contains("window"))
        #expect(!advisory.contains("quits"))
    }

    @Test func `should name the fix in every advisory`() throws {
        // Whichever routes are live, the advisory has to stay actionable.
        for lifetime in [SimulatorLifetime.appleDefault,
                         SimulatorLifetime(detachOnWindowClose: true, detachOnAppQuit: false),
                         SimulatorLifetime(detachOnWindowClose: false, detachOnAppQuit: true)] {
            let advisory = try #require(lifetime.advisory)
            #expect(advisory.contains("baguette lifetime --detach"))
        }
    }

    @Test func `should give no advice when devices survive Simulator app`() {
        #expect(SimulatorLifetime.detached.advisory == nil)
    }
}
