import Foundation
import FanPilotCore

/// 安全守护：独立于控制环的**分档阈值**判断，可随时抢占控制环的输出。
///
/// 为什么不用"92°C 就告警"：本机实测 CPU-only 满载稳定 110–112°C、GPU 满载峰值 112.8°C、
/// Apple Silicon 结温规格约 110°C。按 92°C 告警 → 用户每天被打扰几十次 → 告警被关掉，
/// 安全机制形同虚设。**告警必须稀有才有价值。**
public final class SafetyGuard {
    public struct Event: CustomStringConvertible {
        public enum Kind: String {
            case elevated       // 高负载，静默提高转速
            case forceMax       // 目标拉满
            case notify         // 通知用户
            case alarm          // 告警
            case jump           // 温度突升（前馈兜底）
            case sensorFailure  // 传感器异常
        }
        public let kind: Kind
        public let temp: Double?
        public let family: String?
        public let detail: String
        public var description: String {
            "[\(kind.rawValue)] \(detail)" + (temp.map { String(format: " (%.1f°C", $0) + (family.map { " \($0))" } ?? ")") } ?? "")
        }
    }

    public struct Override {
        public let rpm: Double?          // nil = 不干预
        public let events: [Event]
    }

    private var thresholds: ThermalThresholds
    private var aboveNotifySince: Date?
    private var aboveAlarmSince: Date?
    private var consecutiveForce = 0
    private var lastHotspot: (value: Double, at: Date)?

    public init(thresholds: ThermalThresholds = .default) { self.thresholds = thresholds }
    public var currentThresholds: ThermalThresholds { thresholds }

    /// 每 tick 调用。返回是否要求抢占（并给出目标转速）。
    public func evaluate(_ s: ThermalSnapshot, hardwareMax: Double, now: Date = Date()) -> Override {
        var events: [Event] = []

        // ① 传感器异常 → 保守拉满（**不能因为读不到温度就当没事**）
        if s.isBlind {
            events.append(Event(kind: .sensorFailure, temp: s.hotspot, family: s.hotspotFamily,
                                detail: "关键温度族失明（\(s.deadFamilies.joined(separator: ","))）→ 保守拉满"))
            return Override(rpm: hardwareMax, events: events)
        }

        guard let hot = s.hotspot else {
            return Override(rpm: nil, events: events)
        }

        // ② 温度突升：2 秒内跳升 > jumpDelta → 立即拉满（前馈兜底）
        if let last = lastHotspot {
            let dt = now.timeIntervalSince(last.at)
            if dt <= 2.5, hot - last.value >= thresholds.jumpDelta {
                events.append(Event(kind: .jump, temp: hot, family: s.hotspotFamily,
                                    detail: String(format: "%.1fs 内跳升 %.1f°C → 立即拉满", dt, hot - last.value)))
                lastHotspot = (hot, now)
                return Override(rpm: hardwareMax, events: events)
            }
        }
        lastHotspot = (hot, now)

        // ③ 分档
        if hot >= thresholds.alarmTemp {
            aboveAlarmSince = aboveAlarmSince ?? now
            if now.timeIntervalSince(aboveAlarmSince!) >= thresholds.alarmDwell {
                events.append(Event(kind: .alarm, temp: hot, family: s.hotspotFamily,
                                    detail: "持续高温，建议降低负载（上限 \(thresholds.alarmTemp)°C）"))
            }
            return Override(rpm: hardwareMax, events: events)
        }
        aboveAlarmSince = nil

        if hot >= thresholds.notifyTemp {
            aboveNotifySince = aboveNotifySince ?? now
            if now.timeIntervalSince(aboveNotifySince!) >= thresholds.notifyDwell {
                events.append(Event(kind: .notify, temp: hot, family: s.hotspotFamily,
                                    detail: "持续高于 \(thresholds.notifyTemp)°C"))
            }
            return Override(rpm: hardwareMax, events: events)
        }
        aboveNotifySince = nil

        if hot >= thresholds.maxFanTemp {
            consecutiveForce += 1
            // 连续 2 个采样点才动作 —— 去抖，避免单点毛刺触发
            if consecutiveForce >= 2 {
                events.append(Event(kind: .forceMax, temp: hot, family: s.hotspotFamily,
                                    detail: "超过 \(thresholds.maxFanTemp)°C → 目标拉满"))
                return Override(rpm: hardwareMax, events: events)
            }
            return Override(rpm: nil, events: events)
        }
        consecutiveForce = 0

        if hot >= thresholds.elevatedTemp {
            events.append(Event(kind: .elevated, temp: hot, family: s.hotspotFamily,
                                detail: "高负载（静默提高转速，不通知）"))
        }
        return Override(rpm: nil, events: events)
    }

    public func reset() {
        aboveNotifySince = nil; aboveAlarmSince = nil
        consecutiveForce = 0; lastHotspot = nil
    }
}
