import Foundation

/// The Mac frames installed in a frames folder, as bezels: each measured
/// `MacFrame` whose picture is there as `<name>.png`. baguette ships where
/// each frame's screen sits, never the pictures — they're read from the folder.
public final class MacFrames: Chromes, @unchecked Sendable {
    /// Where frames are installed unless `serve --mac-frames` names another folder.
    public static let standardFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/baguette/Frames", isDirectory: true)

    private let folder: URL
    private let read: @Sendable (URL) -> Data?

    public init(folder: URL = MacFrames.standardFolder,
                read: @escaping @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }) {
        self.folder = folder
        self.read = read
    }

    public func assets(forDeviceName name: String) -> DeviceChromeAssets? {
        guard let frame = MacFrame.named(name), let picture = picture(of: frame) else { return nil }
        return DeviceChromeAssets(chrome: frame.chrome, composite: ChromeImage(data: picture, size: frame.image))
    }

    public func assets(forDeviceName name: String, panel: IntegratedPanel) -> DeviceChromeAssets? {
        panel == .primary ? assets(forDeviceName: name) : nil
    }

    public func panels(forDeviceName name: String) -> [IntegratedPanel] {
        assets(forDeviceName: name) == nil ? [] : [.primary]
    }

    /// The installed frames a display of `size` fits, in the order measured.
    public func fitting(_ size: Size) -> [MacFrame] {
        MacFrame.fitting(size).filter { picture(of: $0) != nil }
    }

    private func picture(of frame: MacFrame) -> Data? {
        read(folder.appendingPathComponent("\(frame.name).png"))
    }
}

/// Several sources of bezels as one: each question answered by the first
/// source that has an answer — DeviceKit's chrome, then the Mac frames.
public final class CombinedChromes: Chromes, @unchecked Sendable {
    private let sources: [any Chromes]

    public init(_ sources: [any Chromes]) {
        self.sources = sources
    }

    public func assets(forDeviceName name: String) -> DeviceChromeAssets? {
        sources.lazy.compactMap { $0.assets(forDeviceName: name) }.first
    }

    public func assets(forDeviceName name: String, panel: IntegratedPanel) -> DeviceChromeAssets? {
        sources.lazy.compactMap { $0.assets(forDeviceName: name, panel: panel) }.first
    }

    public func panels(forDeviceName name: String) -> [IntegratedPanel] {
        sources.lazy.map { $0.panels(forDeviceName: name) }.first { !$0.isEmpty } ?? []
    }
}
