import XCTest
@testable import FanPilotCore

/// 2026-09-16 夜间复盘回归：伪迹的"慢坡平台"形态——以 2-4°C/s 的合法坡度爬升
/// （低于 PlausibilityFilter 的 8°C/s 闸门），把峰值保持顶上 74-80°C 后残留成平台。
/// 夜间实测 261 行 held 与 raw 偏离 >15°C，风扇多转 ~1 小时底速 + 07:23 完整误接管。
/// 修复 = SlowPlateauGate：held 与 raw 滑动中位数偏离 >10°C 且功率不足 → 复位保持。
final class SlowPlateauGateTests: XCTestCase {

    /// 伪迹平台（held 76 / raw 49 / 待机 5W）：~1.5s 后判伪迹。
    func testArtifactPlateauDetected() {
        let gate = SlowPlateauGate()
        var t = 0.0
        var fired = false
        for _ in 0..<8 {
            if gate.isArtifact(held: 76, raw: 49, power: 5,
                               now: Date(timeIntervalSince1970: t)) { fired = true }
            t += 0.5
        }
        XCTAssertTrue(fired, "held 远超 raw 中位数且无功率支撑，必须判伪迹")
    }

    /// 真实负载的峰值保持（80W）：偏离再大也不判伪迹——保持值有功率支撑。
    func testRealLoadHoldNeverFlagged() {
        let gate = SlowPlateauGate()
        var t = 0.0
        for _ in 0..<30 {
            XCTAssertFalse(gate.isArtifact(held: 95, raw: 60, power: 80,
                                           now: Date(timeIntervalSince1970: t)),
                           "80W 负载下的峰值保持是合法的，不得复位")
            t += 0.5
        }
    }

    /// 正常峰值保持（偏离 < 10°C）：不触发。
    func testNormalHoldNotFlagged() {
        let gate = SlowPlateauGate()
        var t = 0.0
        for _ in 0..<20 {
            XCTAssertFalse(gate.isArtifact(held: 55, raw: 49, power: 5,
                                           now: Date(timeIntervalSince1970: t)),
                           "偏离 6°C 在正常保持范围内")
            t += 0.5
        }
    }

    /// 伪迹消退（raw 回落使偏离消失）：可疑计时复位。
    func testSuspicionResetsWhenDeviationClears() {
        let gate = SlowPlateauGate()
        var t = 0.0
        for _ in 0..<2 { _ = gate.isArtifact(held: 76, raw: 49, power: 5,
                                             now: Date(timeIntervalSince1970: t)); t += 0.5 }
        _ = gate.isArtifact(held: 50, raw: 49, power: 5, now: Date(timeIntervalSince1970: t)); t += 0.5
        var fired = false
        for _ in 0..<2 {
            if gate.isArtifact(held: 76, raw: 49, power: 5, now: Date(timeIntervalSince1970: t)) { fired = true }
            t += 0.5
        }
        XCTAssertFalse(fired, "中断 1 poll 后计时应从零开始，1s 内不得判伪迹")
    }
}
