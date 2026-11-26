import Foundation

/// The programs baguette runs inside a simulator (`simctl spawn`), one per
/// Apple subsystem it drives (docs/features/injected-programs/design.md).
///
/// A library host that carries its own copies hands each one here; a nil
/// program is found where baguette's CLI keeps it: `BAGUETTE_<NAME>_TOOL`,
/// the source tree, then the CLI's resource bundle.
public struct InjectedPrograms: Equatable, Sendable {
    /// Reads a foldable's hinge angle from CoreMotion's `CMAngleManager`.
    public var coreMotionAngle: URL?
    /// Plays Device Hub's hinge slider and orientation picker.
    public var deviceHubControls: URL?
    /// Presses a foldable's keys and buttons on a HID buttons service.
    public var hidButtons: URL?
    /// Names the frontmost app through AXPTranslator.
    public var axpFrontmost: URL?

    public init(
        coreMotionAngle: URL? = nil,
        deviceHubControls: URL? = nil,
        hidButtons: URL? = nil,
        axpFrontmost: URL? = nil
    ) {
        self.coreMotionAngle = coreMotionAngle
        self.deviceHubControls = deviceHubControls
        self.hidButtons = hidButtons
        self.axpFrontmost = axpFrontmost
    }

    /// Every program played by one binary that answers all their verbs:
    /// `HingeControl`, the program these were split from.
    static func everyVerb(in binary: URL) -> InjectedPrograms {
        InjectedPrograms(coreMotionAngle: binary, deviceHubControls: binary, hidButtons: binary, axpFrontmost: binary)
    }
}

/// Where each program is, asked each time it runs: a host's copy when it
/// is still executable, else the CLI's.
struct InjectedProgramPaths: Sendable {
    let coreMotionAngle: @Sendable () -> String?
    let deviceHubControls: @Sendable () -> String?
    let hidButtons: @Sendable () -> String?
    let axpFrontmost: @Sendable () -> String?

    init(
        coreMotionAngle: @escaping @Sendable () -> String?,
        deviceHubControls: @escaping @Sendable () -> String?,
        hidButtons: @escaping @Sendable () -> String?,
        axpFrontmost: @escaping @Sendable () -> String?
    ) {
        self.coreMotionAngle = coreMotionAngle
        self.deviceHubControls = deviceHubControls
        self.hidButtons = hidButtons
        self.axpFrontmost = axpFrontmost
    }

    init(_ programs: InjectedPrograms) {
        self.init(
            coreMotionAngle: Self.lookup(programs.coreMotionAngle, else: .coreMotionAngle),
            deviceHubControls: Self.lookup(programs.deviceHubControls, else: .deviceHubControls),
            hidButtons: Self.lookup(programs.hidButtons, else: .hidButtons),
            axpFrontmost: Self.lookup(programs.axpFrontmost, else: .axpFrontmost)
        )
    }

    /// The CLI's own copies.
    static let bundled = InjectedProgramPaths(InjectedPrograms())

    private static func lookup(_ url: URL?, else program: InjectedDylib) -> @Sendable () -> String? {
        guard let path = url?.path else {
            return { @Sendable in InjectedDylibInstaller.installIfNeeded(program) }
        }
        return { @Sendable in FileManager.default.isExecutableFile(atPath: path) ? path : nil }
    }
}
