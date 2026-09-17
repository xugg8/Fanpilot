import XCTest
@testable import ControlEngine
import FanPilotCore

/// 2026-09-15 20:46/20:55 回归：SMC 伪迹尖峰（48→95°C，单 tick）打穿 SafetyGuard 的
/// jump 规则（rise ≥ jumpDelta=25 → 无去抖立即拉满）→ tgt 5777，风扇冲 4585 RPM。
/// 修复 = 守护输入过 3-tick 中位数（独立序列，不影响曲线/激发用的原始值）。
final class GuardGlitchTests: XCTestCase {
    private func makeEngine() -> ControlEngine {
        var c = CustomProfileData()
        c.curve = [CurvePointData(temp: 50, rpm: 1350),
                   CurvePointData(temp: 70, rpm: 1350),
                   CurvePointData(temp: 85, rpm: 3800),
                   CurvePointData(temp: 95, rpm: 5777)]
        c.enableFeedForward = false
        c.respectsActivationGate = true
        var p = ThermalProfile.from(custom: c)
        p = p.scaled(toFanMin: 1350, fanMax: 5777)
        return ControlEngine(config: .init(profile: p))
    }

    private func tick(_ eng: ControlEngine, _ t: Double, mem: Double) -> ControlEngine.Decision {
        eng.decide(ThermalSnapshot.make(power: 10, mem: mem, t: t),
                   hardwareMin: 1350, hardwareMax: 5777,
                   now: Date(timeIntervalSince1970: t))
    }

    /// 单 tick 伪迹尖峰（48→95→48）：守护不得触发拉满，曲线钉在平台。
    func testSingleTickGlitchDoesNotTripGuard() {
        let eng = makeEngine()
        var t = 0.0
        for _ in 0..<10 { _ = tick(eng, t, mem: 48); t += 0.5 }
        let glitch = tick(eng, t, mem: 95); t += 0.5
        XCTAssertFalse(glitch.safetyOverride, "单 tick 伪迹不得触发安全抢占")
        XCTAssertLessThanOrEqual(glitch.finalRPM, 1400,
                                 "伪迹 tick 转速必须在平台内，rpm=\(glitch.finalRPM)")
        let after = tick(eng, t, mem: 48); t += 0.5
        XCTAssertFalse(after.safetyOverride)
        XCTAssertLessThanOrEqual(after.finalRPM, 1400)
    }

    /// 真实持续过热（连续 3+ tick ≥95°C）：守护照常拉满 —— 去抖只延迟 1 tick。
    func testSustainedOverheatStillTripsGuard() {
        let eng = makeEngine()
        var t = 0.0
        for _ in 0..<10 { _ = tick(eng, t, mem: 48); t += 0.5 }
        var tripped = false
        for _ in 0..<5 {
            let d = tick(eng, t, mem: 95); t += 0.5
            if d.safetyOverride { tripped = true }
        }
        XCTAssertTrue(tripped, "持续 ≥95°C 必须触发安全拉满")
    }
}
