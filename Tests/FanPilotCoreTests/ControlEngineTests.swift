import XCTest
import FanPilotCore
@testable import ControlEngine
@testable import SafetyGuard

/// 回放测试：把 P0/P1 实测到的时序喂给控制器，验证输出行为。
/// 这些测试不需要真机、不需要 root、也不会把机器烤热。
final class ControlEngineReplayTests: XCTestCase {

    /// 造一帧快照
    private func frame(power: Double, cpu: Double?, gpu: Double? = nil,
                       mem: Double? = nil, vrm: Double? = nil, t: TimeInterval) -> ThermalSnapshot {
        var s = ThermalSnapshot(timestamp: Date(timeIntervalSince1970: t))
        s.power = power; s.cpuHot = cpu; s.gpuHot = gpu; s.memHot = mem; s.vrmHot = vrm
        return s
    }

    /// ① 空闲：目标必须停在地板（不得低于硬件下限 1350）
    func testIdleHoldsAtFloor() {
        let eng = ControlEngine(config: .init(profile: .profile(.cool)))
        var t = 0.0
        var last: Double = 0
        for _ in 0..<20 {
            let d = eng.decide(frame(power: 27, cpu: 55, t: t), hardwareMin: 1350, hardwareMax: 5777,
                               now: Date(timeIntervalSince1970: t))
            last = d.finalRPM; t += 0.5
        }
        XCTAssertGreaterThanOrEqual(last, 1350)
        XCTAssertLessThan(last, 1600, "空闲不该被推到高转速（应停在前馈最低锚点附近）")
    }

    /// ② GPU 满载（实测 136W / Tg 100°C / VRM 111°C）：
    ///    前馈必须在**温度还没上来**时就先把转速抬起来 —— 这正是"抢跑"。
    func testFeedForwardJumpsBeforeTemperatureRises() {
        let eng = ControlEngine(config: .init(profile: .profile(.cool)))
        let t0 = 0.0
        _ = eng.decide(frame(power: 27, cpu: 55, t: t0), hardwareMin: 1350, hardwareMax: 5777,
                       now: Date(timeIntervalSince1970: t0))
        // 负载出现，但温度还是凉的（真实场景：功率 2s 内到位，温度要 16s）
        let d = eng.decide(frame(power: 136, cpu: 58, gpu: 52, t: t0 + 2),
                           hardwareMin: 1350, hardwareMax: 5777,
                           now: Date(timeIntervalSince1970: t0 + 2))
        XCTAssertGreaterThan(d.finalRPM, 4000,
                             "功率已到 136W 时转速必须已明显抬起（不能等温度）")
        XCTAssertEqual(d.feedForwardRPM ?? 0, 5777, accuracy: 1, "136W 已超出前馈表末端 → 取满速")
    }

    /// ③ 无振荡：温度在目标附近抖动时，转速不应连续跳变
    func testNoOscillationNearTarget() {
        let eng = ControlEngine(config: .init(profile: .profile(.cool)))
        var t = 0.0
        var targets: [Double] = []
        // 模拟 CPU 满载稳态：88±3°C 抖动（含 SMC 噪声）
        let jitter: [Double] = [88, 90, 87, 89, 91, 88, 86, 89, 90, 87, 88, 89, 88, 87, 89, 88]
        for j in jitter {
            let d = eng.decide(frame(power: 88, cpu: j, t: t), hardwareMin: 1350, hardwareMax: 5777,
                               now: Date(timeIntervalSince1970: t))
            targets.append(d.finalRPM); t += 0.5
        }
        let changes = zip(targets, targets.dropFirst()).filter { abs($0 - $1) > 1 }.count
        XCTAssertLessThanOrEqual(changes, 3, "稳态下目标值不应频繁变化（实测噪声抑制）")
    }

    /// ④ 安全守护：温度 ≥95°C 连续越限 → 目标拉满
    /// 2026-09-15 更新：守护输入经 3-tick 中位数滤 SMC 伪迹，抢占延迟 +1 tick。
    func testSafetyForcesMaxAtThreshold() {
        let eng = ControlEngine(config: .init(profile: .profile(.cool)))
        var t = 0.0
        _ = eng.decide(frame(power: 88, cpu: 80, t: t), hardwareMin: 1350, hardwareMax: 5777,
                       now: Date(timeIntervalSince1970: t)); t += 0.5
        let d1 = eng.decide(frame(power: 88, cpu: 96, t: t), hardwareMin: 1350, hardwareMax: 5777,
                            now: Date(timeIntervalSince1970: t)); t += 0.5
        let d2 = eng.decide(frame(power: 88, cpu: 96, t: t), hardwareMin: 1350, hardwareMax: 5777,
                            now: Date(timeIntervalSince1970: t)); t += 0.5
        let d3 = eng.decide(frame(power: 88, cpu: 96, t: t), hardwareMin: 1350, hardwareMax: 5777,
                            now: Date(timeIntervalSince1970: t))
        XCTAssertFalse(d1.safetyOverride, "单点越限不该立刻抢占（中位数滤伪迹）")
        XCTAssertFalse(d2.safetyOverride, "中位数第 2 tick 仍被基线压制")
        XCTAssertTrue(d3.safetyOverride, "持续越限 3 tick 必须抢占（延迟 0.5s，仍远快于固件）")
        XCTAssertEqual(d3.desiredRPM, 5777, accuracy: 1)
    }

    /// ⑤ 温度突升（2.5 秒内 +25°C 持续）→ 立即拉满，不等去抖
    /// 2026-09-15 更新：跳升经中位数确认，单 tick 伪迹不再触发；持续 2 tick 即触发。
    func testJumpDetection() {
        let eng = ControlEngine(config: .init(profile: .profile(.cool)))
        let t0 = 0.0
        _ = eng.decide(frame(power: 88, cpu: 62, t: t0), hardwareMin: 1350, hardwareMax: 5777,
                       now: Date(timeIntervalSince1970: t0))
        _ = eng.decide(frame(power: 130, cpu: 92, t: t0 + 0.5), hardwareMin: 1350, hardwareMax: 5777,
                       now: Date(timeIntervalSince1970: t0 + 0.5))
        let d = eng.decide(frame(power: 130, cpu: 92, t: t0 + 1.0), hardwareMin: 1350, hardwareMax: 5777,
                           now: Date(timeIntervalSince1970: t0 + 1.0))
        XCTAssertTrue(d.safetyOverride)
        XCTAssertTrue(d.safetyEvents.contains { $0.kind == .jump })
    }

    /// ⑥ 传感器失明 → 保守拉满（不能"读不到就当没事"）
    func testBlindSensorsForceMax() {
        let eng = ControlEngine(config: .init(profile: .profile(.cool)))
        var s = ThermalSnapshot(timestamp: Date(timeIntervalSince1970: 0))
        s.deadFamilies = ["cpu", "gpu", "mem"]
        let d = eng.decide(s, hardwareMin: 1350, hardwareMax: 5777,
                           now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(d.safetyOverride)
        XCTAssertEqual(d.desiredRPM, 5777, accuracy: 1)
    }

    /// ⑦ 最强清凉档：**空闲不应一直转**，但负载下必须比清凉档更激进
    func testMaxCoolIsAggressiveUnderLoadNotAtIdle() {
        let idle = ControlEngine(config: .init(profile: .profile(.maxCool)))
        let di = idle.decide(frame(power: 26, cpu: 50, t: 0), hardwareMin: 1350, hardwareMax: 5777,
                             now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(di.finalRPM, 1350, accuracy: 1, "空闲应回到硬件下限（风扇可停转）")

        // 中等负载下，最强清凉应明显高于清凉
        // 时间必须推进：否则速率限制会因 dt≈0 把转速锁住（那是限速生效，不是档位差异）
        let cool = ControlEngine(config: .init(profile: .profile(.cool)))
        let dc = cool.decide(frame(power: 60, cpu: 80, t: 60), hardwareMin: 1350, hardwareMax: 5777,
                             now: Date(timeIntervalSince1970: 60))
        let dm = idle.decide(frame(power: 60, cpu: 80, t: 60), hardwareMin: 1350, hardwareMax: 5777,
                             now: Date(timeIntervalSince1970: 60))
        XCTAssertGreaterThan(dm.finalRPM, dc.finalRPM, "负载下最强清凉必须更激进")
    }

    /// ⑧ 固定转速档：在安全阈值以下与温度/功率无关
    func testFixedProfile() {
        var p = ThermalProfile.profile(.fixed)
        p.fixedRPM = 2200
        let eng = ControlEngine(config: .init(profile: p))
        // 时间要推进：否则"2 秒内跳升 35°C"会被突升检测正确拦截（那是安全行为，不是档位行为）
        for (i, (pw, hot)) in [(26.0, 50.0), (130.0, 85.0)].enumerated() {
            let t = Double(i) * 60
            let d = eng.decide(frame(power: pw, cpu: hot, t: t), hardwareMin: 1350, hardwareMax: 5777,
                               now: Date(timeIntervalSince1970: t))
            XCTAssertEqual(d.desiredRPM, 2200, accuracy: 1)
        }
    }

    /// ⑧b **安全优先于用户档位**：即使选了固定 2200 RPM，超过安全阈值也必须拉满
    func testSafetyOverridesUserProfile() {
        var p = ThermalProfile.profile(.fixed)
        p.fixedRPM = 2200
        let eng = ControlEngine(config: .init(profile: p))
        var t = 0.0
        _ = eng.decide(frame(power: 130, cpu: 96, t: t), hardwareMin: 1350, hardwareMax: 5777,
                       now: Date(timeIntervalSince1970: t)); t += 0.5
        let d = eng.decide(frame(power: 130, cpu: 97, t: t), hardwareMin: 1350, hardwareMax: 5777,
                           now: Date(timeIntervalSince1970: t))
        XCTAssertTrue(d.safetyOverride)
        XCTAssertEqual(d.desiredRPM, 5777, accuracy: 1, "安全守护必须压过用户的固定转速设置")
    }

    /// ⑨ 自定义曲线：温度→转速单调，端点正确；怠速平台压平到 70°C（吸收传感器跳变）
    func testCustomCurveInterpolation() {
        let p = ThermalProfile.profile(.custom)
        XCTAssertEqual(p.curveRPM(temp: 50)!, 1350, accuracy: 1)
        XCTAssertEqual(p.curveRPM(temp: 95)!, 5777, accuracy: 1)
        // 2026-09-14 曲线改版：50–70°C 全平 1350（传感器 53↔77°C 跳变时目标纹丝不动）
        XCTAssertEqual(p.curveRPM(temp: 70)!, 1350, accuracy: 1, "怠速平台必须延续到 70°C")
        let mid = p.curveRPM(temp: 80)!
        XCTAssertGreaterThan(mid, 2800); XCTAssertLessThan(mid, 3200)
    }

    /// ⑩ 速率限制：单 tick 不会从 1350 直接跳到 5777（防抖），但几秒内能到位
    func testSlewLimitAllowsFullRangeWithinSeconds() {
        let eng = ControlEngine(config: .init(profile: .profile(.cool)))
        eng.seedFromCurrentRPM(1350)                  // 接管时用实际转速做起点
        var t = 0.0
        var rpms: [Double] = []
        for _ in 0..<12 {                       // 6 秒，每 0.5s 一 tick
            let d = eng.decide(frame(power: 136, cpu: 95, t: t), hardwareMin: 1350, hardwareMax: 5777,
                               now: Date(timeIntervalSince1970: t))
            rpms.append(d.finalRPM); t += 0.5
        }
        XCTAssertLessThan(rpms[0], 5777, "首个 tick 不应直接跳到满速（速率限制生效）")
        XCTAssertGreaterThan(rpms[0], 1350, "但必须立刻开始上升（不能干等温度）")
        XCTAssertEqual(rpms.last!, 5777, accuracy: 1, "6 秒内必须能到满速")
    }

    /// ⑪ 阈值配置自检：分档必须递增，告警必须比通知更晚触发
    func testThresholdSanity() {
        let t = ThermalThresholds.default
        XCTAssertLessThan(t.elevatedTemp, t.maxFanTemp)
        XCTAssertLessThan(t.maxFanTemp, t.notifyTemp)
        XCTAssertLessThan(t.notifyTemp, t.alarmTemp)
        XCTAssertGreaterThan(t.notifyDwell, t.alarmDwell)
    }

    /// ⑫ 真机录制的 GPU 时序回放：从实测的 PDTR/Tg 序列驱动，检查策略合理性
    func testReplayRealGPUMeasurement() {
        // 数据来自 Docs/M4Max-SensorMap.md §7.2（136W GPU 满载实测）
        let series: [(t: Double, power: Double, tg: Double, vrm: Double)] = [
            (0, 25.0, 49.6, 53.4), (2, 25.0, 55.0, 55.0), (5, 135.9, 85.5, 96.5),
            (10, 135.7, 89.8, 101.1), (15, 135.3, 96.0, 105.1), (20, 133.3, 99.3, 108.7),
            (30, 121.5, 100.5, 109.4), (46, 124.3, 100.0, 111.7), (70, 118.5, 99.0, 110.0),
        ]
        let eng = ControlEngine(config: .init(profile: .profile(.cool)))
        var targets: [Double] = []
        for f in series {
            let d = eng.decide(frame(power: f.power, cpu: f.tg * 0.85, gpu: f.tg, vrm: f.vrm, t: f.t),
                               hardwareMin: 1350, hardwareMax: 5777,
                               now: Date(timeIntervalSince1970: f.t))
            targets.append(d.finalRPM)
        }
        // 关键断言：Apple 在同样负载下到第 70 秒才 3235 RPM（见 §7.2），
        // 我们的策略必须**在负载出现后立刻接近满速**，而不是慢慢爬。
        XCTAssertGreaterThan(targets[2], 5000, "负载出现 5 秒内就应接近满速（抢跑）")
        XCTAssertEqual(targets.last!, 5777, accuracy: 1, "持续 136W 应维持满速")
        // 且不应出现"降到很低又升回去"的往复
        let drops = zip(targets, targets.dropFirst()).filter { $1 < $0 - 500 }.count
        XCTAssertEqual(drops, 0, "不应出现大幅回落（振荡）")
    }
}

/// 激发策略测试 —— 用户的核心要求：**日常工作不自动激发**
final class ActivationPolicyTests: XCTestCase {

    private func frame(power: Double, cpu: Double?, t: TimeInterval) -> ThermalSnapshot {
        var s = ThermalSnapshot(timestamp: Date(timeIntervalSince1970: t))
        s.power = power; s.cpuHot = cpu
        return s
    }
    private func date(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    /// ① 日常轻工作（浏览/文档/听歌）：功率 30–50W、温度 55–70°C → **永不接管**
    func testLightDailyWorkNeverEngages() {
        let eng = ControlEngine(config: .init(profile: .profile(.cool)))
        var t = 0.0
        for _ in 0..<120 {                                   // 60 秒
            let d = eng.decide(frame(power: 42, cpu: 66, t: t), hardwareMin: 1350, hardwareMax: 5777,
                               now: date(t))
            XCTAssertFalse(d.action.isControlling, "轻负载不该接管：\(d.action.reason)")
            t += 0.5
        }
    }

    /// ② 负载出现（88W 编译）→ 去抖 2 秒后接管
    func testEngagesAfterDwellOnRealLoad() {
        let eng = ControlEngine(config: .init(profile: .profile(.cool)))
        var t = 0.0
        _ = eng.decide(frame(power: 30, cpu: 60, t: t), hardwareMin: 1350, hardwareMax: 5777, now: date(t))
        t += 0.5
        var engaged: TimeInterval?
        for _ in 0..<20 {
            let d = eng.decide(frame(power: 88, cpu: 78, t: t), hardwareMin: 1350, hardwareMax: 5777, now: date(t))
            if d.action.isControlling, engaged == nil { engaged = t }
            t += 0.5
        }
        XCTAssertNotNil(engaged, "真实负载必须能激发接管")
        XCTAssertGreaterThanOrEqual(engaged ?? 0, 2.0, "必须有去抖（不能一瞬间就拉风扇）")
        XCTAssertLessThanOrEqual(engaged ?? 99, 3.0, "去抖不能太久（要来得及抢跑）")
    }

    /// ③ 高温但低功耗（单线程 boost）→ 也应激发
    func testEngagesOnHighTempEvenIfLowPower() {
        let eng = ControlEngine(config: .init(profile: .profile(.cool)))
        var t = 0.0
        var engaged = false
        for _ in 0..<20 {
            let d = eng.decide(frame(power: 40, cpu: 87, t: t), hardwareMin: 1350, hardwareMax: 5777, now: date(t))
            if d.action.isControlling { engaged = true }
            t += 0.5
        }
        XCTAssertTrue(engaged, "低功耗但高温也应激发")
    }

    /// ④ 负载结束后自动交还（默认 30 秒静默期 + 45°C 温度地板）
    func testReleasesAfterLoadEnds() {
        let eng = ControlEngine(config: .init(profile: .profile(.cool)))
        var t = 0.0
        // 先进入接管
        for _ in 0..<10 {
            _ = eng.decide(frame(power: 88, cpu: 80, t: t), hardwareMin: 1350, hardwareMax: 5777, now: date(t))
            t += 0.5
        }
        // 负载结束：功率降到 25W、温度降到 40°C（< 45°C 地板才允许交还）
        var releasedAt: TimeInterval?
        for _ in 0..<140 {                                   // 70 秒
            let d = eng.decide(frame(power: 25, cpu: 40, t: t), hardwareMin: 1350, hardwareMax: 5777, now: date(t))
            if !d.action.isControlling, releasedAt == nil { releasedAt = t }
            t += 0.5
        }
        XCTAssertNotNil(releasedAt, "负载结束后必须自动交还")
        let waited = (releasedAt ?? 0) - 5.0
        XCTAssertGreaterThan(waited, 25, "交还前应有静默期，避免负载抖动导致反复接管")
    }

    /// ④b 暖机不交还：温度 55°C（≥ 45°C 地板）即使功率已降也不撒手 ——
    /// 固件闲置策略会停转风扇，交还暖机等于放任温度冲回激发点。
    func testWarmMachineDoesNotRelease() {
        let eng = ControlEngine(config: .init(profile: .profile(.cool)))
        var t = 0.0
        for _ in 0..<10 {
            _ = eng.decide(frame(power: 88, cpu: 80, t: t), hardwareMin: 1350, hardwareMax: 5777, now: date(t))
            t += 0.5
        }
        for _ in 0..<140 {                                   // 70 秒
            let d = eng.decide(frame(power: 25, cpu: 55, t: t), hardwareMin: 1350, hardwareMax: 5777, now: date(t))
            t += 0.5
            if t > 40 {
                XCTAssertTrue(d.action.isControlling,
                              "55°C ≥ 地板 45°C，必须保持接管：\(d.action.reason)")
            }
        }
    }

    /// ⑤ 安全守护**无视激发策略**直接接管（温度危险时，满速比 Apple 曲线更凉）
    func testSafetyOverridesActivationGate() {
        let eng = ControlEngine(config: .init(profile: .profile(.cool)))
        var t = 0.0
        // 低功率（25W）但温度冲到 97°C
        _ = eng.decide(frame(power: 25, cpu: 96, t: t), hardwareMin: 1350, hardwareMax: 5777, now: date(t))
        t += 0.5
        let d = eng.decide(frame(power: 25, cpu: 97, t: t), hardwareMin: 1350, hardwareMax: 5777, now: date(t))
        XCTAssertTrue(d.safetyOverride)
        XCTAssertTrue(d.action.isControlling, "安全越限时必须接管，不受'日常不激发'限制")
    }

    /// ⑥ 重载（GPU 136W）用 95°C 目标，而非 88°C
    func testHeavyLoadUsesRelaxedTargetTemp() {
        let p = ThermalProfile.profile(.cool)
        XCTAssertEqual(p.effectiveTargetTemp(power: 60), 88, accuracy: 0.01)
        XCTAssertEqual(p.effectiveTargetTemp(power: 136), 95, accuracy: 0.01, "GPU 满载应按用户要求放宽到 95°C")

        // 温度 92°C 时：普通负载已超目标（PI 应加转速），重载仍在目标内（应减转速）
        let engLight = ControlEngine(config: .init(profile: p))
        var sl = ThermalSnapshot(); sl.power = 60; sl.cpuHot = 92
        let dl = engLight.decide(sl, hardwareMin: 1350, hardwareMax: 5777)
        let engHeavy = ControlEngine(config: .init(profile: p))
        var sh = ThermalSnapshot(); sh.power = 136; sh.cpuHot = 92
        let dh = engHeavy.decide(sh, hardwareMin: 1350, hardwareMax: 5777)
        XCTAssertGreaterThan(dl.trim, 0, "普通负载 92°C 已超 88°C 目标 → 提高转速")
        XCTAssertLessThan(dh.trim, 0, "重载 92°C 未超 95°C 目标 → 允许回落")
    }

    /// ⑦ 怠速地板已取消：最强清凉档空闲也回到硬件下限
    func testNoIdleFloorByDefault() {
        let p = ThermalProfile.profile(.maxCool)
        XCTAssertNil(p.idleFloorRPM, "地板已按实测结论取消（风扇 2 秒即可到位，无需预热转速）")
        let eng = ControlEngine(config: .init(profile: p))
        var s = ThermalSnapshot(); s.power = 26; s.cpuHot = 50
        let d = eng.decide(s, hardwareMin: 1350, hardwareMax: 5777)
        XCTAssertEqual(d.finalRPM, 1350, accuracy: 1, "空闲应停在硬件下限，不应保持 2500")
    }
}

/// 可选安全开关：高温时完全交还系统（默认关闭）
final class HandbackSwitchTests: XCTestCase {
    func testHandbackDisabledByDefault() {
        let p = ThermalProfile.profile(.cool)
        XCTAssertNil(p.activation.handbackTemp, "默认必须关闭（交还会让 Apple 曲线降速、更热）")
    }

    func testHandbackEngagesWhenEnabled() {
        var p = ThermalProfile.profile(.cool)
        p.activation.handbackTemp = 102
        p.activation = ActivationPolicy(enabled: true, engagePower: 55, engageTemp: 85, engageDwell: 2,
                                       releasePower: 35, releaseTemp: 70, releaseDwell: 30,
                                       handbackTemp: 102, handbackDwell: 3)
        let eng = ControlEngine(config: .init(profile: p))
        var t = 0.0
        // 先进入接管（安全越限会直接接管）
        for _ in 0..<8 {
            _ = eng.decide(ThermalSnapshot.make(power: 130, cpu: 96, t: t), hardwareMin: 1350, hardwareMax: 5777,
                           now: Date(timeIntervalSince1970: t)); t += 0.5
        }
        // 温度冲到 104°C 并持续
        var released = false
        for _ in 0..<12 {
            let d = eng.decide(ThermalSnapshot.make(power: 130, cpu: 104, t: t), hardwareMin: 1350, hardwareMax: 5777,
                               now: Date(timeIntervalSince1970: t))
            if !d.action.isControlling { released = true }
            t += 0.5
        }
        XCTAssertTrue(released, "启用 handback 后，持续超温必须交还系统")
    }
}


/// 跨机型适配：转速表必须按目标机型的风扇范围缩放
final class PortabilityTests: XCTestCase {
    func testProfileScalesToDifferentFanRange() {
        let p = ThermalProfile.profile(.cool)
        // 参考机型（本站）：范围一致 → 缩放应为恒等
        let same = p.scaled(toFanMin: 1350, fanMax: 5777)
        XCTAssertEqual(same.feedForward.last!.rpm, 5777, accuracy: 1)

        // Mac mini M4（调研实测 1000–4900）→ 最高锚点应落在 4900 附近，而不是 5777
        let mini = p.scaled(toFanMin: 1000, fanMax: 4900)
        XCTAssertEqual(mini.feedForward.last!.rpm, 4900, accuracy: 2, "最高锚点必须落到实际上限")
        XCTAssertEqual(mini.feedForward.first!.rpm, 1000, accuracy: 2, "最低锚点必须落到实际下限")
        // 形状保持：中段锚点应落在新区间内的相同相对位置
        let refMid = (3400.0 - 1350) / (5777 - 1350)
        let miniMid = (mini.feedForward[3].rpm - 1000) / (4900 - 1000)
        XCTAssertEqual(refMid, miniMid, accuracy: 0.02, "曲线形状必须保持")
    }

    func testFanlessMachineHasNoFans() throws {
        let fake = FanlessSMC()
        let act = try FanActuator(smc: fake)
        XCTAssertFalse(act.hasFans, "FNum=0（MacBook Air 无风扇）必须识别为无风扇")
        XCTAssertTrue(act.fans.isEmpty)
        // 无风扇机型：接管应明确失败，而不是崩
        XCTAssertFalse(try act.unlockManual())
        XCTAssertNotNil(act.lastError)
    }
}

/// 模拟无风扇机型（MacBook Air）：FNum = 0，没有 F0* 键
final class FanlessSMC: SMCAccess {
    var values: [String: Double] = ["FNum": 0, "Tp01": 45.0, "Tp02": 46.0, "Tp03": 45.5]
    func keyExists(_ key: String) -> Bool { values[key] != nil }
    func allKeys() -> [String] { Array(values.keys) }
    func keySize(_ key: String) -> Int { key == "FNum" ? 1 : 4 }
    func read(_ key: String) throws -> Double? { values[key] }
    func keyType(_ key: String) throws -> SMCDataType { key == "FNum" ? .ui8 : .float }
    @discardableResult func write(_ key: String, data: [UInt8]) throws -> UInt8 { 0x84 }
}

/// 自定义档位（App 曲线编辑器）的校验与转换
final class CustomProfileTests: XCTestCase {
    func testDefaultCustomProfileIsValid() {
        XCTAssertTrue(CustomProfileData().validate().isEmpty, "默认档位必须合法")
    }

    func testValidationCatchesBadTargetTemp() {
        var c = CustomProfileData(); c.targetTemp = 40
        XCTAssertFalse(c.validate().isEmpty, "40°C 目标温度应被拒绝（低于 60）")
        c.targetTemp = 120
        XCTAssertFalse(c.validate().isEmpty, "120°C 目标温度应被拒绝（高于 105）")
    }

    func testValidationCatchesHeavyLowerThanNormal() {
        var c = CustomProfileData(); c.targetTemp = 95; c.targetTempHeavy = 88
        XCTAssertTrue(c.validate().contains { $0.contains("重载目标温度") })
    }

    func testCurveValidationSemantics() {
        // 重复温度 → 有歧义，必须报错
        var dup = CustomProfileData()
        dup.curve = [CurvePointData(temp: 70, rpm: 3000), CurvePointData(temp: 70, rpm: 4000)]
        XCTAssertTrue(dup.validate().contains { $0.contains("重复温度") })

        // 乱序 → 允许（插值前会排序），归一化后应升序
        var unsorted = CustomProfileData()
        unsorted.curve = [CurvePointData(temp: 90, rpm: 4000), CurvePointData(temp: 70, rpm: 3000)]
        XCTAssertTrue(unsorted.validate().isEmpty, "乱序不该被拒绝")
        XCTAssertEqual(unsorted.normalized().curve.map(\.temp), [70, 90])
        // 归一化后插值仍然正确
        let p = ThermalProfile.from(custom: unsorted.normalized())
        XCTAssertEqual(p.curveRPM(temp: 80)!, 3500, accuracy: 1, "70→3000 / 90→4000 的中点应是 3500")
    }

    /// 2026-09-14：自定义档接入功率前馈（max(曲线,前馈)+PI 抢跑语义）。
    func testCustomProfileFeedForwardSemantics() {
        // 开关开：前馈随档位带入引擎
        let on = ThermalProfile.from(custom: CustomProfileData())
        XCTAssertFalse(on.feedForward.isEmpty, "开启前馈时应带入锚点表")
        // 开关关：纯温度曲线
        var off = CustomProfileData(); off.enableFeedForward = false
        XCTAssertTrue(ThermalProfile.from(custom: off).feedForward.isEmpty, "关闭前馈应为空")
    }

    /// 引擎决策：custom 档期望值 = max(曲线, 前馈) + trim（trim 置零隔离验证 max 逻辑）
    func testCustomEngineTakesMaxOfCurveAndFeedForward() {
        var c = CustomProfileData()
        c.kp = 0; c.ki = 0; c.trimPositive = 0; c.trimNegative = 0
        c.curve = [CurvePointData(temp: 50, rpm: 1350), CurvePointData(temp: 95, rpm: 5777)]
        c.feedForward = [PowerPointData(watts: 30, rpm: 2000), PowerPointData(watts: 100, rpm: 4000)]
        let p = ThermalProfile.from(custom: c)

        func frame(power: Double, cpu: Double, t: TimeInterval) -> ThermalSnapshot {
            var s = ThermalSnapshot(timestamp: Date(timeIntervalSince1970: t))
            s.power = power; s.cpuHot = cpu
            return s
        }
        let eng = ControlEngine(config: .init(profile: p))

        // 70°C：曲线 = 1350 + 4427*(20/45) ≈ 3317.6；前馈@60W = 2000 + 2000*(30/70) ≈ 2857.1
        let d1 = eng.decide(frame(power: 60, cpu: 70, t: 0), hardwareMin: 1350, hardwareMax: 5777, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(d1.desiredRPM, 3317.6, accuracy: 1, "曲线更高时听曲线的")

        // 55°C：曲线 ≈ 1841.9，前馈@60W ≈ 2857.1 → 前馈高（温度盲区里抢跑生效）
        let d2 = eng.decide(frame(power: 60, cpu: 55, t: 1), hardwareMin: 1350, hardwareMax: 5777, now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(d2.desiredRPM, 2857.1, accuracy: 1, "前馈更高时听前馈的（抢跑生效）")
    }

    func testCustomConvertsToThermalProfile() {
        var c = CustomProfileData()
        c.name = "我的档位"; c.targetTemp = 84; c.targetTempHeavy = 92
        c.kp = 55; c.ki = 1.5; c.idleFloorRPM = 2200
        c.curve = [CurvePointData(temp: 50, rpm: 1400), CurvePointData(temp: 95, rpm: 5777)]
        let p = ThermalProfile.from(custom: c)
        XCTAssertEqual(p.name, "我的档位")
        XCTAssertEqual(p.targetTemp, 84, accuracy: 0.01)
        XCTAssertEqual(p.kp, 55, accuracy: 0.01)
        XCTAssertEqual(p.idleFloorRPM!, 2200, accuracy: 0.01)
        XCTAssertEqual(p.curveRPM(temp: 50)!, 1400, accuracy: 1)
        XCTAssertEqual(p.curveRPM(temp: 95)!, 5777, accuracy: 1)
        // 关闭激发门限时应当变成常驻接管
        var c2 = CustomProfileData(); c2.respectsActivationGate = false
        XCTAssertFalse(ThermalProfile.from(custom: c2).activation.enabled)
    }

    func testCustomProfileScalesToOtherFanRange() {
        var c = CustomProfileData(); c.curve = [CurvePointData(temp: 50, rpm: 1350),
                                                CurvePointData(temp: 95, rpm: 5777)]
        let scaled = ThermalProfile.from(custom: c).scaled(toFanMin: 1000, fanMax: 4900)
        XCTAssertEqual(scaled.curveRPM(temp: 50)!, 1000, accuracy: 2)
        XCTAssertEqual(scaled.curveRPM(temp: 95)!, 4900, accuracy: 2)
    }

    func testProfileStorePersistsAndReloads() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fanpilot-test-\(UUID().uuidString)")
        let store = ProfileStore(directory: tmp)
        var c = CustomProfileData(); c.name = "测试档"; c.targetTemp = 86
        store.upsert(c)
        store.prefs.releaseOnQuit = false
        store.save()

        let reloaded = ProfileStore(directory: tmp)
        XCTAssertEqual(reloaded.profile(named: "测试档")?.targetTemp ?? 0, 86, accuracy: 0.01)
        XCTAssertFalse(reloaded.prefs.releaseOnQuit, "偏好设置必须持久化")
        try? FileManager.default.removeItem(at: tmp)
    }
}
