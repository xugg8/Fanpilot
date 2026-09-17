import Foundation
import FanPilotCore

/// 成形器：把"期望转速"整形成"可下发的转速"。
///
/// 三件事，都是实测逼出来的：
///  1. **怠速地板 + 硬件下限**：任何情况下不低于 `F%dMn`（本机 1350），可选更高地板
///  2. **非对称速率限制**：快升（800 RPM/s）慢降（300 RPM/s）。
///     实测风扇本身可达 ~1270 RPM/s，所以这里的限制是**为了抑制振荡**，不是硬件所限。
///  3. **最小保持时间**：同一目标值至少保持 `minDwell`，避免每 tick 微调造成转速抖动
public struct TargetShaper {
    public private(set) var lastTarget: Double?
    public private(set) var lastChangeAt: Date?

    public init() {}

    public struct Output {
        public let rpm: Double
        public let floored: Bool
        public let clampedBySlew: Bool
        public let heldByDwell: Bool
    }

    public mutating func shape(desired: Double,
                               profile: ThermalProfile,
                               hardwareMin: Double,
                               hardwareMax: Double,
                               now: Date = Date()) -> Output {
        let floor = max(profile.idleFloorRPM ?? hardwareMin, hardwareMin)
        var want = min(max(desired, floor), hardwareMax)
        let floored = desired < floor

        var clampedBySlew = false
        if let cur = lastTarget {
            let dt = max(0.001, now.timeIntervalSince(lastChangeAt ?? now))
            let up = profile.slewUpRPMps * dt
            let down = profile.slewDownRPMps * dt
            if want > cur + up { want = cur + up; clampedBySlew = true }
            else if want < cur - down { want = cur - down; clampedBySlew = true }
        }

        var heldByDwell = false
        if let cur = lastTarget, let at = lastChangeAt,
           now.timeIntervalSince(at) < profile.minDwell,
           abs(want - cur) > 1, abs(cur - floor) > 1 {
            want = cur
            heldByDwell = true
        }

        if lastTarget == nil || abs(want - (lastTarget ?? -1)) > 0.5 {
            lastTarget = want
            lastChangeAt = now
        }
        return Output(rpm: want, floored: floored,
                      clampedBySlew: clampedBySlew, heldByDwell: heldByDwell)
    }

    /// 用当前实际转速作为起点 —— 否则第一个 tick 会不受限速地直接跳到期望值。
    /// 正确做法：接管时先 seed，之后的每一次变化都受速率限制约束。
    public mutating func seed(currentRPM: Double, now: Date = Date()) {
        lastTarget = currentRPM
        lastChangeAt = now
    }

    public mutating func reset() { lastTarget = nil; lastChangeAt = nil }
}

/// PI 控制器（带**死区**与抗积分饱和）。
///
/// 为什么不用纯 PID：本机被控对象的纯滞后 ≈ 16 秒（负载→温度峰值），
/// 执行器满行程约 3.5 秒。纯 PID 在这种对象上要么震荡、要么增益被压得极低。
/// 正解是**前馈抢占 + PI 修稳态**：前馈负责"快"，PI 负责"准"。
///
/// **死区**（`profile.hysteresis`）是必需的：SMC 读数本身有 ±2°C 级抖动，
/// 没有死区的话 PI 会跟着噪声不停微调，转速一直"嗡嗡"变。
public struct PIController {
    private var integral: Double = 0
    private var lastTime: Date?

    public init() {}
    public mutating func reset() { integral = 0; lastTime = nil }
    public var integralValue: Double { integral }

    public mutating func trim(hotspot: Double?, profile: ThermalProfile,
                              targetTemp: Double? = nil, now: Date = Date()) -> Double {
        guard profile.kp > 0 || profile.ki > 0, let h = hotspot else { return 0 }
        let dt = lastTime.map { max(0.0, min(2.0, now.timeIntervalSince($0))) } ?? 0
        lastTime = now

        var error = h - (targetTemp ?? profile.targetTemp)
        if abs(error) <= profile.hysteresis { error = 0 }     // 死区：不追噪声

        let pos = profile.trimLimit
        let neg = profile.trimLimitNegative
        if profile.ki > 0, dt > 0 { integral += error * dt * profile.ki }
        integral = max(-neg, min(pos, integral))

        var out = error * profile.kp + integral
        if out > pos { out = pos; integral = min(integral, pos) }              // 抗饱和
        if out < -neg { out = -neg; integral = max(integral, -neg) }
        return out
    }
}
