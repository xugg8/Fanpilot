import Foundation
import FanPilotCore

/// 散热档位（预设）—— 全部参数都可在运行时覆盖，这里给的是**基于本机实测的初版默认值**。
public enum ThermalProfileKind: String, CaseIterable {
    case auto          // 自动：系统控制，本软件只监控不干预
    case cool          // 清凉：目标 88°C，前馈 + PI（**推荐默认**）
    case maxCool       // 最强清凉：目标 82°C（重载 90）+ 快爬坡前馈
    case custom        // 自定义曲线（温度 → 转速）
    case fixed         // 固定转速
}

/// **激发策略**：决定"什么时候才让本软件接管风扇"。
///
/// 设计目标（用户明确要求）：**日常工作不自动激发** —— 只有真的出现负载或真的热起来，
/// 才从"系统自动"切换到"本软件接管"；负载过去后再自动交还。
public struct ActivationPolicy {
    /// 开关：false = 永远接管（用于调试/常驻场景）
    public var enabled: Bool
    /// 激发条件 A：系统功率 ≥ 此值并持续 dwell
    public var engagePower: Double
    /// 激发条件 B：热点温度 ≥ 此值并持续 dwell（低功耗但高温的单线程 boost 场景）
    public var engageTemp: Double
    /// 激发去抖：条件需持续这么久（避免一瞬间的峰值就拉起风扇）
    public var engageDwell: TimeInterval
    /// 交还条件：功率低于 releasePower 且温度低于 releaseTemp，并持续 dwell
    public var releasePower: Double
    public var releaseTemp: Double
    public var releaseDwell: TimeInterval
    /// 可选安全开关：热点 ≥ 此值并持续 handbackDwell → 完全交还系统（含 Ftst=0）。
    /// **默认 nil（关闭）**：实测 Apple 曲线在 110°C 时只有 3235 RPM，
    /// 交还反而让风扇降速、更热。保留此项仅为"极端保守用户"提供选择。
    public var handbackTemp: Double?
    public var handbackDwell: TimeInterval

    public static let daily = ActivationPolicy(
        enabled: true,
        // 2026-09-14 A/B 实测：固件曲线慢 ~150s，负载头 90s 就冲到 115.9°C（超结温规格）。
        // 激发温度 85→80：更早接管，配合前馈把瞬时冲击压平。
        engagePower: 55, engageTemp: 80, engageDwell: 2.0,
        // 2026-09-15：releaseTemp 70→45。本机固件拿到控制权后在闲置策略下会**直接停转风扇**
        // （实测解除武装后 68.6°C 仍 0 RPM），交还一台 50-70°C 的暖机等于放任温度冲回激发点。
        // 45°C 地板：只有真正凉透了才交还，把"交还→停转→升温→再接管"的锯齿窗口堵死。
        //
        // 2026-09-17 复盘修正 45→50：暖和环境下待机热点悬在 45.1-46.5°C，<45 永远不满足
        // → helper 卡在"接管中"把风扇钉在 1350（实测 15:09-15:25、21:12-21:40 两段，各 15-28 分钟）。
        // 固件在闲置策略下 68°C 都会停转，50°C 交还不会引入锯齿，只会把控制权还给固件。
        releasePower: 35, releaseTemp: 50, releaseDwell: 30,
        handbackTemp: nil, handbackDwell: 3.0)

    /// 永远接管（调试用）
    public static let alwaysOn = ActivationPolicy(
        enabled: false,
        engagePower: 0, engageTemp: 0, engageDwell: 0,
        releasePower: -1, releaseTemp: -1, releaseDwell: .infinity,
        handbackTemp: nil, handbackDwell: 3.0)
}

/// 前馈映射的一个锚点
public struct PowerPoint: Equatable {
    public let watts: Double
    public let rpm: Double
    public init(_ watts: Double, _ rpm: Double) { self.watts = watts; self.rpm = rpm }
}

/// 自定义曲线的锚点
public struct CurvePoint: Equatable {
    public let temp: Double
    public let rpm: Double
    public init(_ temp: Double, _ rpm: Double) { self.temp = temp; self.rpm = rpm }
}

public struct ThermalProfile {
    public var kind: ThermalProfileKind
    public var name: String

    // ── 反馈（PI）──
    /// 目标温度。实测：本机 CPU-only 满载 112°C、GPU 满载 100–113°C、结温规格约 110°C。
    /// 88°C 对"日常编译/渲染"是可达目标；双满载场景下 PI 会饱和拉满（见 §1.1 分级承诺）。
    public var targetTemp: Double
    /// **重载档目标温度**：功率 ≥ `heavyPowerThreshold` 时改用此目标。
    /// 用户已确认：GPU 136W 满载压到 **95°C 即可**（不强求 88°C）。
    public var targetTempHeavy: Double?
    /// 判定"重载"的功率阈值
    public var heavyPowerThreshold: Double
    /// 比例增益（RPM/°C）。取 40：20°C 误差 → +800 RPM，响应足够快但不抖。
    public var kp: Double
    /// 积分增益（RPM/(°C·s)）。取 2：慢积分消除稳态误差，不参与瞬态。
    public var ki: Double
    /// PI **正向**修正限幅（温度偏高时最多加多少转速）
    public var trimLimit: Double
    /// PI **负向**修正限幅（温度偏低时最多减多少转速）。
    ///
    /// 故意比正向小得多：热惯性使"现在凉"不代表"马上不热"（实测功率到位后要 16 秒温度才到峰值）。
    /// 若允许大幅负修正，大功率前馈刚把转速抬起来，PI 就会立刻把它压回去 —— 那是反向优化。
    public var trimLimitNegative: Double

    // ── 前馈 ──
    /// 功率 → 基础转速锚点表（空 = 关闭前馈，仅用曲线/PI）
    public var feedForward: [PowerPoint]
    /// 前馈整体偏移（"最强清凉"整体上移）
    public var feedForwardBias: Double

    // ── 整形 ──
    /// 怠速地板。**默认 nil**（= 仅用硬件下限 1350）。
    ///
    /// 早期设计曾用 2500 RPM 地板来"预热抢跑"，但 P1 实测表明风扇 2 秒内即可从 1350 到 4000+，
    /// 抢跑完全来得及 —— 地板只带来持续噪音，收益为零，故默认取消。
    public var idleFloorRPM: Double?
    /// 温度迟滞（±°C），避免在阈值附近抖动
    public var hysteresis: Double
    /// 变化率限制（RPM/s）—— 非对称：快升慢降
    ///
    /// **升速上限故意设得比硬件能力高**（实测风扇可达 ~1270 RPM/s）：软件不该比硬件更慢，
    /// 否则"抢跑"的窗口白白浪费。防振荡靠的是 PI 死区 + 最小保持时间，不是靠限速。
    /// 降速则刻意放慢，避免转速"忽高忽低"的听感。
    public var slewUpRPMps: Double
    public var slewDownRPMps: Double
    /// 同一目标值的最小保持时间
    public var minDwell: TimeInterval

    // ── 激发策略 ──
    public var activation: ActivationPolicy

    // ── 自定义曲线 / 固定转速 ──
    public var curve: [CurvePoint]
    public var fixedRPM: Double?

    /// 从用户可编辑数据构造（App 的曲线编辑器用）
    public static func from(custom c: CustomProfileData) -> ThermalProfile {
        var p = ThermalProfile.profile(.cool)
        p.kind = .custom
        p.name = c.name
        p.targetTemp = c.targetTemp
        p.targetTempHeavy = c.targetTempHeavy
        p.heavyPowerThreshold = c.heavyPowerThreshold
        p.kp = c.kp
        p.ki = c.ki
        p.trimLimit = c.trimPositive
        p.trimLimitNegative = c.trimNegative
        p.idleFloorRPM = c.idleFloorRPM
        p.curve = c.curve.map { CurvePoint($0.temp, $0.rpm) }
        // 抢跑前馈：开 = 采用用户锚点（引擎 .custom 分支取 max(曲线, 前馈)）；
        // 关 = 空（纯温度曲线，滞后响应）。基座 profile(.cool) 的表必须覆盖。
        p.feedForward = c.enableFeedForward ? c.feedForward.map { PowerPoint($0.watts, $0.rpm) } : []
        if !c.respectsActivationGate { p.activation = .alwaysOn }
        return p
    }

    public static func profile(_ kind: ThermalProfileKind) -> ThermalProfile {
        switch kind {
        case .auto:
            return ThermalProfile(kind: .auto, name: "自动（仅监控）",
                                  targetTemp: 0, targetTempHeavy: nil, heavyPowerThreshold: 110,
                                  kp: 0, ki: 0, trimLimit: 0, trimLimitNegative: 0,
                                  feedForward: [], feedForwardBias: 0,
                                  idleFloorRPM: nil, hysteresis: 2,
                                  slewUpRPMps: 800, slewDownRPMps: 300, minDwell: 1,
                                  activation: .daily,
                                  curve: [], fixedRPM: nil)

        case .cool:
            // ★ 推荐默认。前馈锚点来自实测功耗等级：闲置 24–28W / CPU满载 88W / GPU满载 118–136W。
            //   注意前馈故意"保守起步"，由 PI 按实际温度补足 —— 避免一上来就满转速吵人。
            return ThermalProfile(kind: .cool, name: "清凉",
                                  targetTemp: 88, targetTempHeavy: 95, heavyPowerThreshold: 110,
                                  kp: 40, ki: 2, trimLimit: 1500, trimLimitNegative: 600,
                                  feedForward: [PowerPoint(30, 1350),
                                                PowerPoint(45, 1900),
                                                PowerPoint(60, 2600),
                                                PowerPoint(75, 3400),
                                                PowerPoint(90, 4200),
                                                PowerPoint(110, 5000),
                                                PowerPoint(130, 5777)],
                                  feedForwardBias: 0,
                                  idleFloorRPM: nil, hysteresis: 2,
                                  slewUpRPMps: 1500, slewDownRPMps: 300, minDwell: 1,
                                  activation: .daily,
                                  curve: [], fixedRPM: nil)

        case .maxCool:
            return ThermalProfile(kind: .maxCool, name: "最强清凉",
                                  targetTemp: 82, targetTempHeavy: 90, heavyPowerThreshold: 110,
                                  kp: 60, ki: 3, trimLimit: 2000, trimLimitNegative: 800,
                                  // ★ 空闲起点与"清凉"档一致（1350 = 风扇可停转）；
                                  //   "最强"体现在**负载下爬得更快更高**，不是空闲时也一直转。
                                  feedForward: [PowerPoint(30, 1350),
                                                PowerPoint(45, 2400),
                                                PowerPoint(60, 3400),
                                                PowerPoint(75, 4400),
                                                PowerPoint(90, 5200),
                                                PowerPoint(110, 5777)],
                                  feedForwardBias: 0,
                                  idleFloorRPM: nil, hysteresis: 2,          // ★ 地板已取消（见注释）
                                  slewUpRPMps: 1500, slewDownRPMps: 300, minDwell: 1,
                                  activation: .daily,
                                  curve: [], fixedRPM: nil)

        case .custom:
            return ThermalProfile(kind: .custom, name: "自定义曲线",
                                  targetTemp: 88, targetTempHeavy: 95, heavyPowerThreshold: 110,
                                  kp: 0, ki: 0, trimLimit: 0, trimLimitNegative: 0,
                                  feedForward: [], feedForwardBias: 0,
                                  idleFloorRPM: nil, hysteresis: 2,
                                  slewUpRPMps: 1500, slewDownRPMps: 300, minDwell: 1,
                                  activation: .daily,
                                  curve: [CurvePoint(50, 1350), CurvePoint(70, 1350),
                                          CurvePoint(85, 3800),
                                          CurvePoint(95, 5777)],
                                  fixedRPM: nil)

        case .fixed:
            return ThermalProfile(kind: .fixed, name: "固定转速",
                                  targetTemp: 0, targetTempHeavy: nil, heavyPowerThreshold: 110,
                                  kp: 0, ki: 0, trimLimit: 0, trimLimitNegative: 0,
                                  feedForward: [], feedForwardBias: 0,
                                  idleFloorRPM: nil, hysteresis: 0,
                                  slewUpRPMps: 2000, slewDownRPMps: 2000, minDwell: 0.5,
                                  activation: .alwaysOn,
                                  curve: [], fixedRPM: 3000)
        }
    }

    /// 参考机型（M4 Max MacBook Pro 16"）的风扇范围 —— 表里的绝对值都基于它。
    public static let referenceFanMin: Double = 1350
    public static let referenceFanMax: Double = 5777

    /// 把本档所有**绝对 RPM** 按目标机型的实际风扇范围等比缩放。
    ///
    /// 为什么必须做：不同机型风扇范围差很多（Mac mini M4 是 1000–4900，
    /// MacBook Pro 16" 是 1350–5777，Studio 又是另一套）。
    /// 若不缩放，同一张曲线在别的机型上会整体偏高/偏低。
    /// 缩放保持"曲线形状"（各锚点在区间内的相对位置）不变。
    public func scaled(toFanMin fanMin: Double, fanMax: Double) -> ThermalProfile {
        guard fanMax > fanMin else { return self }
        let refSpan = Self.referenceFanMax - Self.referenceFanMin
        let span = fanMax - fanMin
        func scale(_ rpm: Double) -> Double {
            let ratio = (rpm - Self.referenceFanMin) / refSpan      // 参考区间内的相对位置
            return (fanMin + ratio * span).rounded()
        }
        var p = self
        p.feedForward = feedForward.map { PowerPoint($0.watts, scale($0.rpm)) }
        p.curve = curve.map { CurvePoint($0.temp, scale($0.rpm)) }
        p.idleFloorRPM = idleFloorRPM.map(scale)
        p.fixedRPM = fixedRPM.map(scale)
        return p
    }

    /// 当前生效的目标温度：重载（大功率）时用 `targetTempHeavy`
    public func effectiveTargetTemp(power: Double?) -> Double {
        guard let heavy = targetTempHeavy, let p = power, p >= heavyPowerThreshold else {
            return targetTemp
        }
        return heavy
    }

    /// 前馈：功率 → 转速（线性插值，超出两端取端点，含整体偏移）
    public func feedForwardRPM(power: Double?) -> Double? {
        guard !feedForward.isEmpty, let p = power else { return nil }
        let pts = feedForward.sorted { $0.watts < $1.watts }
        var base: Double
        if p <= pts[0].watts { base = pts[0].rpm }
        else if p >= pts[pts.count - 1].watts { base = pts[pts.count - 1].rpm }
        else {
            base = pts[pts.count - 1].rpm
            for i in 1..<pts.count where p <= pts[i].watts {
                let a = pts[i - 1], b = pts[i]
                let t = (p - a.watts) / (b.watts - a.watts)
                base = a.rpm + t * (b.rpm - a.rpm)
                break
            }
        }
        return base + feedForwardBias
    }

    /// 自定义曲线：温度 → 转速（线性插值）
    public func curveRPM(temp: Double?) -> Double? {
        guard !curve.isEmpty, let t = temp else { return nil }
        let pts = curve.sorted { $0.temp < $1.temp }
        if t <= pts[0].temp { return pts[0].rpm }
        if t >= pts[pts.count - 1].temp { return pts[pts.count - 1].rpm }
        for i in 1..<pts.count where t <= pts[i].temp {
            let a = pts[i - 1], b = pts[i]
            let k = (t - a.temp) / (b.temp - a.temp)
            return a.rpm + k * (b.rpm - a.rpm)
        }
        return pts[pts.count - 1].rpm
    }
}
