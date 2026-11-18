import Foundation

public struct DeviceModelID: RawRepresentable, Equatable, Hashable, Sendable, Codable,
                      ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }
}

public struct RenderDimensions: Equatable, Sendable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum DeviceModelOrientation: String, Equatable, Sendable, Codable {
    case portrait
    case landscape
}

public struct DeviceModelMatches: Equatable, Sendable, Codable {
    public let simulatorDeviceTypes: [String]
    public let deviceNames: [String]
    /// Physical-hardware identifiers (`utsname.machine`, e.g.
    /// "iPhone14,3") for the device-twin path. Optional in the JSON so
    /// every pre-existing definition keeps parsing.
    public let deviceModels: [String]

    public init(
        simulatorDeviceTypes: [String] = [],
        deviceNames: [String] = [],
        deviceModels: [String] = []
    ) {
        self.simulatorDeviceTypes = simulatorDeviceTypes
        self.deviceNames = deviceNames
        self.deviceModels = deviceModels
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        simulatorDeviceTypes = try container.decodeIfPresent(
            [String].self, forKey: .simulatorDeviceTypes) ?? []
        deviceNames = try container.decodeIfPresent(
            [String].self, forKey: .deviceNames) ?? []
        deviceModels = try container.decodeIfPresent(
            [String].self, forKey: .deviceModels) ?? []
    }
}

public struct DeviceModelAsset: Equatable, Sendable, Codable {
    public let file: String?
    public let downloadURL: String?
    public let sha256: String?
    /// An asset Apple ships inside Xcode, named by its path under the
    /// selected Xcode's `Contents/` — iPhone Duo's `V68.usdz` lives in
    /// DeviceKit's plug-in, and is read from there like the 2D chromes
    /// are read from `/Library/Developer/DeviceKit`.
    public let xcodeResource: String?

    public init(file: String?, downloadURL: String?, sha256: String?, xcodeResource: String? = nil) {
        self.file = file
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.xcodeResource = xcodeResource
    }
}

/// A foldable's book, as its model animates it. The clip shuts the book
/// from flat at its start to shut at `shutTime`; the cover is the
/// screen on the far side of the leaf that folds over.
public struct DeviceModelFold: Equatable, Sendable, Codable {
    public let clip: String
    public let shutTime: Double
    public let coverMaterial: String
    public let coverTextureSize: RenderDimensions
    /// Quarter turns (degrees, clockwise) the cover's frames need to
    /// read upright on the mesh; nil is none.
    public let coverTextureRotation: Int?
    /// The hinge angle of Device Hub's open pose: from here up the bend
    /// is centred between the halves.
    public let openPoseDegrees: Double

    public init(
        clip: String,
        shutTime: Double,
        coverMaterial: String,
        coverTextureSize: RenderDimensions,
        coverTextureRotation: Int? = nil,
        openPoseDegrees: Double
    ) {
        self.clip = clip
        self.shutTime = shutTime
        self.coverMaterial = coverMaterial
        self.coverTextureSize = coverTextureSize
        self.coverTextureRotation = coverTextureRotation
        self.openPoseDegrees = openPoseDegrees
    }
}

/// A hardware button the model carries: the wire name the page presses
/// (`DeviceButton`) and the skeleton joint that sits on it, whose rest
/// position is where the page draws the control.
public struct DeviceModelButton: Equatable, Sendable, Codable {
    public let id: String
    public let joint: String

    public init(id: String, joint: String) {
        self.id = id
        self.joint = joint
    }
}

public struct DeviceModelScene: Equatable, Sendable, Codable {
    public let rootNode: String
    public let screenNode: String?
    public let screenMaterial: String
    public let nativeOrientation: DeviceModelOrientation
    public let textureSize: RenderDimensions
    public let usesScreenOverlay: Bool
    /// Quarter turns (degrees, clockwise) the screen's frames need to
    /// read upright on the mesh, when its UVs run the other way from the
    /// framebuffer; nil is none.
    public let textureRotation: Int?
    /// Turns an asset authored lying flat (screen up) to face the
    /// camera before any requested rotation; nil for models authored
    /// standing up.
    public let restRotation: DeviceRotation?
    public let fold: DeviceModelFold?
    public let buttons: [DeviceModelButton]?

    public init(
        rootNode: String,
        screenNode: String?,
        screenMaterial: String,
        nativeOrientation: DeviceModelOrientation,
        textureSize: RenderDimensions,
        usesScreenOverlay: Bool,
        textureRotation: Int? = nil,
        restRotation: DeviceRotation? = nil,
        fold: DeviceModelFold? = nil,
        buttons: [DeviceModelButton]? = nil
    ) {
        self.rootNode = rootNode
        self.screenNode = screenNode
        self.screenMaterial = screenMaterial
        self.nativeOrientation = nativeOrientation
        self.textureSize = textureSize
        self.usesScreenOverlay = usesScreenOverlay
        self.textureRotation = textureRotation
        self.restRotation = restRotation
        self.fold = fold
        self.buttons = buttons
    }
}

public struct DeviceVariantChoice: Equatable, Sendable, Codable {
    public let id: String
    public let displayName: String
    public let usdValue: String
    public let previewColor: String?
    public let materialColors: [String: String]?

    public init(
        id: String,
        displayName: String,
        usdValue: String,
        previewColor: String?,
        materialColors: [String: String]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.usdValue = usdValue
        self.previewColor = previewColor
        self.materialColors = materialColors
    }
}

public enum DeviceVariantKind: String, Equatable, Sendable, Codable {
    case usd
    case materials
}

public struct DeviceVariantSet: Equatable, Sendable, Codable {
    public let id: String
    public let displayName: String
    public let primPath: String
    public let usdName: String
    public let `default`: String
    public let choices: [DeviceVariantChoice]
    public let kind: DeviceVariantKind?

    public init(
        id: String,
        displayName: String,
        primPath: String,
        usdName: String,
        default: String,
        choices: [DeviceVariantChoice],
        kind: DeviceVariantKind? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.primPath = primPath
        self.usdName = usdName
        self.default = `default`
        self.choices = choices
        self.kind = kind
    }
}

public struct DeviceVariantSelection: Equatable, Sendable {
    public let setID: String
    public let primPath: String
    public let usdName: String
    public let usdValue: String
    public let materialColors: [String: String]
    public let kind: DeviceVariantKind

    public init(
        setID: String,
        primPath: String,
        usdName: String,
        usdValue: String,
        materialColors: [String: String] = [:],
        kind: DeviceVariantKind = .usd
    ) {
        self.setID = setID
        self.primPath = primPath
        self.usdName = usdName
        self.usdValue = usdValue
        self.materialColors = materialColors
        self.kind = kind
    }
}

public struct DeviceModelDefinition: Equatable, Sendable, Codable {
    public let schemaVersion: Int
    public let id: DeviceModelID
    public let displayName: String
    public let matches: DeviceModelMatches
    public let asset: DeviceModelAsset
    public let scene: DeviceModelScene
    public let variantSets: [DeviceVariantSet]

    public static func parsing(json: Data) throws -> DeviceModelDefinition {
        let definition: DeviceModelDefinition
        do {
            definition = try JSONDecoder().decode(DeviceModelDefinition.self, from: json)
        } catch {
            throw DeviceModelError.malformedJSON
        }
        try definition.validate()
        return definition
    }

    public func matches(deviceType: String, deviceName: String) -> Bool {
        matches.simulatorDeviceTypes.contains(deviceType)
            || matches.deviceNames.contains(deviceName)
    }

    /// Match a physical device by its hardware identifier — the
    /// device-twin sibling of `matches(deviceType:deviceName:)`.
    public func matches(hardware: String) -> Bool {
        matches.deviceModels.contains(hardware)
    }

    public func resolveVariants(_ requested: [String: String]) throws -> [DeviceVariantSelection] {
        let knownSets = Set(variantSets.map(\.id))
        if let unknown = requested.keys.sorted().first(where: { !knownSets.contains($0) }) {
            throw DeviceModelError.unknownVariantSet(unknown)
        }

        return try variantSets.map { set in
            let choiceID = requested[set.id] ?? set.default
            guard let choice = set.choices.first(where: { $0.id == choiceID }) else {
                throw DeviceModelError.unknownVariantChoice(
                    set: set.id,
                    choice: choiceID,
                    allowed: set.choices.map(\.id)
                )
            }
            return DeviceVariantSelection(
                setID: set.id,
                primPath: set.primPath,
                usdName: set.usdName,
                usdValue: choice.usdValue,
                materialColors: choice.materialColors ?? [:],
                kind: set.kind ?? .usd
            )
        }
    }

    private func validate() throws {
        guard schemaVersion == 1 else {
            throw DeviceModelError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !id.rawValue.isEmpty else {
            throw DeviceModelError.emptyField("id")
        }
        guard !displayName.isEmpty else {
            throw DeviceModelError.emptyField("displayName")
        }
        guard scene.textureSize.width > 0, scene.textureSize.height > 0 else {
            throw DeviceModelError.invalidTextureSize
        }
        guard asset.file?.isEmpty == false || asset.downloadURL?.isEmpty == false
                || asset.xcodeResource?.isEmpty == false else {
            throw DeviceModelError.missingAsset
        }
        for turn in [scene.textureRotation, scene.fold?.coverTextureRotation].compactMap({ $0 }) {
            guard turn % 90 == 0 else { throw DeviceModelError.invalidTextureRotation(turn) }
        }
        for button in scene.buttons ?? [] {
            guard !button.id.isEmpty, !button.joint.isEmpty else {
                throw DeviceModelError.emptyField("scene.buttons")
            }
        }
        if let fold = scene.fold {
            guard !fold.clip.isEmpty else { throw DeviceModelError.emptyField("scene.fold.clip") }
            guard fold.shutTime > 0, fold.openPoseDegrees > 0, fold.openPoseDegrees <= 180,
                  fold.coverTextureSize.width > 0, fold.coverTextureSize.height > 0,
                  !fold.coverMaterial.isEmpty else {
                throw DeviceModelError.invalidFold
            }
        }
        if asset.downloadURL?.isEmpty == false {
            guard let hash = asset.sha256,
                  hash.count == 64,
                  hash.allSatisfy({ $0.isHexDigit }) else {
                throw DeviceModelError.downloadRequiresSHA256
            }
        }

        var setIDs = Set<String>()
        for set in variantSets {
            guard setIDs.insert(set.id).inserted else {
                throw DeviceModelError.duplicateVariantSet(set.id)
            }
            guard !set.id.isEmpty, !set.primPath.isEmpty, !set.usdName.isEmpty else {
                throw DeviceModelError.emptyField("variantSets")
            }
            var choiceIDs = Set<String>()
            for choice in set.choices {
                guard choiceIDs.insert(choice.id).inserted else {
                    throw DeviceModelError.duplicateVariantChoice(set: set.id, choice: choice.id)
                }
                for (material, color) in choice.materialColors ?? [:] {
                    guard !material.isEmpty,
                          color.count == 7,
                          color.first == "#",
                          color.dropFirst().allSatisfy(\.isHexDigit) else {
                        throw DeviceModelError.invalidMaterialColor(
                            material: material,
                            color: color
                        )
                    }
                }
            }
            guard choiceIDs.contains(set.default) else {
                throw DeviceModelError.invalidVariantDefault(set: set.id, choice: set.default)
            }
        }
    }

    public init(schemaVersion: Int, id: DeviceModelID, displayName: String, matches: DeviceModelMatches, asset: DeviceModelAsset, scene: DeviceModelScene, variantSets: [DeviceVariantSet]) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.matches = matches
        self.asset = asset
        self.scene = scene
        self.variantSets = variantSets
    }
}

public enum DeviceModelError: Error, Equatable, LocalizedError {
    case malformedJSON
    case unsupportedSchemaVersion(Int)
    case emptyField(String)
    case invalidTextureSize
    case modelCannotFold(String)
    case invalidHingeAngle
    case invalidFold
    case invalidTextureRotation(Int)
    case missingAsset
    case downloadRequiresSHA256
    case duplicateVariantSet(String)
    case duplicateVariantChoice(set: String, choice: String)
    case duplicateModelID(String)
    case ambiguousMatch([String])
    case malformedDefinition(String)
    case assetOutsideBundle(String)
    case localAssetNotFound(String)
    case invalidOutputSize
    case invalidRotation
    case invalidUSDIdentifier(String)
    case invalidAssetReference
    case invalidBackground(String)
    case sceneLoadFailed(String)
    case sceneNodeNotFound(String)
    case sceneHasNoGeometry
    case screenImageInvalid
    case renderFailed
    case invalidRotationArgument(String)
    case invalidSizeArgument(String)
    case invalidVariantArgument(String)
    case duplicateVariantSelection(String)
    case modelNotFound(String)
    case noModelForDevice(String)
    case invalidRenderOptions
    case invalidDownloadURL(String)
    case assetDownloadFailed(String)
    case assetHashMismatch
    case assetCacheWriteFailed(String)
    case invalidMaterialColor(material: String, color: String)
    case invalidVariantDefault(set: String, choice: String)
    case unknownVariantSet(String)
    case unknownVariantChoice(set: String, choice: String, allowed: [String])
}

public extension DeviceModelError {
    var errorDescription: String? {
        switch self {
        case .modelCannotFold(let model):
            "Model '\(model)' cannot fold; omit --hinge-degrees or choose a foldable model."
        case .invalidHingeAngle:
            "The hinge angle must be finite and between 0 and 180 degrees."
        case .screenImageInvalid:
            "The screen image is not a readable PNG or JPEG."
        default:
            String(describing: self)
        }
    }
}
