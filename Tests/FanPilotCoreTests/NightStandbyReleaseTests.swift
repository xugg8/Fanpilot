import XCTest
@testable import ControlEngine
import FanPilotCore

/// 2026-09-15 交还地板改造：releaseTemp 70→45（固件闲置策略会停转风扇，
/// 交还暖机 = 放任温度冲回激发点）。
final class NightStandbyReleaseTests: XCTestCase {
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

    private func simulate(_ eng: ControlEngine, timeline: [(seconds: Double, power: Double, temp: Double)]) -> [String] {
        var reasons: [String] = []
        var t = Date()
        for step in timeline {
            let d = eng.decide(ThermalSnapshot.make(power: step.power, cpu: step.temp,
                                                    t: t.timeIntervalSince1970),
                               hardwareMin: 1350, hardwareMax: 5777, now: t)
            reasons.append("\(Int(step.seconds))s controlling=\(d.action.isControlling) \(d.action.reason)")
            t = t.addingTimeInterval(0.5)
        }
        return reasons
    }

    /// 深待机（3.5W/41.5°C < 50°C 地板）：quiet 30s dwell 后应交还。
    func testDeepIdleStillReleases() {
        let eng = makeEngine()
        XCTAssertEqual(eng.config.profile.activation.releaseTemp, 50)
        var timeline: [(Double, Double, Double)] = []
        for i in 0..<20 { timeline.append((Double(i) * 0.5, 55, 75)) }
        for i in 0..<240 { timeline.append((10 + Double(i) * 0.5, 3.5, 41.5)) }
        let reasons = simulate(eng, timeline: timeline)
        print("A last:  \(reasons.last ?? "")")
        XCTAssertTrue(reasons.last!.contains("controlling=false"),
                      "真正凉透（<50°C）后应照常交还；最后状态：\(reasons.last!)")
    }

    /// 2026-09-17 回归：暖环境待机（8W/46°C 悬在旧地板 45 之上）必须交还。
    /// 实测 15:09-15:25、21:12-21:40 两段 helper 卡死"接管中"、风扇被钉 1350。
    func testWarmAmbientIdleReleases() {
        let eng = makeEngine()
        var timeline: [(Double, Double, Double)] = []
        for i in 0..<40 { timeline.append((Double(i) * 0.5, 60, 78)) }          // 20s 活跃（激发）
        for i in 0..<240 { timeline.append((20 + Double(i) * 0.5, 8, 46.3)) }   // 120s 暖环境待机
        let reasons = simulate(eng, timeline: timeline)
        print("D last:  \(reasons.last ?? "")")
        XCTAssertTrue(reasons.last!.contains("controlling=false"),
                      "46.3°C < 新地板 50°C，120s 后必须交还（否则待机卡 1350）；最后状态：\(reasons.last!)")
    }

    /// 暖机轻载（10W/55°C ≥ 50°C 地板）：不得交还 —— 交还给会停转风扇的固件
    /// 等于放任温度冲回 80°C 激发点（2026-09-15 11:29 型事故的假设路径）。
    func testWarmLightLoadDoesNotRelease() {
        let eng = makeEngine()
        var timeline: [(Double, Double, Double)] = []
        for i in 0..<40 { timeline.append((Double(i) * 0.5, 60, 78)) }        // 20s 活跃（激发）
        for i in 0..<120 { timeline.append((20 + Double(i) * 0.5, 10, 55)) }  // 60s 暖机轻载
        let reasons = simulate(eng, timeline: timeline)
        print("B last:  \(reasons.last ?? "")")
        XCTAssertTrue(reasons.last!.contains("controlling=true"),
                      "55°C ≥ 地板 50°C，应保持接管；最后状态：\(reasons.last!)")
    }

    /// 重载保持 —— 36W/78°C，不应交还（quiet=false，36 ≥ 35W）。
    func testAboveReleasePowerKeepsControl() {
        let eng = makeEngine()
        var timeline: [(Double, Double, Double)] = []
        for i in 0..<40 { timeline.append((Double(i) * 0.5, 60, 78)) }
        for i in 0..<120 { timeline.append((20 + Double(i) * 0.5, 36, 78)) }
        let reasons = simulate(eng, timeline: timeline)
        print("C last:  \(reasons.last ?? "")")
        XCTAssertTrue(reasons.last!.contains("controlling=true"),
                      "36W ≥ releasePower(35) 不满足 quiet，应保持接管")
    }
}
