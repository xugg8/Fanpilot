import XCTest
@testable import ControlEngine
import FanPilotCore

/// 2026-09-15 晚间三次暴冲回归：GPU/统一内存突发使 mem 传感器 46→~95°C
/// 存续 6-12s，3-tick 中位数挡不住多 tick 伪迹 → 风扇冲 4600-5005 RPM。
/// 修复 = mem 曲线输入上升斜率限制（默认 3°C/s，下降自由）。
final class MemorySlewTests: XCTestCase {
    private func makeEngine() -> ControlEngine {
        var c = CustomProfileData()
        c.curve = [CurvePointData(temp: 50, rpm: 1350),
                   CurvePointData(temp: 70, rpm: 1350),
                   CurvePointData(temp: 85, rpm: 3800),
                   CurvePointData(temp: 95, rpm: 5777)]
        c.enableFeedForward = false          // 隔离变量：只看曲线对 mem 输入的响应
        c.respectsActivationGate = true
        var p = ThermalProfile.from(custom: c)
        p = p.scaled(toFanMin: 1350, fanMax: 5777)
        return ControlEngine(config: .init(profile: p))
    }

    private func tick(_ eng: ControlEngine, _ t: Double, power: Double, mem: Double) -> ControlEngine.Decision {
        eng.decide(ThermalSnapshot.make(power: power, mem: mem, t: t),
                   hardwareMin: 1350, hardwareMax: 5777,
                   now: Date(timeIntervalSince1970: t))
    }

    /// 6 秒内存突发（46→95 维持 12 tick）后回落：斜率限制下全程钉在 1350 平台。
    func testShortMemBurstStaysOnPlatform() {
        let eng = makeEngine()
        var t = 0.0
        for _ in 0..<10 { _ = tick(eng, t, power: 10, mem: 46); t += 0.5 }
        var peak: Double = 0
        for _ in 0..<12 { peak = max(peak, tick(eng, t, power: 10, mem: 95).curveRPM ?? 0); t += 0.5 }
        XCTAssertLessThanOrEqual(peak, 1400,
                                 "6s 内存突发必须被斜率限制压在平台内，peak=\(peak)")
    }

    /// 12 秒突发（当晚实测最长的尖峰存续）：峰值不得进入陡坡段（对照：修复前 5005 RPM）。
    func testLongMemBurstBoundedBelowSteepSlope() {
        let eng = makeEngine()
        var t = 0.0
        for _ in 0..<10 { _ = tick(eng, t, power: 10, mem: 46); t += 0.5 }
        var peak: Double = 0
        for _ in 0..<24 { peak = max(peak, tick(eng, t, power: 10, mem: 95).curveRPM ?? 0); t += 0.5 }
        // 12s × 3°C/s ≈ +36°C → 输入 ~82°C，位于 70-85 缓坡段，远低于 95°C 满速
        XCTAssertLessThanOrEqual(peak, 3400,
                                 "12s 突发峰值必须显著低于满速，peak=\(peak)")
    }

    /// 真实持续内存过热：~17s 内仍完整爬到满速 —— 斜率限制不牺牲真散热。
    func testSustainedMemHeatStillReachesFullResponse() {
        let eng = makeEngine()
        var t = 0.0
        for _ in 0..<10 { _ = tick(eng, t, power: 10, mem: 46); t += 0.5 }
        var last: Double = 0
        for _ in 0..<40 { last = tick(eng, t, power: 30, mem: 95).curveRPM ?? 0; t += 0.5 }
        XCTAssertGreaterThan(last, 5000,
                             "持续 95°C 内存过热必须完整响应，last=\(last)")
    }

    /// 突发结束后立即跟降：下降不限速，不得滞留高位（中位数在下降沿最多滞后 1 tick）。
    func testMemFallsImmediatelyAfterBurst() {
        let eng = makeEngine()
        var t = 0.0
        for _ in 0..<10 { _ = tick(eng, t, power: 10, mem: 46); t += 0.5 }
        for _ in 0..<24 { _ = tick(eng, t, power: 10, mem: 95); t += 0.5 }
        _ = tick(eng, t, power: 10, mem: 46); t += 0.5          // 下降沿中位数滞后的 1 tick
        let after = tick(eng, t, power: 10, mem: 46)
        XCTAssertLessThanOrEqual(after.curveRPM ?? 0, 1500,
                                 "尖峰消退后应立即回到平台，curve=\(after.curveRPM ?? -1)")
    }
}
