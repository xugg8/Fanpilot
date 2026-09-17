import XCTest
@testable import ControlEngine
import FanPilotCore

/// 2026-09-15 19:48 事故回归：轻载下传感器亚采样尖峰（46→~95°C，单 tick）
/// 把曲线打进陡坡段，风扇暴冲 5000 RPM。修复 = 曲线输入取 3-tick 中位数。
final class HotspotSpikeDebounceTests: XCTestCase {
    private func makeEngine() -> ControlEngine {
        var c = CustomProfileData()
        c.curve = [CurvePointData(temp: 50, rpm: 1350),
                   CurvePointData(temp: 70, rpm: 1350),
                   CurvePointData(temp: 85, rpm: 3800),
                   CurvePointData(temp: 95, rpm: 5777)]
        c.enableFeedForward = false          // 隔离变量：只看曲线对温度输入的响应
        c.respectsActivationGate = true
        var p = ThermalProfile.from(custom: c)
        p = p.scaled(toFanMin: 1350, fanMax: 5777)
        return ControlEngine(config: .init(profile: p))
    }

    private func tick(_ eng: ControlEngine, _ t: Double, power: Double, temp: Double) -> ControlEngine.Decision {
        eng.decide(ThermalSnapshot.make(power: power, cpu: temp, t: t),
                   hardwareMin: 1350, hardwareMax: 5777,
                   now: Date(timeIntervalSince1970: t))
    }

    /// 稳态 50°C 后单 tick 尖峰 95°C：曲线输出必须钉在平台，不得追毛刺。
    func testSingleTickSpikeIsFiltered() {
        let eng = makeEngine()
        var t = 0.0
        for _ in 0..<10 { _ = tick(eng, t, power: 10, temp: 50); t += 0.5 }
        let spike = tick(eng, t, power: 10, temp: 95); t += 0.5
        XCTAssertLessThanOrEqual(spike.curveRPM ?? 0, 1400,
                                 "单 tick 尖峰必须被中位数滤除，curve=\(spike.curveRPM ?? -1)")
        let after = tick(eng, t, power: 10, temp: 50); t += 0.5
        XCTAssertLessThanOrEqual(after.curveRPM ?? 0, 1400, "尖峰过后应立即回到平台")
    }

    /// 真实持续高温（连续 3 tick 95°C）：曲线必须完整响应到陡坡 —— 去抖不能牺牲真散热。
    func testSustainedHeatStillGetsFullResponse() {
        let eng = makeEngine()
        var t = 0.0
        for _ in 0..<10 { _ = tick(eng, t, power: 10, temp: 50); t += 0.5 }
        var last: Double = 0
        for _ in 0..<3 { last = tick(eng, t, power: 30, temp: 95).curveRPM ?? 0; t += 0.5 }
        XCTAssertGreaterThan(last, 5000,
                             "持续 95°C 必须 full 陡坡响应（前馈之外的真实温升路径），curve=\(last)")
    }

    /// 两个连续 tick 的尖峰：第 1 个被抑制、第 2 个通过 —— 与"真实温升 ≫1s"的判别一致。
    func testTwoTickSpikePassesOnSecond() {
        let eng = makeEngine()
        var t = 0.0
        for _ in 0..<10 { _ = tick(eng, t, power: 10, temp: 50); t += 0.5 }
        let first = tick(eng, t, power: 10, temp: 95); t += 0.5
        let second = tick(eng, t, power: 10, temp: 95); t += 0.5
        XCTAssertLessThanOrEqual(first.curveRPM ?? 0, 1400, "第 1 个尖峰 tick 被抑制")
        XCTAssertGreaterThan(second.curveRPM ?? 0, 5000, "第 2 个连续 tick 放行（真实尖峰语义）")
    }
}
