import BaguetteDevice
import Foundation
import Mockable

@Mockable
protocol DeviceRenderer: Sendable {
    func render(plan: DeviceRenderPlan, screenImage: Data) throws -> Data
}
