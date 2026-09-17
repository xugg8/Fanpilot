import Foundation

/// 高温通知策略（**纯逻辑，不碰 UI**，便于单测与回放）
///
/// 为什么在 App 侧单独做一份，而不是复用 helper 里的 SafetyGuard：
///   · helper 是 **root LaunchDaemon**，它发的通知不会出现在用户的通知中心；
///   · 而且用户可能根本没接管（helper 不在线，App 只是只读监控）——
///     这时依然应该提醒"机器很烫"，所以 App 自己按采样温度独立判断。
///
/// 与 SafetyGuard 的阈值保持一致（100°C/10s 提醒、105°C/5s 报警），
/// 另加 112°C 立即响铃（本机实测 Apple 设计上限就在这附近）。
public struct TempAlertPolicy {

    public enum Level: String, Comparable {
        case warn       // ≥100°C 持续 10s：提醒
        case critical   // ≥105°C 持续 5s：报警
        case emergency  // ≥112°C 立即：紧急（不再等持续时长）

        private var order: Int {
            switch self {
            case .warn: return 0
            case .critical: return 1
            case .emergency: return 2
            }
        }
        public static func < (a: Level, b: Level) -> Bool { a.order < b.order }
    }

    public struct Alert: Equatable {
        public let level: Level
        public let temp: Double
        /// 给用户看的一句话（含建议动作）
        public let title: String
        public let body: String

        public init(level: Level, temp: Double, title: String, body: String) {
            self.level = level; self.temp = temp; self.title = title; self.body = body
        }
    }

    // MARK: 阈值（可调）
    public var warnTemp: Double = 100
    public var warnDwell: TimeInterval = 10
    public var criticalTemp: Double = 105
    public var criticalDwell: TimeInterval = 5
    public var emergencyTemp: Double = 112
    /// 同一级别最短重复间隔，防刷屏
    public var cooldown: TimeInterval = 180
    /// 温度回落到（触发阈值 − 该值）以下才允许再次触发同级
    public var clearDrop: Double = 5
    /// 传感器全失效时是否提醒（只提醒一次）
    public var notifyOnBlind: Bool = true

    public static let `default` = TempAlertPolicy()

    // MARK: 内部状态
    private var aboveWarnSince: Date?
    private var aboveCriticalSince: Date?
    private var lastFired: [Level: Date] = [:]
    private var latched: Set<Level> = []
    private var blindNotified = false

    public init() {}

    /// 当前是否处于"已提醒未恢复"状态（UI 可用来显示一个小警示）
    public var activeLevel: Level? { latched.max() }

    /// 喂一个采样点。`temp == nil` 表示**传感器全盲**（读不到任何有效温度）。
    /// 返回非 nil 表示"现在应该弹一条通知"。
    public mutating func step(temp: Double?, now: Date = Date()) -> Alert? {
        guard let t = temp else {
            var out: Alert?
            if notifyOnBlind, !blindNotified {
                blindNotified = true
                out = Alert(level: .critical, temp: .nan,
                            title: "⚠️ FanPilot 读不到温度传感器",
                            body: "已停止闭环控制（安全设计：读不到温度就不敢乱调风扇）。请检查是否安装了特权组件。")
            }
            return out
        }
        blindNotified = false

        // 恢复判定：掉到「阈值 − clearDrop」以下就解锁该级别
        if t < warnTemp - clearDrop { aboveWarnSince = nil; latched.remove(.warn) }
        if t < criticalTemp - clearDrop { aboveCriticalSince = nil; latched.remove(.critical) }
        if t < emergencyTemp - clearDrop { latched.remove(.emergency) }

        // 持续时长计时
        if t >= warnTemp {
            if aboveWarnSince == nil { aboveWarnSince = now }
        } else {
            aboveWarnSince = nil
        }
        if t >= criticalTemp {
            if aboveCriticalSince == nil { aboveCriticalSince = now }
        } else {
            aboveCriticalSince = nil
        }

        // 由高到低判断，只发一条
        if t >= emergencyTemp {
            return fire(.emergency, temp: t, now: now,
                        title: String(format: "🔥 %.0f°C 已到设计上限", t),
                        body: "建议立刻停掉正在跑的负载（本地大模型 / 视频生成），或打开「最强清凉」档。")
        }
        if t >= criticalTemp, let since = aboveCriticalSince,
           now.timeIntervalSince(since) >= criticalDwell {
            return fire(.critical, temp: t, now: now,
                        title: String(format: "🔥 持续 %.0f°C 已超过 %.0f 秒", t, criticalDwell),
                        body: "风扇应已拉到最大。若仍在升温，请降低负载或插电状态下切到「最强清凉」。")
        }
        if t >= warnTemp, let since = aboveWarnSince,
           now.timeIntervalSince(since) >= warnDwell {
            return fire(.warn, temp: t, now: now,
                        title: String(format: "⚠️ 持续 %.0f°C 已超过 %.0f 秒", t, warnDwell),
                        body: "温度偏高。可切换到「清凉」档接管风扇，或减少后台负载。")
        }
        return nil
    }

    private mutating func fire(_ level: Level, temp: Double, now: Date,
                              title: String, body: String) -> Alert? {
        // 已锁存（本级正在生效且没恢复）→ 不重复
        if latched.contains(level) { return nil }
        if let last = lastFired[level], now.timeIntervalSince(last) < cooldown { return nil }
        latched.insert(level)
        lastFired[level] = now
        return Alert(level: level, temp: temp, title: title, body: body)
    }

    /// 重置（例如用户手动接管/交还、或机器休眠唤醒后）
    public mutating func reset() {
        aboveWarnSince = nil
        aboveCriticalSince = nil
        latched.removeAll()
        blindNotified = false
        // 保留 lastFired：避免"重置后立刻补发一条"
    }
}
