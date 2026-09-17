import XCTest
@testable import ControlEngine
import FanPilotCore

/// 2026-09-16 夜间复盘三项修复的引擎级回归：
/// ② 激发伪迹交叉验证（低功率+低 raw 的 80°C = 慢坡伪迹，30s 确认）；
/// ③ 凉机超时（<15W 且 raw <55 持续 10min 强制交还，收走伪迹的"续命权"）。
final class ArtifactCrossCheckTests: XCTestCase {
    private func makeEngine() -> ControlEngine {
        var c = CustomProfileData()
        c.curve = [CurvePointData(temp: 50, rpm: 1350),
                   CurvePointData(temp: 70, rpm: 1350),
                   CurvePointData(temp: 85, rpm: 3800),
                   CurvePointData(temp: 95, rpm: 5777)]
        c.enableFeedForward = true
        c.feedForward = [PowerPointData(watts: 30, rpm: 1350),
                         PowerPointData(watts: 130, rpm: 5777)]
        c.respectsActivationGate = true
        var p = ThermalProfile.from(custom: c)
        p = p.scaled(toFanMin: 1350, fanMax: 5777)
        return ControlEngine(config: .init(profile: p))
    }

    /// 伪迹场景帧：保持值被伪迹顶起，raw（真实即时温度）仍在待机水平。
    private func frame(held: Double, raw: Double, power: Double, _ t: Double) -> ThermalSnapshot {
        var s = ThermalSnapshot(timestamp: Date(timeIntervalSince1970: t))
        s.power = power
        s.cpuHot = raw
        s.hotspotHeld = held
        return s
    }

    /// ② 慢坡伪迹激发（held 81 / raw 50 / 20W）：2s 去抖不得激发，30s 确认后才会。
    func testSlowRampArtifactBlocksFastEngage() {
        let eng = makeEngine()
        var t = 0.0
        var at10s: ControlEngine.Action?
        var at31s: ControlEngine.Action?
        for i in 0..<70 {
            let d = eng.decide(frame(held: 81, raw: 50, power: 20, t),
                               hardwareMin: 1350, hardwareMax: 5777,
                               now: Date(timeIntervalSince1970: t))
            if i == 19 { at10s = d.action }
            if i == 63 { at31s = d.action }
            t += 0.5
        }
        guard case .passive = at10s! else {
            return XCTFail("10s 时伪迹必须仍在去抖（旧逻辑 2s 就误激发），实际：\(at10s!)")
        }
        guard case .controlling = at31s! else {
            return XCTFail("若伪迹真的持续 30s（无法排除的真实场景），30s 确认后应接管，实际：\(at31s!)")
        }
    }

    /// ② 有功率支撑的真高温（40W / held 81 / raw 79）：保持 2s 快速激发，不受加严影响。
    func testRealHotWithPowerStillEngagesFast() {
        let eng = makeEngine()
        var t = 0.0
        var engaged: ControlEngine.Action?
        for i in 0..<8 {
            let d = eng.decide(frame(held: 81, raw: 79, power: 40, t),
                               hardwareMin: 1350, hardwareMax: 5777,
                               now: Date(timeIntervalSince1970: t))
            if d.action.isControlling { engaged = d.action; break }
            t += 0.5
        }
        XCTAssertNotNil(engaged, "40W + raw 79°C 是真热，2s 去抖后必须激发")
    }

    /// ③ 凉机超时：接管中被伪迹续命（held 76 / raw 50 / 8W）10 分钟后强制交还。
    func testCoolTimeoutForceReleasesArtifactSustainedControl() {
        let eng = makeEngine()
        var t = 0.0
        // 先用真实负载接管（60W，2s 去抖）
        for _ in 0..<8 {
            _ = eng.decide(frame(held: 70, raw: 68, power: 60, t),
                           hardwareMin: 1350, hardwareMax: 5777,
                           now: Date(timeIntervalSince1970: t))
            t += 0.5
        }
        // 伪迹续命：held 顶在 76，raw 已回落待机水平
        var at5min: ControlEngine.Action?
        var last: ControlEngine.Action?
        var timeoutReasonSeen = false
        for i in 0..<1240 {
            let d = eng.decide(frame(held: 76, raw: 50, power: 8, t),
                               hardwareMin: 1350, hardwareMax: 5777,
                               now: Date(timeIntervalSince1970: t))
            if i == 599 { at5min = d.action }       // 300s：还没到 10min
            if case .passive(let why) = d.action, why.contains("凉机超时") { timeoutReasonSeen = true }
            last = d.action
            t += 0.5
        }
        XCTAssertTrue(at5min!.isControlling, "5 分钟时凉机超时未到，应保持接管")
        XCTAssertTrue(timeoutReasonSeen, "必须出现一次'凉机超时'交还")
        guard case .passive = last! else {
            return XCTFail("10 分钟凉机超时后必须处于交还态，实际：\(last!)")
        }
    }

    /// ③ 中途恢复真实负载：凉机计时复位，累计不得跨负载段落。
    func testCoolTimeoutResetsOnRealLoad() {
        let eng = makeEngine()
        var t = 0.0
        for _ in 0..<8 { _ = eng.decide(frame(held: 70, raw: 68, power: 60, t),
                                        hardwareMin: 1350, hardwareMax: 5777,
                                        now: Date(timeIntervalSince1970: t)); t += 0.5 }
        // 5 分钟伪迹续命
        for _ in 0..<600 {
            _ = eng.decide(frame(held: 76, raw: 50, power: 8, t),
                           hardwareMin: 1350, hardwareMax: 5777,
                           now: Date(timeIntervalSince1970: t)); t += 0.5
        }
        // 1 分钟真实负载（功率 60W：既打断凉机条件，也打断 quiet）
        for _ in 0..<120 {
            _ = eng.decide(frame(held: 70, raw: 68, power: 60, t),
                           hardwareMin: 1350, hardwareMax: 5777,
                           now: Date(timeIntervalSince1970: t)); t += 0.5
        }
        // 再 5 分钟伪迹续命：计时已复位，总共不足 10min
        var last: ControlEngine.Action?
        for _ in 0..<600 {
            let d = eng.decide(frame(held: 76, raw: 50, power: 8, t),
                               hardwareMin: 1350, hardwareMax: 5777,
                               now: Date(timeIntervalSince1970: t))
            last = d.action; t += 0.5
        }
        XCTAssertTrue(last!.isControlling,
                      "负载打断后凉机计时复位，5+1+5 分钟累计不得触发超时交还，实际：\(last!)")
    }
}
