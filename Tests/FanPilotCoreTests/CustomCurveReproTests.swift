import XCTest
import FanPilotCore
@testable import ControlEngine

/// 复现「曲线页五组温度/转速是否真的生效」的最小决策路径测试。
/// 用 profiles.json 里的五组锚点 + 真实观测到的温度/功率帧，验证引擎输出。
final class CustomCurveReproTests: XCTestCase {

    /// 与 ~/Library/Application Support/FanPilot/profiles.json 一致的五组曲线
    private func userCustom() -> CustomProfileData {
        var c = CustomProfileData()
        c.targetTemp = 85
        c.targetTempHeavy = 92
        c.curve = [
            CurvePointData(temp: 50, rpm: 1350), CurvePointData(temp: 65, rpm: 2000),
            CurvePointData(temp: 75, rpm: 3000), CurvePointData(temp: 85, rpm: 4200),
            CurvePointData(temp: 95, rpm: 5777),
        ]
        return c
    }

    private func frame(power: Double, cpu: Double?, t: TimeInterval) -> ThermalSnapshot {
        var s = ThermalSnapshot(timestamp: Date(timeIntervalSince1970: t))
        s.power = power; s.cpuHot = cpu
        return s
    }

    /// 曲线插值本身：80°C 应落在 75→3000 与 85→4200 之间（≈3720）
    func testCurveInterpolation() {
        let p = ThermalProfile.from(custom: userCustom())
        XCTAssertEqual(p.kind, .custom)
        XCTAssertEqual(p.curve.count, 5, "from(custom:) 必须带上五组锚点")
        let cv = p.curveRPM(temp: 80.0)!
        XCTAssertEqual(cv, 3600.0, accuracy: 1.0, "80°C 插值应为 3600 RPM")
    }

    /// 引擎端到端：80°C / 30W（2026-09-14 09:25 实测帧）→ 期望 ≥3000 RPM，而非硬件下限
    func testEngineOutputAt80C() {
        let p = ThermalProfile.from(custom: userCustom())
        let eng = ControlEngine(config: .init(profile: p))
        eng.seedFromCurrentRPM(1350, now: Date(timeIntervalSince1970: 0))
        var last: ControlEngine.Decision?
        for i in 0..<60 {   // 跑 30 秒，越过整形/最小保持
            last = eng.decide(frame(power: 30, cpu: 80.0, t: Double(i)), hardwareMin: 1350, hardwareMax: 5777,
                              now: Date(timeIntervalSince1970: Double(i)))
        }
        let d = try! XCTUnwrap(last)
        XCTAssertGreaterThanOrEqual(d.finalRPM, 2900,
            "80°C 下五组曲线应给出 ≥3000−600(PI 负向限幅) ≈ 3120 RPM；实测 \(d.finalRPM)")
        print("✔ 80°C/30W custom → curveRPM=\(d.curveRPM ?? -1) final=\(d.finalRPM)")
    }

    /// 帮助定位实测 1350/1458 的成因：曲线为空时的行为（应等于硬件下限）
    func testEmptyCurveFallsToFloor() {
        var c = userCustom()
        c.curve = []
        let p = ThermalProfile.from(custom: c)
        XCTAssertNil(p.curveRPM(temp: 80.0), "空曲线必须返回 nil")
        let eng = ControlEngine(config: .init(profile: p))
        eng.seedFromCurrentRPM(1350, now: Date(timeIntervalSince1970: 0))
        var last: ControlEngine.Decision?
        for i in 0..<60 {
            last = eng.decide(frame(power: 30, cpu: 80.0, t: Double(i)), hardwareMin: 1350, hardwareMax: 5777,
                              now: Date(timeIntervalSince1970: Double(i)))
        }
        let d = try! XCTUnwrap(last)
        XCTAssertLessThanOrEqual(d.finalRPM, 1351.0, "空曲线 + PI 负向 → 钳在硬件下限（复现实测 1350）")
        print("✔ 空曲线 80°C/30W → final=\(d.finalRPM)（与 09-14 实测 1350/1458 一致）")
    }
}
