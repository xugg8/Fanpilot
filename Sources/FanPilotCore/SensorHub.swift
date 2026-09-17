import Foundation

/// 一个时刻的热状态快照 —— 控制器的**唯一输入**。
///
/// 为什么要有这一层：真机上 `Tp*` 单键噪声可达 32–75°C（SMC 多路复用），
/// 直接用单键值驱动风扇会疯狂震荡。这里统一做稳健聚合后再交给控制逻辑。
public struct ThermalSnapshot {
    /// 各族"热点估计值"（已去离群 + 取分位数），nil = 该族本次无有效读数
    public var cpuHot: Double?
    public var gpuHot: Double?
    public var memHot: Double?
    public var vrmHot: Double?
    /// 系统直流功率（W），来自 `PDTR`。**前馈控制的主输入**（比温度早 10–14 秒）
    public var power: Double?
    public var timestamp: Date

    /// 各族样本数与采用数（用于判断传感器是否健康）
    public var samples: [String: (total: Int, used: Int)] = [:]
    /// 读不到任何有效读数的族
    public var deadFamilies: [String] = []

    public init(timestamp: Date = Date()) { self.timestamp = timestamp }

    /// 便捷构造（模拟/测试用）
    public static func make(power: Double?, cpu: Double? = nil, gpu: Double? = nil,
                            mem: Double? = nil, vrm: Double? = nil,
                            t: TimeInterval = 0) -> ThermalSnapshot {
        var s = ThermalSnapshot(timestamp: Date(timeIntervalSince1970: t))
        s.power = power; s.cpuHot = cpu; s.gpuHot = gpu; s.memHot = mem; s.vrmHot = vrm
        return s
    }

    /// 各族"热点估计值"的即时最大值（未做峰值保持）。**必须用族级聚合值，不能用单键。**
    public var hotspotRaw: Double? {
        [cpuHot, gpuHot, memHot, vrmHot].compactMap { $0 }.max()
    }

    /// 对外 hotspot：取「最近 window 秒内的峰值」（由 hub 写入 `hotspotHeld`）。
    /// 测试/回放没有 hub 时 `hotspotHeld == nil`，自动回落到即时值。
    public var hotspot: Double? { hotspotHeld ?? hotspotRaw }

    /// 峰值保持值（hub 维护）。见 `HotspotHold` 的说明。
    public var hotspotHeld: Double?

    public var hotspotFamily: String? {
        let pairs: [(String, Double?)] = [("cpu", cpuHot), ("gpu", gpuHot),
                                          ("mem", memHot), ("vrm", vrmHot)]
        return pairs.compactMap { k, v in v.map { (k, $0) } }.max { $0.1 < $1.1 }?.0
    }

    /// 关键族全部失明 → 控制器必须转入保守策略，而不是"因为读不到就当没事"
    /// 认为"传感器全盲"。★ 必须用**即时值**判断：
    /// 峰值保持会让 hotspot 在传感器失效后仍停留若干秒，用它判断盲区会掩盖故障。
    public var isBlind: Bool { hotspotRaw == nil || deadFamilies.count >= 3 }
}

/// 热数据来源（真机 = SMC；测试 = 录制/合成序列）
public protocol ThermalSource {
    func snapshot() -> ThermalSnapshot
}

/// 热点峰值保持（rolling max）。
///
/// 为什么需要：SMC 是**多路复用**的，某一族偶发读失败时该族本轮直接"消失"，
/// `hotspot` 会单次掉十几度（实测 79.6 → 63.5）。这会带来两个真实危害：
///   1. 菜单栏温度/面板大数字乱跳，用户以为坏了；
///   2. 高温通知的"持续时长"被单次坏读数清零 → 该报的高温不报（P4 的核心功能）。
/// 取最近 window 秒内的最大值：上升沿**无延迟**（新峰值立刻生效），下降沿最多滞后 window 秒
/// （对风扇来说更保守，符合"宁慢勿热"）。
public final class HotspotHold {
    public var window: TimeInterval
    private var history: [(t: Date, v: Double)] = []

    public init(window: TimeInterval = 8) { self.window = window }

    /// 喂一个即时值，返回应该对外汇报的（保持后的）值
    public func update(_ v: Double?, now: Date) -> Double? {
        history.removeAll { now.timeIntervalSince($0.t) > window }
        if let v { history.append((now, v)) }
        return history.map(\.v).max() ?? v
    }

    /// 传感器全盲时清空，避免"拿着旧峰值当现状"
    public func reset() { history.removeAll() }

    public var held: Double? { history.map(\.v).max() }
}

/// 族级物理合理性滤波（2026-09-15 晚间三次风扇误暴冲的根治）。
///
/// SMC 多路复用偶发返回伪迹读数：idle 下族聚合值单 poll 内 48→75+°C 然后回落
/// （硅不可能 0.5s 升 27°C）。伪迹单 tick 本可被中位数滤掉，但它会被
/// `HotspotHold` 放大成 8s 平台（16 个连续高 tick），打穿任何下游中位数
/// —— 21:27 守护在 48°C 误触发拉满就是这条链。
///
/// 规则：**上升限速、下降不限**。满载实测真实温升 ~3.5°C/s，限 8°C/s 余量充足；
/// 真实的快速升温最多延迟几秒跟上，坏读数消退则立即跟随。
/// 放在 SensorHub 源头，曲线/守护/峰值保持/UI 全部受益。
public final class PlausibilityFilter {
    public let maxRiseRate: Double          // °C/s
    private var last: [String: (v: Double, at: Date)] = [:]

    public init(maxRiseRate: Double = 8.0) { self.maxRiseRate = maxRiseRate }

    /// 返回物理上可信的值。`key` 为族名（cpu/gpu/mem/vrm）。
    public func filter(_ v: Double?, key: String, now: Date) -> Double? {
        guard let v else { last[key] = nil; return nil }
        guard let prev = last[key] else {
            last[key] = (v, now)
            return v
        }
        let dt = max(0.05, now.timeIntervalSince(prev.at))
        let cap = prev.v + maxRiseRate * dt
        let out = v > cap ? cap : v          // 超出物理升速的部分判为伪迹，钳制
        last[key] = (out, now)
        return out
    }

    public func reset() { last.removeAll() }
}

/// 慢坡平台闸（2026-09-16 夜间复盘新增，PlausibilityFilter 的补集）。
///
/// 本机伪迹有两种形态：
/// 1. 单 poll 尖峰（48→95→48）——由 `PlausibilityFilter` 的 8°C/s 闸门钳制；
/// 2. **慢坡平台**：以 2-4°C/s 的"合法"坡度多 poll 连续爬升（低于 8°C/s 闸门），
///    把峰值保持顶上 74-80°C 后残留成平台——夜间复盘实测 261 行 held 与 raw
///    偏离 >15°C，导致风扇多转 ~1 小时底速、07:23 完整误接管。
///
/// 指纹：**保持值远高于 raw 滑动中位数，且功率不足以支撑该温度**
/// （真 80°C 必然 ≥55W；待机 <35W 时热点物理上到不了 75°C）。
/// 条件持续 `sustain` 秒 → 判伪迹，复位峰值保持，让 held 立即跟随 raw。
/// 代价：真实负载结束后的下降沿保持窗口从 8s 缩短到 ~4-5s（UI 数字回落稍快，可接受）。
public final class SlowPlateauGate {
    /// 判定偏离阈值（°C）：held 超出 raw 滑动中位数这么多即可疑
    public var deviation: Double = 10
    /// 可疑状态需持续多久才复位保持（秒）
    public var sustain: TimeInterval = 1.5
    /// raw 滑动中位数的时间窗（秒）
    public var medianWindow: TimeInterval = 6
    /// 功率低于此值视为"无负载支撑"（W）
    public var maxPower: Double = 35

    private var rawHistory: [(t: Date, v: Double)] = []
    private var suspectSince: Date?

    public init() {}

    /// 返回 true = 当前峰值保持判为伪迹平台，调用方应复位。
    /// `held` 为当前保持值，`raw` 为本次即时值，`power` 为系统功率（nil 视为待机）。
    public func isArtifact(held: Double, raw: Double, power: Double?, now: Date) -> Bool {
        rawHistory.append((now, raw))
        rawHistory.removeAll { now.timeIntervalSince($0.t) > medianWindow }
        let vs = rawHistory.map(\.v).sorted()
        let med = vs[vs.count / 2]
        let suspect = (held - med) > deviation && (power ?? 0) < maxPower
        if suspect {
            suspectSince = suspectSince ?? now
            return now.timeIntervalSince(suspectSince!) >= sustain
        }
        suspectSince = nil
        return false
    }

    public func reset() { rawHistory.removeAll(); suspectSince = nil }
}

/// 真机实现：用 `SMCAccess` 读 `PDTR` + 四个族，全部走稳健聚合。
public final class SMCSensorHub: ThermalSource {
    private let smc: SMCAccess
    private let registryRef: SensorRegistry?
    private let hold: HotspotHold
    private let plausibility = PlausibilityFilter()
    private let plateauGate = SlowPlateauGate()

    private let registry: SensorRegistry
    /// ★ 串行化整个 snapshot()（poll + 聚合 + 峰值保持）。
    /// 控制线程与 socket 线程都会调它；不加锁就会并发改同一个 Dictionary → SIGABRT。
    private let lock = NSRecursiveLock()

    public init(smc: SMCAccess, registry: SensorRegistry? = nil,
                holdWindow: TimeInterval = 8) throws {
        let reg = try registry ?? SensorRegistry(smc: smc)
        self.smc = smc
        self.registry = reg
        self.registryRef = reg
        self.hold = HotspotHold(window: holdWindow)
    }

    /// 被监控的传感器族数量（用于启动日志/UI）
    public var registeredFamilyCount: Int { self.registryRef?.recordsSnapshot().count ?? 4 }

    public func snapshot() -> ThermalSnapshot {
        lock.lock(); defer { lock.unlock() }
        var s = ThermalSnapshot()
        registry.poll()
        // 取一份副本，后续聚合都在副本上做（poll 期间不受其它线程影响）
        let records = registry.recordsSnapshot()

        func fam(_ f: SensorFamily, _ key: String) {
            if let r = SensorAggregator.aggregate(records, family: f) {
                s.samples[key] = (r.sampleCount, r.usedCount)
                // 物理合理性滤波：单 poll 伪迹尖峰在此钳制（上游中位数/峰值保持才能生效）
                let q = plausibility.filter(r.quantile, key: key, now: s.timestamp)
                switch key {
                case "cpu": s.cpuHot = q
                case "gpu": s.gpuHot = q
                case "mem": s.memHot = q
                case "vrm": s.vrmHot = q
                default: break
                }
            } else {
                s.deadFamilies.append(key)
            }
        }
        fam(.cpu, "cpu")
        fam(.gpu, "gpu")
        fam(.memory, "mem")
        fam(.vrm, "vrm")

        s.power = (try? smc.read("PDTR")) ?? nil

        // 全盲 → 清空保持窗口（不能拿旧峰值冒充现状）
        if s.hotspotRaw == nil { hold.reset() }
        // 慢坡平台闸：保持值与 raw 中位数长期背离且无功率支撑 → 复位保持（在写入前）
        if let held = hold.held, let raw = s.hotspotRaw,
           plateauGate.isArtifact(held: held, raw: raw, power: s.power, now: s.timestamp) {
            hold.reset()
        }
        s.hotspotHeld = hold.update(s.hotspotRaw, now: s.timestamp)
        return s
    }
}

/// 仅供测试/回放：按给定序列产出快照
public final class ScriptedThermalSource: ThermalSource {
    public var frames: [ThermalSnapshot]
    public private(set) var index = 0
    public init(frames: [ThermalSnapshot]) { self.frames = frames }

    public func snapshot() -> ThermalSnapshot {
        defer { if index < frames.count - 1 { index += 1 } }
        return frames[index]
    }
    public var finished: Bool { index >= frames.count - 1 }
}
