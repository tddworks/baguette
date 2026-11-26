import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Coverage for the install layout shared by every dylib baguette injects.
///
/// Generalised from the camera's installer once motion became a second
/// consumer: the layout, the sha-keying and the idempotence rule are
/// identical, and only the dylib's name differs.
@Suite("InjectedDylibInstallPlan")
struct InjectedDylibInstallPlanTests {

    @Test func `should install a dylib under the builds folder keyed by the first 12 hex chars of its sha256`() {
        let plan = InjectedDylibInstallPlan.compute(
            bytes: Data("hello".utf8), supportDir: "/tmp/baguette-test", dylib: .camera)
        // sha256("hello") prefix = "2cf24dba5fb0".
        #expect(plan.sha12 == "2cf24dba5fb0")
        #expect(plan.buildDir == "/tmp/baguette-test/builds/2cf24dba5fb0")
        #expect(plan.destPath == "/tmp/baguette-test/builds/2cf24dba5fb0/VirtualCamera.dylib")
    }

    @Test func `should install the motion dylib under its own file name`() {
        let plan = InjectedDylibInstallPlan.compute(
            bytes: Data("hello".utf8), supportDir: "/s", dylib: .motion)
        #expect(plan.destPath == "/s/builds/2cf24dba5fb0/VirtualMotion.dylib")
    }

    @Test func `should install different builds into different folders`() {
        // The sha-keyed directory is what dodges iOS 26's dyld page-hash
        // cache rejecting a replaced dylib at a path it has already seen.
        let a = InjectedDylibInstallPlan.compute(bytes: Data([0x01]), supportDir: "/s",
                                                 dylib: .camera)
        let b = InjectedDylibInstallPlan.compute(bytes: Data([0x02]), supportDir: "/s",
                                                 dylib: .camera)
        #expect(a.buildDir != b.buildDir)
    }

    @Test func `should install every dylib of the same build side by side`() {
        // Same bytes, different dylibs: the directory is shared, the file
        // names differ. All of them can be armed at once, which is the
        // whole point of `InjectedDylibs` merging by file name.
        let plans = [InjectedDylib.camera, .motion, .network].map {
            InjectedDylibInstallPlan.compute(bytes: Data([0x01]), supportDir: "/s", dylib: $0)
        }
        #expect(Set(plans.map(\.buildDir)).count == 1)
        #expect(Set(plans.map(\.destPath)).count == plans.count)
    }

    @Test func `should give each dylib its own environment override`() {
        #expect(InjectedDylib.camera.environmentOverride == "BAGUETTE_VIRTUALCAMERA_DYLIB")
        #expect(InjectedDylib.motion.environmentOverride == "BAGUETTE_VIRTUALMOTION_DYLIB")
        #expect(InjectedDylib.network.environmentOverride == "BAGUETTE_VIRTUALNETWORK_DYLIB")
    }

    @Test func `should locate each dylib under the Injected folder of the source tree`() {
        // The dev-build fallback walks up from the executable looking for
        // this path. All three live under one `Injected/` folder, so the
        // lookup has to name it — a bare `<Name>/<Name>.dylib` stopped
        // resolving the moment they moved.
        #expect(InjectedDylib.camera.sourceTreePath == "Injected/VirtualCamera/VirtualCamera.dylib")
        #expect(InjectedDylib.motion.sourceTreePath == "Injected/VirtualMotion/VirtualMotion.dylib")
        #expect(InjectedDylib.network.sourceTreePath
                    == "Injected/VirtualNetwork/VirtualNetwork.dylib")
    }

    @Test func `should install the network dylib under its own file name`() {
        let plan = InjectedDylibInstallPlan.compute(
            bytes: Data("hello".utf8), supportDir: "/s", dylib: .network)
        #expect(plan.destPath == "/s/builds/2cf24dba5fb0/VirtualNetwork.dylib")
    }

    @Test func `should ship the library that lets an app say which preferences it looks up`() {
        #expect(InjectedDylib.defaultsLookups.sourceTreePath
                    == "Injected/DefaultsLookups/DefaultsLookups.dylib")
        #expect(InjectedDylib.defaultsLookups.environmentOverride == "BAGUETTE_DEFAULTSLOOKUPS_DYLIB")
    }
}

@Suite("InjectedDylibInstaller — applies the plan to disk")
struct InjectedDylibInstallerApplyTests {

    @Test func `should write the dylib bytes to its install path`() throws {
        let scratch = NSTemporaryDirectory() + "baguette-installer-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let bytes = Data([0xAA, 0xBB, 0xCC])
        let plan = InjectedDylibInstallPlan.compute(bytes: bytes, supportDir: scratch,
                                                    dylib: .motion)
        try InjectedDylibInstaller.apply(plan: plan, bytes: bytes)

        #expect(try Data(contentsOf: URL(fileURLWithPath: plan.destPath)) == bytes)
    }

    @Test func `should leave an installed dylib untouched when it is already on disk`() throws {
        // Rewriting would replace the linker's adhoc signature, which iOS 26's
        // simulator dyld rejects after any post-build re-sign.
        let scratch = NSTemporaryDirectory() + "baguette-installer-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let bytes = Data([0x01, 0x02, 0x03])
        let plan = InjectedDylibInstallPlan.compute(bytes: bytes, supportDir: scratch,
                                                    dylib: .camera)
        try InjectedDylibInstaller.apply(plan: plan, bytes: bytes)
        let url = URL(fileURLWithPath: plan.destPath)
        let before = try url.resourceValues(forKeys: [.contentModificationDateKey])
        Thread.sleep(forTimeInterval: 0.05)
        try InjectedDylibInstaller.apply(plan: plan, bytes: bytes)
        let after = try url.resourceValues(forKeys: [.contentModificationDateKey])

        #expect(before.contentModificationDate == after.contentModificationDate)
    }
}

// The programs spawned in the guest are not dylibs to inject but
// executables; they ship and install the same way, under their bare names.
extension InjectedDylibInstallPlanTests {
    @Test(arguments: [
        (InjectedDylib.coreMotionAngle, "CoreMotionAngle", "BAGUETTE_COREMOTIONANGLE_TOOL"),
        (.deviceHubControls, "DeviceHubControls", "BAGUETTE_DEVICEHUBCONTROLS_TOOL"),
        (.hidButtons, "HIDButtons", "BAGUETTE_HIDBUTTONS_TOOL"),
        (.axpFrontmost, "AXPFrontmost", "BAGUETTE_AXPFRONTMOST_TOOL"),
    ])
    func `should ship each guest program under its bare name`(program: InjectedDylib, name: String, override: String) {
        #expect(program.fileName == name)
        #expect(program.sourceTreePath == "Injected/\(name)/\(name)")
        #expect(program.environmentOverride == override)
        let plan = InjectedDylibInstallPlan.compute(bytes: Data("program".utf8), supportDir: "/s", dylib: program)
        #expect(plan.destPath.hasSuffix("/\(name)"))
    }
}

/// Where a build keeps the dylibs it injects, in the order they are
/// looked for: an explicit override, the source tree a development build
/// runs from, the resource bundle beside the executable, the executable's
/// own folder.
@Suite("InjectedDylibInstaller — finds the bundled dylib")
struct InjectedDylibInstallerLookupTests {

    /// A scratch folder with an executable folder inside it, two deep,
    /// as `.build/debug` sits in a checkout.
    private final class Scratch {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baguette-lookup-\(UUID().uuidString)")
        var executable: URL { root.appendingPathComponent(".build/debug") }

        init() throws {
            try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func file(_ path: String, in base: URL? = nil, bytes: Data = Data([0x01])) throws -> URL {
            let url = (base ?? root).appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            return url
        }
    }

    private func find(_ dylib: InjectedDylib, _ scratch: Scratch, environment: [String: String] = [:]) -> URL? {
        InjectedDylibInstaller.bundledDylibURL(
            dylib, environment: environment, executableDirectory: scratch.executable)
    }

    @Test func `should take the dylib its environment override names`() throws {
        let scratch = try Scratch()
        let named = try scratch.file("elsewhere/Mine.dylib")
        try scratch.file("Injected/VirtualMotion/VirtualMotion.dylib")

        let found = find(.motion, scratch, environment: ["BAGUETTE_VIRTUALMOTION_DYLIB": named.path])

        #expect(found?.path == named.path)
    }

    @Test func `should look further when the environment override names no file`() throws {
        let scratch = try Scratch()
        let tree = try scratch.file("Injected/VirtualMotion/VirtualMotion.dylib")

        let found = find(.motion, scratch, environment: ["BAGUETTE_VIRTUALMOTION_DYLIB": "/nowhere/Mine.dylib"])

        #expect(found?.path == tree.path)
    }

    @Test func `should find the dylib in the source tree a development build runs from`() throws {
        let scratch = try Scratch()
        let tree = try scratch.file("Injected/VirtualMotion/VirtualMotion.dylib")

        #expect(find(.motion, scratch)?.path == tree.path)
    }

    @Test func `should find the dylib in the resource bundle beside the executable`() throws {
        let scratch = try Scratch()
        let bundled = try scratch.file(
            "Baguette_Baguette.bundle/VirtualMotion/VirtualMotion.dylib", in: scratch.executable)

        #expect(find(.motion, scratch)?.resolvingSymlinksInPath().path == bundled.resolvingSymlinksInPath().path)
    }

    @Test func `should find a bundled executable by its bare name`() throws {
        let scratch = try Scratch()
        let bundled = try scratch.file("Baguette_Baguette.bundle/HIDButtons/HIDButtons", in: scratch.executable)

        #expect(
            find(.hidButtons, scratch)?.resolvingSymlinksInPath().path == bundled.resolvingSymlinksInPath().path)
    }

    @Test func `should find the dylib beside the executable when the build ships no resource bundle`() throws {
        let scratch = try Scratch()
        let sibling = try scratch.file("VirtualMotion.dylib", in: scratch.executable)

        #expect(find(.motion, scratch)?.path == sibling.path)
    }

    @Test func `should find nothing when this build ships no dylib`() throws {
        let scratch = try Scratch()
        try FileManager.default.createDirectory(
            at: scratch.executable.appendingPathComponent("Baguette_Baguette.bundle"), withIntermediateDirectories: true)

        #expect(find(.motion, scratch) == nil)
    }

    @Test func `should find nothing when the executable cannot be located`() {
        #expect(InjectedDylibInstaller.bundledDylibURL(.motion, environment: [:], executableDirectory: nil) == nil)
    }

    @Test func `should install the dylib it finds under its build folder`() throws {
        let scratch = try Scratch()
        let bytes = Data([0xCA, 0xFE])
        try scratch.file("Injected/VirtualMotion/VirtualMotion.dylib", bytes: bytes)
        let support = scratch.root.appendingPathComponent("support").path

        let installed = InjectedDylibInstaller.installIfNeeded(
            .motion, supportDir: support, environment: [:], executableDirectory: scratch.executable)

        let plan = InjectedDylibInstallPlan.compute(bytes: bytes, supportDir: support, dylib: .motion)
        #expect(installed == plan.destPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: plan.destPath)) == bytes)
    }

    @Test func `should install nothing when this build ships no dylib`() throws {
        let scratch = try Scratch()

        let installed = InjectedDylibInstaller.installIfNeeded(
            .motion, supportDir: scratch.root.appendingPathComponent("support").path,
            environment: [:], executableDirectory: scratch.executable)

        #expect(installed == nil)
    }

    @Test func `should install nothing when its support folder cannot be written`() throws {
        let scratch = try Scratch()
        try scratch.file("Injected/VirtualMotion/VirtualMotion.dylib")
        let blocked = try scratch.file("support")

        let installed = InjectedDylibInstaller.installIfNeeded(
            .motion, supportDir: blocked.path, environment: [:], executableDirectory: scratch.executable)

        #expect(installed == nil)
    }
}
