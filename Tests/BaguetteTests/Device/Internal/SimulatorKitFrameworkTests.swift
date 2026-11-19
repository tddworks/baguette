import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Xcode 27 relocated `SimulatorKit.framework` out of the developer
/// directory: it used to sit under `Contents/Developer/Library/
/// PrivateFrameworks/`, and now sits under `Contents/SharedFrameworks/`
/// — a sibling of `Contents/Developer`, not a child of it. Every
/// `dlopen` site in baguette hardcoded the old path, so a machine whose
/// only Xcode is 27 fails to load SimulatorKit at all (issue #28).
///
/// `SimulatorKitFramework` is the one place that knows both layouts.
/// The filesystem probe is injected so the resolution order is provable
/// without either Xcode installed.
@Suite("SimulatorKit framework location")
struct SimulatorKitFrameworkTests {

    private static let dev = "/Applications/Xcode.app/Contents/Developer"
    private static let privatePath =
        "/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
    private static let sharedPath =
        "/Applications/Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework/SimulatorKit"

    @Test func `should find SimulatorKit under PrivateFrameworks in the Xcode 26 layout`() {
        let found = SimulatorKitFramework.path(developerDir: Self.dev) {
            $0 == Self.privatePath
        }

        #expect(found == Self.privatePath)
    }

    @Test func `should find SimulatorKit under SharedFrameworks in the Xcode 27 layout`() {
        let found = SimulatorKitFramework.path(developerDir: Self.dev) {
            $0 == Self.sharedPath
        }

        #expect(found == Self.sharedPath)
    }

    @Test func `should prefer the PrivateFrameworks location when both exist`() {
        // Belt-and-braces: an Xcode carrying both layouts must keep
        // resolving to the path that shipped working input on 26.
        let found = SimulatorKitFramework.path(developerDir: Self.dev) { _ in true }

        #expect(found == Self.privatePath)
    }

    @Test func `should find no SimulatorKit when neither location exists`() {
        let found = SimulatorKitFramework.path(developerDir: Self.dev) { _ in false }

        #expect(found == nil)
    }

    @Test func `should offer both known SimulatorKit locations as candidates in order`() {
        // The diagnostic path prints these, so both the order and the
        // absence of a `..` segment are part of the contract.
        #expect(
            SimulatorKitFramework.candidatePaths(developerDir: Self.dev)
                == [Self.privatePath, Self.sharedPath]
        )
    }
}
