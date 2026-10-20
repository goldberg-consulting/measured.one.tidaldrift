import XCTest
@testable import TidalDrift

final class StreamingThermalPolicyTests: XCTestCase {
    func testPressureProgressivelyReducesStreamingLoad() {
        let states: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        let policies = states.map { StreamingThermalPolicy(state: $0, enabled: true) }
        XCTAssertEqual(policies.map(\.frameRateCap), [.max, 45, 30, 15])
        XCTAssertEqual(policies.map(\.bitrateScale), [1.0, 0.75, 0.5, 0.25])
    }

    func testDisablingProtectionRemovesCapsAtEveryPressureLevel() {
        for state in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            let policy = StreamingThermalPolicy(state: state, enabled: false)
            XCTAssertEqual(policy.frameRateCap, .max)
            XCTAssertEqual(policy.bitrateScale, 1.0)
        }
    }
}
