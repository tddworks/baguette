import Foundation
import IOSurface
import Mockable

/// A loaded 3D device scene whose screen can be updated and rendered
/// repeatedly. The scene owns expensive model/renderer state for one live
/// connection.
@Mockable
protocol DeviceScene: AnyObject, Sendable {
    /// Replace the device screen with the supplied simulator surface and
    /// return the composed 3D scene as a BGRA surface. Keeping the result
    /// unencoded lets any existing stream codec consume it.
    func render(screen: IOSurface) throws -> IOSurface

    /// A foldable: put each panel's latest frame on its screen and
    /// return the composed scene, as `render(screen:)` does for a phone.
    func render(screens: FoldableScreens) throws -> IOSurface

    /// Capture geometry inside the same render operation as its pixels.
    func renderFrame(screen: IOSurface) throws -> DeviceFrame
    func renderFrame(screens: FoldableScreens) throws -> DeviceFrame

    /// A foldable: pose the book at this hinge angle (`FoldPose`).
    func update(hingeDegrees: Double)

    /// Mutate camera state without reloading the model or reconnecting.
    func update(camera: Device3DCamera)

    /// Pose the model from a gyroscope attitude. The quaternion reaches
    /// the entity and the screen-quad projection untouched — never
    /// decomposed into euler angles, whose composition order would not
    /// match the scene's.
    func update(pose: Attitude, zoom: Double)

    /// Where the screen mesh currently lands in the rendered image, for
    /// mapping browser clicks back onto the device screen without ray
    /// casting into the GPU scene. `nil` until the first render/update.
    var screenQuad: ScreenQuad? { get }

    /// A foldable's lit screen as flat pieces in the rendered image
    /// (`FoldedScreenProjection`), replacing `screenQuad`; nil on a
    /// phone.
    var screenPieces: [ScreenPiece]? { get }

    /// Where the model's hardware buttons land in the rendered image,
    /// for a model whose definition names them; nil otherwise.
    var screenButtons: [ScreenButtonMark]? { get }

    /// A foldable's lit panel at the current hinge angle; nil on a phone.
    var litPanel: IntegratedPanel? { get }
}
