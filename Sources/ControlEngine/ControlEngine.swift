import Foundation
import FanPilotCore
import SafetyGuard

/// 控制引擎：**决策部分是纯函数**（输入快照 → 输出目标转速），
/// I/O 部分（写 SMC、重断言、心跳）在 `ControlRunner` 里。
///
/// 这样拆分的直接好处：P5 烤机录下来的时序可以直接回放测试控制器，
/// 不需要真机、不需要 root、也不会把机器烤热。
public final class ControlEngine {
    public struct Config {
        public var profile: ThermalProfile
        /// 控制环周期。2 Hz 足够：温度本身的滞后是秒级，且 SMC 读取有开销。
        public var tickInterval: TimeInterval = 0.5
        /// 内存族曲线输入的上升斜率上限（°C/s），下降不限。
        /// GPU/统一内存突发会让 mem 传感器 1-2 tick 内 46→~95°C——这是采样伪迹不是硅温
        /// （LPDDR 热容不可能），但能存续 6-12s，中位数挡不住。按物理发热速率限升：
        /// 3°C/s 下 6s 突发最多爬 ~18°C（平台内，风扇不动）；真实持续过热 ~17s 到顶。
        public var memoryRiseRate: Double = 3.0
        /// 手动模式重断言间隔（空闲 / 有负载）。实测 reclaim 不在 20s 内发生，
        /// 退出后数分钟才回落，所以 3s/1s 是很保守的取值。
        public var reassertIdleInterval: TimeInterval = 3.0
        public var reassertLoadedInterval: TimeInterval = 1.0
        /// 超过这个功率视为"有负载"，加密重断言
        public var loadedPowerThreshold: Double = 60
        /// 功率可信通道（2026-09-17 大模型实测复盘）：传感器伪迹只发生在低功率场景
        /// （暴冲时 11-20W，慢坡伪迹 20W），真实重载 ≥80W。功率达到此值时判定
        /// "温度是真实的"：曲线输入直接用即时原始热点（跳过中位/斜率限制），
        /// 消除猛负载下风扇爬速 3 分钟的滞后（实测 115°C 峰值的根因）。
        public var trustedPowerW: Double = 80
        // ── 慢坡伪迹交叉验证（2026-09-16 夜间复盘）──
        /// 温度型激发的伪迹指纹：热点 ≥ engageTemp 但功率 < 此值且即时(raw)温度 < engageArtifactMaxRawTemp
        /// ——真 80°C 必然 ≥55W；待机 20W 时热点到不了 80°C，那是慢坡伪迹顶起来的保持值。
        /// 此时确认去抖从 engageDwell(2s) 加严到 engageArtifactDwell(30s)。
        public var engageArtifactMaxPower: Double = 35
        public var engageArtifactMaxRawTemp: Double = 70
        public var engageArtifactDwell: TimeInterval = 30
        /// 凉机超时：接管中功率 < coolTimeoutPower 且即时温度 < coolTimeoutRawTemp
        /// 持续 coolTimeout → 强制交还。收走慢坡伪迹通过峰值保持对交还判据的"续命权"
        /// （夜间实测：伪迹把 held 顶在 75-80°C，releaseTemp=45 永远不满足，多转 1 小时底速）。
        /// <15W 时固件停转的无风平衡点 ~50-65°C，远低于 80°C 激发线，交还安全。
        public var coolTimeoutPower: Double = 15
        public var coolTimeoutRawTemp: Double = 55
        public var coolTimeout: TimeInterval = 600
        public init(profile: ThermalProfile) { self.profile = profile }
    }

    /// 引擎本 tick 的动作
    public enum Action: Equatable {
        case passive(reason: String)     // 不接管（系统自动），只监控
        case controlling(reason: String)

        public var isControlling: Bool { if case .controlling = self { return true }; return false }
        public var reason: String {
            switch self {
            case .passive(let r), .controlling(let r): return r
            }
        }
    }

    public struct Decision {
        public let snapshot: ThermalSnapshot
        public let feedForwardRPM: Double?
        public let curveRPM: Double?
        public let trim: Double
        public let desiredRPM: Double
        public let shaped: TargetShaper.Output
        public let finalRPM: Double
        public let safetyEvents: [SafetyGuard.Event]
        public let safetyOverride: Bool
        public let action: Action
        public let effectiveTargetTemp: Double

        public var summary: String {
            let hot = snapshot.hotspot.map { String(format: "%.1f", $0) } ?? "n/a"
            let pw = snapshot.power.map { String(format: "%.0f", $0) } ?? "n/a"
            let ff = feedForwardRPM.map { String(format: "%.0f", $0) } ?? "-"
            let cv = curveRPM.map { String(format: "%.0f", $0) } ?? "-"
            return String(format: "热点 %@°C(%@) 功率 %@W | 前馈 %@ 曲线 %@ 修正 %+.0f → 期望 %.0f → **下发 %.0f RPM**%@",
                          hot, snapshot.hotspotFamily ?? "-", pw, ff, cv, trim, desiredRPM, finalRPM,
                          safetyOverride ? " ⚠️安全抢占" : "")
        }
    }

    public let config: Config
    private var shaper = TargetShaper()
    private var pi = PIController()
    private let guardUnit: SafetyGuard
    // 激发状态机
    private var conditionSince: Date?
    private var conditionKind: String = ""
    private var isControlling = false
    private var releaseSince: Date?
    /// 凉机超时计时（连续 <coolTimeoutPower 且 raw <coolTimeoutRawTemp 的起点）
    private var coolSince: Date?
    /// 曲线输入去抖：最近 3 次热点读数。
    /// 2026-09-15 19:48 实测：轻载（11-16W）下传感器亚采样尖峰 46→~95°C，
    /// 单 tick 就把曲线打进 70-95°C 陡坡段，风扇暴冲 5000 RPM。
    /// 中位数滤除单 tick 毛刺；真实持续高温 2 个 tick（~1s）后完整通过。
    private var hotHistory: [Double] = []

    private func debouncedHotspot(_ h: Double?) -> Double? {
        guard let h else { return nil }
        hotHistory.append(h)
        if hotHistory.count > 3 { hotHistory.removeFirst(hotHistory.count - 3) }
        let sorted = hotHistory.sorted()
        // 1 个元素：原样；2 个元素取较小（宁可少响应也不追毛刺）；3 个取中位数
        return sorted.count == 2 ? sorted[0] : sorted[sorted.count / 2]
    }

    /// 内存族专属平滑（2026-09-15 晚间三次暴冲的根治）：
    /// mem 传感器突发 46→~95°C 能存续 6-12s，3-tick 中位数挡不住多 tick 伪迹。
    /// 先过同样的中位数，再做**上升斜率限制**（下降自由，尖峰消退立即跟随）。
    private var memMedianHistory: [Double] = []
    private var memSlew: Double?

    private func debouncedMemory(_ mem: Double?) -> Double? {
        guard let mem else { return nil }
        memMedianHistory.append(mem)
        if memMedianHistory.count > 3 { memMedianHistory.removeFirst(memMedianHistory.count - 3) }
        let sorted = memMedianHistory.sorted()
        let med = sorted.count == 2 ? sorted[0] : sorted[sorted.count / 2]
        let risePerTick = config.memoryRiseRate * config.tickInterval
        if let cur = memSlew {
            memSlew = med < cur ? med : min(cur + risePerTick, med)
        } else {
            memSlew = med
        }
        return memSlew
    }

    /// 曲线输入的族级合成：内存走专属斜率限制，其余族沿用 3-tick 中位数；
    /// 族数据全缺时回退到聚合热点（测试/回放路径）。
    ///
    /// 2026-09-17 功率可信通道：功率 ≥ trustedPowerW 时伪迹物理上不可能
    /// （LPDDR 假读数只出现在待机/轻载），曲线输入直接用**即时原始热点**
    /// （hotspotRaw，不用 8s 峰值保持——那是给激发判定防抖的，控温要跟当下）。
    /// 滤波状态照常推进并重锚定，负载回落后不出现"风扇先掉底再二次爬坡"。
    private func curveInputTemp(_ s: ThermalSnapshot) -> Double? {
        let trusted = (s.power ?? 0) >= config.trustedPowerW
        let memPart = debouncedMemory(s.memHot)
        let othersMax = [s.cpuHot, s.gpuHot, s.vrmHot].compactMap { $0 }.max()
        let otherPart = debouncedHotspot(othersMax)
        if trusted {
            // memSlew 重锚定到当前中位：否则它停在低位，功率一降 Target 会塌到平台再慢慢爬回
            if let m = memPart { memSlew = m }
            return s.hotspotRaw ?? max(otherPart ?? 0, memPart ?? 0)
        }
        switch (otherPart, memPart) {
        case (let o?, let m?): return max(o, m)
        case (let o?, nil):    return o
        case (nil, let m?):    return m
        default:               return debouncedHotspot(s.hotspot)
        }
    }

    /// 安全守护输入去抖：独立 3-tick 中位数序列（不影响曲线/激发用的原始值）。
    /// 2026-09-15 20:46/20:55 实测：SMC 伪迹尖峰（48→95，单 tick）直接打穿守护的
    /// jump 规则（rise ≥ jumpDelta=25 → 无去抖立即拉满）→ tgt 5777，风扇冲 4585 RPM。
    /// 守护输入过中位数后：单 tick 伪迹被滤除；真实持续过热只延迟 1 tick（0.5s），
    /// 仍比固件曲线快两个数量级。isBlind 等盲区判断用原始快照，不受影响。
    private var guardHistory: [Double] = []

    private func debouncedGuardSnapshot(_ s: ThermalSnapshot) -> ThermalSnapshot {
        guard let h = s.hotspot else { return s }
        guardHistory.append(h)
        if guardHistory.count > 3 { guardHistory.removeFirst(guardHistory.count - 3) }
        let sorted = guardHistory.sorted()
        var sg = s
        sg.hotspotHeld = sorted.count == 2 ? sorted[0] : sorted[sorted.count / 2]
        return sg
    }
    public private(set) var decisions: [Decision] = []

    public init(config: Config, thresholds: ThermalThresholds = .default) {
        self.config = config
        self.guardUnit = SafetyGuard(thresholds: thresholds)
    }

    /// 纯决策：不碰硬件
    public func decide(_ s: ThermalSnapshot,
                       hardwareMin: Double,
                       hardwareMax: Double,
                       now: Date = Date()) -> Decision {
        let profile = config.profile

        // ① 前馈（功率）与曲线（温度）：cool/maxCool 用前馈；custom 两者取 max（见③）
        let ff = profile.feedForwardRPM(power: s.power)
        // 曲线输入经族级去抖：内存族斜率限制 + 其余族 3-tick 中位数（激发/安全判定仍用原始值）
        let cv = profile.curveRPM(temp: curveInputTemp(s))        // ② 有效目标温度（重载时放宽到 targetTempHeavy，例如 GPU 满载 95°C）
        let effTarget = profile.effectiveTargetTemp(power: s.power)

        // ③ PI 修正（死区 + 抗饱和，目标温度随时间档位变化）
        let trim = pi.trim(hotspot: s.hotspot, profile: profile, targetTemp: effTarget, now: now)

        // ③ 期望值
        //    .custom 语义：max(曲线, 前馈) + PI。曲线响应温度（滞后 ~16s），
        //    前馈按功率抢跑（负载一上来就垫转速）；谁算出来的高听谁的。
        //    一侧缺失时另一侧独挑；两侧都缺 → 硬件下限。
        var desired: Double
        switch profile.kind {
        case .fixed:
            desired = profile.fixedRPM ?? hardwareMin
        case .custom:
            let cvBase = cv ?? hardwareMin
            let ffBase = ff ?? cvBase
            desired = max(cvBase, ffBase) + trim
        default:
            desired = (ff ?? hardwareMin) + trim
        }

        // ④ 安全守护可抢占（安全优先级最高）；输入经 3-tick 中位数滤 SMC 伪迹
        let ov = guardUnit.evaluate(debouncedGuardSnapshot(s), hardwareMax: hardwareMax, now: now)
        if let forced = ov.rpm { desired = forced }

        // ⑤ 激发判定：决定本 tick 是"接管"还是"交还/不接管"
        let action = evaluateActivation(s, safetyOverride: ov.rpm != nil, now: now)

        // ⑤ 整形
        let shaped = shaper.shape(desired: desired, profile: profile,
                                  hardwareMin: hardwareMin, hardwareMax: hardwareMax, now: now)

        let d = Decision(snapshot: s, feedForwardRPM: ff, curveRPM: cv, trim: trim,
                         desiredRPM: desired, shaped: shaped, finalRPM: shaped.rpm,
                         safetyEvents: ov.events, safetyOverride: ov.rpm != nil,
                         action: action, effectiveTargetTemp: effTarget)
        decisions.append(d)
        if decisions.count > 4000 { decisions.removeFirst(1000) }
        return d
    }

    /// 激发状态机：**日常工作不激发** —— 只有功率或温度真的上来了才接管，负载过去后自动交还。
    ///
    /// - 激发：功率 ≥ engagePower 持续 engageDwell，或 热点 ≥ engageTemp 持续 engageDwell
    /// - 交还：功率 < releasePower 且 热点 < releaseTemp 持续 releaseDwell
    /// - **安全守护可无视策略直接接管**（温度危险时，我们的满速比 Apple 曲线更凉）
    private func evaluateActivation(_ s: ThermalSnapshot, safetyOverride: Bool, now: Date) -> Action {
        let policy = config.profile.activation
        if !policy.enabled {
            isControlling = true
            return .controlling(reason: "常驻接管（策略已关闭激发门限）")
        }
        // ★ 顺序很重要：用户显式配置的"高温交还"必须**先于**安全守护的"接管"判断，
        //   否则温度越高越会走"拉满接管"分支，交还开关永远不会生效。
        if let hb = policy.handbackTemp, let h = s.hotspot, isControlling, h >= hb {
            releaseSince = releaseSince ?? now
            let held = now.timeIntervalSince(releaseSince!)
            if held >= policy.handbackDwell {
                isControlling = false
                return .passive(reason: String(format: "热点 %.0f°C ≥ %.0f°C 持续 %.0fs → 交还系统（含 Ftst 复位）",
                                               h, hb, held))
            }
            return .controlling(reason: String(format: "超温交还倒计时 %.1fs/%.1fs", held, policy.handbackDwell))
        }

        if safetyOverride {
            isControlling = true
            releaseSince = nil
            coolSince = nil
            return .controlling(reason: "安全守护接管（温度越限）")
        }

        let power = s.power ?? 0
        let hot = s.hotspot ?? 0
        let rawHot = s.hotspotRaw ?? hot

        let overPower = power >= policy.engagePower
        let overTemp = hot >= policy.engageTemp

        if !isControlling {
            if overPower || overTemp {
                var kind = overPower ? "功率 \(String(format: "%.0f", power))W ≥ \(String(format: "%.0f", policy.engagePower))W"
                                     : "热点 \(String(format: "%.0f", hot))°C ≥ \(String(format: "%.0f", policy.engageTemp))°C"
                var dwell = policy.engageDwell
                // 慢坡伪迹交叉验证：纯温度型激发 + 低功率 + 即时温度也低 → 伪迹指纹。
                // 真高温必然有大功率支撑；此时要求 30s 持续确认，伪迹（几秒即退）自然出局。
                if overTemp, !overPower,
                   power < config.engageArtifactMaxPower,
                   rawHot < config.engageArtifactMaxRawTemp {
                    kind += String(format: "（%.0fW + raw %.0f°C，疑似慢坡伪迹）", power, rawHot)
                    dwell = config.engageArtifactDwell
                }
                if conditionKind != kind { conditionKind = kind; conditionSince = now }
                let held = now.timeIntervalSince(conditionSince ?? now)
                if held >= dwell {
                    isControlling = true
                    releaseSince = nil
                    coolSince = nil
                    return .controlling(reason: "激发：\(kind) 持续 \(String(format: "%.1f", held))s")
                }
                return .passive(reason: "\(kind)，去抖中 \(String(format: "%.1f", now.timeIntervalSince(conditionSince ?? now)))s")
            }
            conditionSince = nil; conditionKind = ""
            return .passive(reason: "轻负载（\(String(format: "%.0f", power))W / \(String(format: "%.0f", hot))°C）→ 系统自动")
        }

        // 已在接管：凉机超时（先于常规交还判定——伪迹把 held 顶在 releaseTemp 之上时，
        // quiet 永远不满足，只有这里能收走控制权）
        if power < config.coolTimeoutPower, rawHot < config.coolTimeoutRawTemp {
            coolSince = coolSince ?? now
            let cold = now.timeIntervalSince(coolSince!)
            if cold >= config.coolTimeout {
                isControlling = false
                conditionSince = nil
                return .passive(reason: String(format: "凉机超时（%.0fW / raw %.0f°C 持续 %.0f 分钟）→ 强制交还",
                                               power, rawHot, cold / 60))
            }
        } else {
            coolSince = nil
        }

        // 已在接管：判断是否该交还
        let quiet = power < policy.releasePower && hot < policy.releaseTemp
        if quiet {
            releaseSince = releaseSince ?? now
            let held = now.timeIntervalSince(releaseSince!)
            if held >= policy.releaseDwell {
                isControlling = false
                conditionSince = nil
                return .passive(reason: "负载结束（\(String(format: "%.0f", power))W / \(String(format: "%.0f", hot))°C 持续 \(String(format: "%.0f", held))s）→ 交还系统")
            }
            return .controlling(reason: "负载已结束，\(String(format: "%.0f", now.timeIntervalSince(releaseSince!)))s 后交还")
        }
        releaseSince = nil
        return .controlling(reason: "接管中")
    }

    /// 是否需要重断言手动模式
    public func needsReassert(_ d: Decision, sinceLast: TimeInterval) -> Bool {
        let loaded = (d.snapshot.power ?? 0) >= config.loadedPowerThreshold
        return sinceLast >= (loaded ? config.reassertLoadedInterval : config.reassertIdleInterval)
    }

    public func reset() { shaper.reset(); pi.reset(); guardUnit.reset(); coolSince = nil }

    /// 用当前实际转速给整形器设起点（接管时调用）。
    /// `now` 必须与后续 decide 使用同一时间基准 —— 回放场景要传序列起始时刻，
    /// 否则速率限制会算出 dt≈0 而把转速"锁死"。
    public func seedFromCurrentRPM(_ rpm: Double, now: Date = Date()) {
        shaper.seed(currentRPM: rpm, now: now)
    }
    public var sharedShaper: TargetShaper { shaper }
    public var safetyThresholds: ThermalThresholds { guardUnit.currentThresholds }
}
