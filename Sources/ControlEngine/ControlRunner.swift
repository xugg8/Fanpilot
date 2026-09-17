import Foundation
import FanPilotCore
import SafetyGuard

/// 控制环的 I/O 外壳：读快照 → 决策 → 下发 → 重断言 → 收尾。
///
/// 安全不变式（与红线一致）：
///  - 任何异常路径都必须尝试**交还系统控制**（`releaseToAuto`）
///  - 关键传感器失明 → 不硬撑，交还系统（系统自己的热管理仍在）
///  - 每次写入都已由 `FanActuator` 做回读校验（带 1.2s 沉降窗口）
///  - 周期性把心跳写入文件，供 launchd 看门狗判断"控制进程是否还活着"
public final class ControlRunner {
    public struct Stats {
        public var ticks = 0
        public var writes = 0
        public var writeFailures = 0
        public var reasserts = 0
        public var safetyEvents: [String] = []
        public var minTarget = Double.infinity
        public var maxTarget = 0.0
        public var maxHotspot = 0.0
        public var peakAt: Date?
        public var targetChanges = 0
    }

    private let engine: ControlEngine
    private let actuator: FanActuator
    private let source: ThermalSource
    private let heartbeatPath: String?
    /// 审核优化：控制环每 tick 都要"报活"，旧实现是每 tick 一次原子写（临时文件+rename）。
    /// 改为节流原地写（≥0.8s 一次），控制环高频调用自动合并。见 HeartbeatWriter 注释。
    private let heartbeat: HeartbeatWriter?
    public private(set) var stats = Stats()
    /// 当前是否处于"已接管"状态（由激发策略驱动）
    public private(set) var isControlling = false
    /// 关键事件回调（接管成功/失败/交还）—— helper 用它写日志。
    /// 2026-09-17 排查"激发没发生"时发现接管失败只进 stats 静默丢弃，完全不可诊断。
    public var onEvent: ((String) -> Void)?
    /// 激发失败日志节流（每 tick 重试会刷屏，30s 记一次足够诊断）
    private var lastAcquireFailLog = Date.distantPast
    private var stopFlag = false
    private var lastReassert = Date.distantPast
    private var lastAckTarget: Double?

    public init(engine: ControlEngine, actuator: FanActuator, source: ThermalSource,
                heartbeatPath: String? = nil) {
        self.engine = engine
        self.actuator = actuator
        self.source = source
        self.heartbeatPath = heartbeatPath
        self.heartbeat = heartbeatPath.map { HeartbeatWriter(path: $0, minInterval: 0.8) }
    }

    public func requestStop() { stopFlag = true }

    /// 取得控制权（Mode 3 预检静默解锁 → 直写 → Ftst 回退）。
    /// 预写目标 = 当前实际转速：mode=1 生效瞬间风扇保持原速，由控制环平滑起步，
    /// 不会按 F%dTg 残留旧值爆冲（"半生效猛响"的根治点之一）。
    public func acquire() throws -> Bool {
        try? actuator.refresh()
        let cur = actuator.fansSnapshot().first?.actualRPM
        let initial = cur.map { actuator.clamp($0, fanIndex: 0) }
        let ok = try actuator.unlockManual(initialTargetRPM: initial)
        if !ok { return false }
        try? actuator.refresh()
        if let cur = actuator.fansSnapshot().first?.actualRPM, cur > 0 {
            engine.seedFromCurrentRPM(cur)      // 首 tick 也从实际转速平滑起步
        }
        lastReassert = Date()
        return true
    }

    /// 交还系统控制
    @discardableResult
    public func release() -> Bool {
        (try? actuator.releaseToAuto(target: 0)) ?? false
    }

    /// 主循环。`duration` 秒后自动收尾；`verbose` 打印每 tick 摘要。
    @discardableResult
    public func run(duration: TimeInterval, verbose: Bool = true,
                    onTick: ((ControlEngine.Decision) -> Void)? = nil) throws -> Stats {
        guard let f0 = actuator.fansSnapshot().first else {
            throw SMCError.keyNotFound(actuator.hasFans ? "F0*" : "FNum（此机型无风扇，仅支持监控）")
        }
        let hwMin = f0.minRPM, hwMax = f0.maxRPM
        let deadline = Date().addingTimeInterval(duration)
        var handedBack = false

        defer {
            // 无论如何都要尝试交还（即使处于 passive 也做一次，确保 Ftst/mode 干净）
            if !handedBack {
                let ok = release()
                stats.safetyEvents.append(ok ? "退出：已交还系统控制"
                                             : "⚠️ 退出：交还系统失败，请手动执行 fanpilot auto")
            }
        }

        while !stopFlag && Date() < deadline {
            let tickStart = Date()
            let snap = source.snapshot()
            let d = engine.decide(snap, hardwareMin: hwMin, hardwareMax: hwMax)
            stats.ticks += 1

            if let h = snap.hotspot {
                if h > stats.maxHotspot { stats.maxHotspot = h; stats.peakAt = snap.timestamp }
            }
            stats.minTarget = min(stats.minTarget, d.finalRPM)
            stats.maxTarget = max(stats.maxTarget, d.finalRPM)
            if let last = lastAckTarget, abs(last - d.finalRPM) > 0.5 { stats.targetChanges += 1 }

            for e in d.safetyEvents {
                stats.safetyEvents.append(e.description)
                if verbose { print("   ⚠️ \(e.description)") }
            }

            // ★ 激发策略：轻负载时不接管（日常使用不会拉起风扇）
            switch d.action {
            case .passive(let why):
                if isControlling {
                    let ok = release()
                    isControlling = false
                    stats.safetyEvents.append("交还系统：\(why)")
                    if verbose { print("   ↩︎ \(why)；已交还系统") }
                    onEvent?("交还系统：\(why)\(ok ? "" : "（交还失败！）")")
                    if !ok, verbose { print("   ⚠️ 交还失败，请手动执行 fanpilot auto") }
                } else if verbose, stats.ticks % 20 == 0 {
                    print("   · 监控中（未接管）：\(why)")
                }
                // ★ passive 路径也必须回报状态：否则 HelperCore.controlling 永远滞留为
                //   最后一次 controlling 的值，App/CSV 会把"已交还"误显示成"接管中"
                //   （2026-09-15 排查 11:29 停转事件时被这个滞留值误导）。
                onTick?(d)
                heartbeat?.beat()
                sleepRemaining(from: tickStart)
                continue
            case .controlling(let why):
                if !isControlling {
                    guard try acquire() else {
                        stats.safetyEvents.append("接管失败：\(actuator.lastError ?? "")")
                        if verbose { print("   ⚠️ 接管失败：\(actuator.lastError ?? "")") }
                        if Date().timeIntervalSince(lastAcquireFailLog) >= 30 {
                            lastAcquireFailLog = Date()
                            onEvent?("接管失败（将持续重试）：\(actuator.lastError ?? "")")
                        }
                        sleepRemaining(from: tickStart)
                        continue
                    }
                    isControlling = true
                    stats.safetyEvents.append("接管：\(why)")
                    if verbose { print("   ⚡️ \(why)；已接管风扇") }
                    onEvent?("接管：\(why)")
                }
            }

            // 关键传感器失明 → 交还系统（不硬撑）
            if snap.isBlind {
                if verbose { print("   ⚠️ 传感器失明，交还系统控制") }
                stats.safetyEvents.append("传感器失明 → 交还系统")
                _ = release(); handedBack = true; isControlling = false
                break
            }

            // 下发目标（带沉降校验）
            do {
                if try actuator.setTarget(d.finalRPM, fanIndex: 0) { stats.writes += 1 }
                else { stats.writeFailures += 1 }
                for f in actuator.fansSnapshot().dropFirst() {
                    _ = try actuator.setTarget(d.finalRPM, fanIndex: f.index)
                }
                lastAckTarget = d.finalRPM

                // 周期重断言：对抗 thermalmonitord 的 reclaim
                if engine.needsReassert(d, sinceLast: Date().timeIntervalSince(lastReassert)) {
                    let ok = try actuator.reassert(targetRPM: d.finalRPM)
                    stats.reasserts += 1
                    lastReassert = Date()
                    if !ok, verbose { print("   ⚠️ 重断言未完全生效（可能被系统抢回）") }
                }
            } catch {
                stats.writeFailures += 1
                stats.safetyEvents.append("写入失败：\(error)")
                if verbose { print("   ❌ 写入失败：\(error) → 交还系统") }
                _ = release(); handedBack = true
                break
            }

            heartbeat?.beat()
            onTick?(d)
            if verbose { print("   \(d.summary)") }

            sleepRemaining(from: tickStart)
        }
        return stats
    }

    private func sleepRemaining(from start: Date) {
        let sleepFor = max(0, engine.config.tickInterval - Date().timeIntervalSince(start))
        if sleepFor > 0 { Thread.sleep(forTimeInterval: sleepFor) }
    }
}
