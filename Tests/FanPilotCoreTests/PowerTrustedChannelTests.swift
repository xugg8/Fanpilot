import XCTest
@testable import ControlEngine
import FanPilotCore

/// 2026-09-17 大模型实测复盘：负载 20W→133W，曲线输入被防伪迹管道
/// （3-tick 中位 + 内存 3°C/s 斜率限制）拖住，风扇爬了 ~3.5 分钟，
/// 热点冲到 115.1°C。修复 = **功率可信通道**：伪迹只发生在低功率
/// （<35W）场景，功率 ≥ trustedPowerW(80) 时曲线输入直接用即时原始热点。
final class PowerTrustedChannelTests: XCTestCase {
    private func makeEngine() -> ControlEngine {
        var c = CustomProfileData()
        c.curve = [CurvePointData(temp: 50, rpm: 1350),
                   CurvePointData(temp: 70, rpm: 1350),
                   CurvePointData(temp: 85, rpm: 3800),
                   CurvePointData(temp: 95, rpm: 5777)]
        c.enableFeedForward = false          // 隔离变量：只看曲线输入通道
        c.respectsActivationGate = true
        var p = ThermalProfile.from(custom: c)
        p = p.scaled(toFanMin: 1350, fanMax: 5777)
        return ControlEngine(config: .init(profile: p))
    }

    private func tick(_ eng: ControlEngine, _ t: Double, power: Double,
                      cpu: Double? = nil, mem: Double? = nil) -> ControlEngine.Decision {
        eng.decide(ThermalSnapshot.make(power: power, cpu: cpu, mem: mem, t: t),
                   hardwareMin: 1350, hardwareMax: 5777,
                   now: Date(timeIntervalSince1970: t))
    }

    /// 功率 ≥80W：内存族突发 46→115 必须当 tick 就完整响应（≥80°C 段 → 满速区）。
    func testTrustedPowerBypassesMemSlew() {
        let eng = makeEngine()
        var t = 0.0
        for _ in 0..<10 { _ = tick(eng, t, power: 10, mem: 46); t += 0.5 }
        let d = tick(eng, t, power: 100, cpu: 115, mem: 115)
        XCTAssertGreaterThan(d.curveRPM ?? 0, 5000,
                             "可信功率下原始热点 115°C 必须立即拉满曲线，curve=\(d.curveRPM ?? -1)")
    }

    /// 对照：同样的突发在低功率（10W）下仍被斜率限制压住（防伪迹语义不变）。
    func testLowPowerStillSlewLimited() {
        let eng = makeEngine()
        var t = 0.0
        for _ in 0..<10 { _ = tick(eng, t, power: 10, mem: 46); t += 0.5 }
        var peak: Double = 0
        for _ in 0..<12 { peak = max(peak, tick(eng, t, power: 10, mem: 115).curveRPM ?? 0); t += 0.5 }
        XCTAssertLessThanOrEqual(peak, 3400,
                                 "低功率下 6s 突发仍须压在缓坡段（防伪迹），peak=\(peak)")
    }

    /// 可信期结束后滤波状态已重锚定：功率回落当 tick 曲线不得塌回平台再二次爬坡。
    func testNoPostLoadDipAfterTrustedPeriod() {
        let eng = makeEngine()
        var t = 0.0
        for _ in 0..<10 { _ = tick(eng, t, power: 10, mem: 46); t += 0.5 }
        for _ in 0..<20 { _ = tick(eng, t, power: 100, cpu: 115, mem: 115); t += 0.5 }  // 可信重载 10s
        // 负载消失（功率 10W）但硅温还没降（95°C）：曲线必须仍处于高位
        let after = tick(eng, t, power: 10, cpu: 95, mem: 95)
        XCTAssertGreaterThan(after.curveRPM ?? 0, 5000,
                             "重载结束瞬间温度仍 95°C，曲线不得塌回平台（滤波重锚定验证），curve=\(after.curveRPM ?? -1)")
    }
}
