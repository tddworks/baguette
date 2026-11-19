import Foundation
import Mockable

@Mockable
public protocol DeviceRenderer: Sendable {
    func render(plan: DeviceRenderPlan, screenImage: Data) throws -> Data
}
