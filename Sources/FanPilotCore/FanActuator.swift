import Foundation

/// 把 SMC 访问抽象成协议，便于用假实现测试安全关键逻辑
/// （异步生效、Mode 3 锁定、写入被拒等场景无法用真机反复验证）。
public protocol SMCAccess {
    func keyExists(_ key: String) -> Bool
    func allKeys() -> [String]
    func keySize(_ key: String) -> Int
    func read(_ key: String) throws -> Double?
    func keyType(_ key: String) throws -> SMCDataType
    @discardableResult func write(_ key: String, data: [UInt8]) throws -> UInt8
}

extension SMCConnection: SMCAccess {
    public func keyExists(_ key: String) -> Bool {
        (try? keyInfo(key)).map { $0.size > 0 } ?? false
    }
    public func keySize(_ key: String) -> Int { (try? keyInfo(key))?.size ?? 0 }
    public func keyType(_ key: String) throws -> SMCDataType { try keyInfo(key).type }
    public func write(_ key: String, data: [UInt8]) throws -> UInt8 { try writeRaw(key, payload: data) }
}

public struct FanInfo {
    public let index: Int
    public var actualRPM: Double
    public var targetRPM: Double
    public var minRPM: Double
    public var maxRPM: Double
    /// 0 = auto，1 = manual，3 = system（AppleCLPC 缓解态）。**不要假设自动就是 0**。
    public var mode: Double
    public var modeKey: String

    public var isStopped: Bool { actualRPM < 1 && targetRPM < 1 }
    public var isManual: Bool { abs(mode - 1) < 0.5 }
    public var percent: Double { maxRPM > 0 ? actualRPM / maxRPM * 100 : 0 }
}

/// 唯一的 SMC 写入者。
///
/// ## 三条硬事实（真机实测 + macos-smc-fan 逆向调研，已按本机键表适配）
///
/// 1. **SMC 写入异步生效**：写完立即回读会拿到**旧值**，新值要数百毫秒后才可见。
///    → 校验必须带沉降窗口（6 次 × 200ms）。只读一次会把成功误判为失败，
///    而"已解锁但上层以为失败"会留下**无主手动态**，比失败更危险。
///
/// 2. **M4 Max MacBook 默认处于 Mode 3（System）**：此时固件**拒绝**手动模式写入
///    （写 `F0Md=1` 后回读仍是 3）。必须先用 **`Ftst=1`** 这个全局诊断闸门让
///    `thermalmonitord` 松手，再重试写 `F0Md=1`。调研实测：写 Ftst 后约 3–4 秒
///    `F0Md` 才从 3 变 0，重试成功通常需 4–6.5 秒。
///
/// 3. **`thermalmonitord` 会持续 reclaim**：一旦 `Ftst≠1`，几秒内（空闲约 4000ms、
///    高负载可快到 250ms）就把模式抢回 3。→ 维持手动控制必须**常驻 + 周期重断言**。
public final class FanActuator {
    /// ★ 串行化对 SMC 的读写：控制线程写目标转速的同时，
    /// socket 线程在 `HelperCore.status()` 里读风扇状态（refresh）——
    /// 不加锁会并发改 `fans` 数组与同一个 SMC 连接（同类崩溃已由 SensorRegistry 踩过）。
    private let lock = NSRecursiveLock()
    public struct WritePolicy {
        public var verifyAttempts = 6
        public var verifyInterval: TimeInterval = 0.2      // 合计 ~1.2s 沉降窗口
        public var unlockTimeout: TimeInterval = 10.0
        public var unlockRetryInterval: TimeInterval = 0.1
        public var ftstSettleAfterWrite: TimeInterval = 0.5
        public var targetToleranceRPM = 25.0
        public static let `default` = WritePolicy()
    }

    public private(set) var fans: [FanInfo] = []

    /// 线程安全的只读副本。
    /// ★ 审核修复（2026-09-14）：`fans` 的所有**写入**都在锁内（refresh/unlockManual/reassert），
    ///   但此前 status()（socket 线程）与 ControlRunner（控制线程）存在**绕锁直读** ——
    ///   写者持锁、读者不持锁等于没保护，与 09-13 SensorRegistry 字典竞态（5 次 SIGABRT 崩溃）同类。
    ///   任何跨线程读取风扇列表一律走这里，禁止直接摸 `.fans`。
    public func fansSnapshot() -> [FanInfo] {
        lock.lock(); defer { lock.unlock() }
        return fans
    }
    public private(set) var ftstAvailable = false
    public private(set) var ftstArmed = false
    public private(set) var degraded = false
    public private(set) var lastError: String?
    public private(set) var unlockLog: [String] = []

    private let smc: SMCAccess
    private let policy: WritePolicy
    private var originalMode: [Int: Double] = [:]
    /// 我方最近一次成功写入（含校验通过）的目标转速，按风扇索引。
    /// 用途：mode 回读怪癖探测——mode 读回非 manual 但 F%dTg 仍精确等于此值时，
    /// 说明写路径实际有效（压测实测：转速仍跟手），属寄存器回读与控制权不一致。
    private var lastWrittenTarget: [Int: Double] = [:]
    /// 本实例是否真的把模式写成过 manual。
    /// ★ 踩坑：CLI 每次调用都是新进程；若无脑"恢复构造时读到的模式"，
    /// 那么 `fanpilot auto` 会把上一条命令留下的 manual(=1) 当成"原值"再写一遍，
    /// 于是**报告恢复成功、实际仍是手动**（真机 P1 测试中真实发生）。
    private var didTakeControl = false

    public init(smc: SMCAccess, policy: WritePolicy = .default) throws {
        self.smc = smc
        self.policy = policy
        try refresh()
        ftstAvailable = smc.keyExists("Ftst")
        for f in fans where originalMode[f.index] == nil { originalMode[f.index] = f.mode }
    }

    // MARK: - 读

    /// 探测模式键大小写（M1–M4 用 `F%dMd`，M5 用 `F%dmd`），不维护芯片型号表。
    private func modeKey(for index: Int) -> String? {
        for candidate in ["F\(index)Md", "F\(index)md"] where smc.keyExists(candidate) { return candidate }
        return nil
    }

    /// 本机是否有可控风扇。**MacBook Air 全系无风扇**（被动散热），
    /// 此时 FNum 为 0 或不存在 —— 必须退化为"仅监控"，而不是去读不存在的键。
    public private(set) var hasFans = false

    public func refresh() throws {
        lock.lock(); defer { lock.unlock() }
        // 不再默认 2：FNum 缺失或为 0 就是没有风扇（Air），照实处理
        let raw = (try? smc.read("FNum")) ?? nil
        let count = Int(raw ?? 0)
        hasFans = count > 0
        var list: [FanInfo] = []
        guard count > 0 else { fans = []; return }
        for i in 0..<max(1, min(count, 8)) {
            guard let mk = modeKey(for: i),
                  let actual = try smc.read("F\(i)Ac"),
                  let target = try smc.read("F\(i)Tg"),
                  let lo = try smc.read("F\(i)Mn"),
                  let hi = try smc.read("F\(i)Mx"),
                  let mode = try smc.read(mk)
            else { continue }
            list.append(FanInfo(index: i, actualRPM: actual, targetRPM: target,
                                minRPM: lo, maxRPM: hi, mode: mode, modeKey: mk))
        }
        fans = list
    }

    // MARK: - 写入与校验

    @discardableResult
    public func writeVerified(_ key: String, value: Double, type: SMCDataType,
                              tolerance: Double) throws -> Bool {
        // 容忍 result=0x87 (SmcKeySizeMismatch)：实测写 F0Tg 偶发该码但值仍生效
        _ = try smc.write(key, data: SMCCodec.encode(type: type, value: value))
        return try verify(key: key, expected: value, tolerance: tolerance)
    }

    /// 沉降窗口内多次回读 —— 对抗"写入异步生效"
    public func verify(key: String, expected: Double, tolerance: Double) throws -> Bool {
        for attempt in 0..<policy.verifyAttempts {
            if attempt > 0 { Thread.sleep(forTimeInterval: policy.verifyInterval) }
            if let back = try smc.read(key), abs(back - expected) <= tolerance { return true }
        }
        return false
    }

    // MARK: - 解锁（Mode 3 预检静默解锁 → 直写 → Ftst 回退）

    /// 取得手动控制权。
    ///
    /// ## 接管顺序为什么重要（"半生效猛响"的教训）
    /// Ftst=0 时直写 `mode=1` 会**短暂生效 1–2 秒**再被 thermalmonitord 抢回——
    /// 抢回前风扇按 F%dTg 残留的旧目标猛转一下，然后骤停，等 Ftst 解锁后才恢复，
    /// 用户听到"猛响→停→隔几秒→连续工作"的拉锯（压测实测）。
    /// 现在顺序改为：
    ///   1. **先探测 Mode 3**：已处于缓解态且 Ftst 可用 → 跳过直写，先写 Ftst=1
    ///      静默等待解锁窗口（此期间固件拒绝一切 mode 写入，风扇保持怠速，无声）；
    ///   2. **切 manual 前预写目标**：把 F%dTg 先写到接管初始转速（当前实际转速），
    ///      mode=1 生效的瞬间硬件目标就是合理值，不会按残留旧目标爆冲。
    ///
    /// - Parameter initialTargetRPM: 切 manual 前预写的目标转速（nil = 不预写）。
    ///   建议传**当前实际转速**：接管瞬间风扇保持原速，由控制环从该值平滑起步。
    public func unlockManual(initialTargetRPM: Double? = nil) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        unlockLog.removeAll()
        try refresh()
        guard !fans.isEmpty else { lastError = "没有可用风扇"; return false }

        // 阶段 0：Mode 3 预检 —— 缓解态下直写必被抢回（半生效猛响），直接走 Ftst 静默解锁
        let lockedByMode3 = fans.contains { abs($0.mode - 3) < 0.5 }
        var needFtst = false
        if lockedByMode3 {
            guard ftstAvailable else {
                lastError = "处于 Mode 3 锁定，但本机不存在 Ftst 键 —— 无法解锁"
                unlockLog.append(lastError!)
                return false
            }
            needFtst = true
            unlockLog.append("预检：Mode 3 缓解态 → 跳过直写，先静默解锁（避免半生效猛响）")
        } else {
            // 阶段 1：直写（无锁定机型走这条即可）
            for f in fans {
                let type = try smc.keyType(f.modeKey)
                do {
                    // 切 manual 前先预写目标：mode=1 生效瞬间硬件目标即为合理值
                    if let t = initialTargetRPM, smc.keyExists("F\(f.index)Tg") {
                        let tt = try smc.keyType("F\(f.index)Tg")
                        _ = try? smc.write("F\(f.index)Tg",
                                           data: SMCCodec.encode(type: tt, value: clamp(t, fanIndex: f.index)))
                    }
                    _ = try smc.write(f.modeKey, data: SMCCodec.encode(type: type, value: 1))
                } catch {
                    // 非 root 时内核返回 kIOReturnNotPrivileged，这里转成可读诊断
                    lastError = "写入被内核拒绝：\(error) —— 通常是没有 root 权限"
                    unlockLog.append("F\(f.index) 写入被拒：\(error)")
                    return false
                }
                if try verify(key: f.modeKey, expected: 1, tolerance: 0.5) {
                    unlockLog.append("F\(f.index) 直写 mode=1 成功")
                } else {
                    needFtst = true
                    let back = (try? smc.read(f.modeKey)) ?? nil
                    let shown = back.map { String(format: "%.0f", $0) } ?? "n/a"
                    unlockLog.append("F\(f.index) 直写 mode=1 未生效（回读 \(shown)）→ 判定为 Mode 3 锁定")
                }
            }
        }
        if !needFtst {
            didTakeControl = true
            ftstArmed = ftstAvailable && (((try? smc.read("Ftst")) ?? nil) == 1)
            try refresh()
            return true
        }

        // 阶段 2：Ftst 全局闸门
        guard ftstAvailable else {
            lastError = "处于 Mode 3 锁定，但本机不存在 Ftst 键 —— 无法解锁"
            unlockLog.append(lastError!)
            return false
        }
        let ftstType = try smc.keyType("Ftst")
        do {
            _ = try smc.write("Ftst", data: SMCCodec.encode(type: ftstType, value: 1))
        } catch {
            lastError = "写 Ftst 被拒：\(error)"
            unlockLog.append(lastError!)
            return false
        }
        unlockLog.append("已写 Ftst=1，等待 \(policy.ftstSettleAfterWrite)s 后重试 mode=1")
        Thread.sleep(forTimeInterval: policy.ftstSettleAfterWrite)

        let deadline = Date().addingTimeInterval(policy.unlockTimeout)
        var allOK = false
        var rounds = 0
        var lastWrite = Date.distantPast
        // 策略：**写一次 → 轮询回读**；只有隔了 reassertInterval 还没成功才重写。
        // 反面教训：早期每轮（0.1s）都重写，而写入的"生效可见"需要时间，
        // 反复重写会把等待窗口一次次重置 → 永远读不到新值（单元测试里直接暴露）。
        let reassertInterval: TimeInterval = 1.0
        // 预写目标（尽力而为）：解锁窗口内固件在 auto 态可能忽略 F%dTg 写入，
        // 失败无妨——控制环接管后 1 个 tick 内会带校验重写。目的是让 mode=1
        // 生效瞬间硬件目标不是残留旧值（防爆冲）。
        if let t = initialTargetRPM {
            for f in fans {
                if smc.keyExists("F\(f.index)Tg") {
                    let tt = (try? smc.keyType("F\(f.index)Tg")) ?? .float
                    _ = try? smc.write("F\(f.index)Tg",
                                       data: SMCCodec.encode(type: tt, value: clamp(t, fanIndex: f.index)))
                }
            }
            unlockLog.append("已预写目标 \(Int(t)) RPM（切 manual 前垫底）")
        }
        while Date() < deadline {
            rounds += 1
            if Date().timeIntervalSince(lastWrite) >= reassertInterval {
                for f in fans {
                    let type = try smc.keyType(f.modeKey)
                    _ = try smc.write(f.modeKey, data: SMCCodec.encode(type: type, value: 1))
                }
                lastWrite = Date()
            }
            allOK = true
            for f in fans {
                if let v = try smc.read(f.modeKey), abs(v - 1) <= 0.5 {
                    if !(try verify(key: f.modeKey, expected: 1, tolerance: 0.5)) { allOK = false }
                } else {
                    allOK = false
                }
            }
            if allOK { break }
            Thread.sleep(forTimeInterval: policy.unlockRetryInterval)
        }
        unlockLog.append(String(format: "Ftst 解锁：重试 %d 轮 → %@", rounds, allOK ? "成功" : "超时失败"))
        // 解锁成功 → 立即把目标转速带校验落定（预写可能被 auto 态忽略过）
        if allOK, let t = initialTargetRPM {
            var targetOK = true
            for f in fans {
                targetOK = ((try? setTarget(t, fanIndex: f.index)) ?? false) && targetOK
            }
            unlockLog.append(targetOK ? "初始目标已落定" : "初始目标写入未校验通过（控制环将重试）")
        }
        ftstArmed = allOK
        didTakeControl = allOK
        if !allOK { lastError = "Ftst 解锁超时（\(policy.unlockTimeout)s）" }
        try refresh()
        return allOK
    }

    // MARK: - 目标转速

    /// 红线 #1：任何目标转速都不得低于出厂最低转速（`F%dMn`）
    public func clamp(_ rpm: Double, fanIndex: Int) -> Double {
        guard let f = fans.first(where: { $0.index == fanIndex }) else { return rpm }
        return Swift.min(Swift.max(rpm, f.minRPM), f.maxRPM)
    }

    @discardableResult
    public func setTarget(_ rpm: Double, fanIndex: Int) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard fans.contains(where: { $0.index == fanIndex }) else { return false }
        let wanted = clamp(rpm, fanIndex: fanIndex)
        let type = try smc.keyType("F\(fanIndex)Tg")
        let ok = try writeVerified("F\(fanIndex)Tg", value: wanted, type: type,
                                   tolerance: policy.targetToleranceRPM)
        if ok { lastWrittenTarget[fanIndex] = wanted }
        if !ok { lastError = "F\(fanIndex)Tg 写入校验失败（期望 \(wanted)）" }
        return ok
    }

    /// mode 回读怪癖探测：mode 读回**非 manual**，但目标寄存器仍精确等于我方最近写入值。
    /// 压测实测（2026-09-14 两轮 LLM 满载）：此状态下转速仍逐 tick 跟随我方目标（偏差 ≤3 RPM），
    /// 且满载段从未出现——说明写路径有效，是 SMC mode 寄存器**回读与实际控制权不一致**的怪癖，
    /// 不是真的被固件抢回。status() 用它区分"真丢控制"和"回读怪癖"，避免误报。
    public func modeReadbackQuirk(tolerance: Double = 5) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !fans.isEmpty, !fans.contains(where: { $0.isManual }) else { return false }
        return fans.contains { f in
            guard let written = lastWrittenTarget[f.index] else { return false }
            return abs(f.targetRPM - written) <= tolerance
        }
    }

    /// 周期重断言：对抗 thermalmonitord 的 reclaim
    @discardableResult
    public func reassert(targetRPM: Double?) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var ok = true
        for f in fans where !f.isManual {
            let type = try smc.keyType(f.modeKey)
            _ = try smc.write(f.modeKey, data: SMCCodec.encode(type: type, value: 1))
            ok = (try verify(key: f.modeKey, expected: 1, tolerance: 0.5)) && ok
        }
        if let rpm = targetRPM {
            for f in fans { ok = (try setTarget(rpm, fanIndex: f.index)) && ok }
        }
        try refresh()
        return ok
    }

    // MARK: - 恢复自动（顺序关键）

    /// 恢复系统自动控制。
    ///
    /// ## 成功判据（**这里踩过坑，务必注意**）
    /// 目标是"风扇由系统掌控"，而系统的状态有两种合法取值：
    ///   - `mode == 0` → auto（系统管理）
    ///   - `mode == 3` → system（固件缓解态）
    /// **只有 `mode == 1`（manual）才算"仍被我们接管"**。
    ///
    /// 反面教训：早期版本要求"必须回读到 0 才算成功"。但处于 Mode 3 时
    /// **固件会拒绝任何模式写入**（这正是 Mode 3 的定义），于是写 0 失败 →
    /// 明明风扇已在系统手里，却报告"交还失败"——纯属假警报，
    /// 会让用户误以为出了问题。现在改为：**先看是否已经是非 manual，是则直接成功**
    /// （也顺带避免在 Mode 3 下做无意义的写入）。
    @discardableResult
    public func releaseToAuto(target explicitTarget: Double? = 0) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        try refresh()

        // ① 已经在系统掌控下（0 或 3）→ 无需写模式，直接完成
        let alreadyAuto = !fans.isEmpty && !fans.contains(where: { $0.isManual })
        if alreadyAuto {
            resetFtstIfArmed()
            didTakeControl = false
            lastError = nil
            try refresh()
            return true
        }

        // ② 确实处于 manual → 写回模式并校验
        var ok = true
        for f in fans where f.isManual {
            let restore = explicitTarget ?? (didTakeControl ? (originalMode[f.index] ?? 0) : 0)
            let type = try smc.keyType(f.modeKey)
            _ = try smc.write(f.modeKey, data: SMCCodec.encode(type: type, value: restore))
            if !(try verify(key: f.modeKey, expected: restore, tolerance: 0.5)) {
                ok = false
                lastError = "恢复自动失败：\(f.modeKey) 期望 \(restore)"
            }
        }
        try refresh()
        resetFtstIfArmed()
        didTakeControl = false

        // ③ 诚实性检查：只要还有风扇是 manual，就绝不能报告"已交还"
        if fans.contains(where: { $0.isManual }) {
            ok = false
            lastError = "仍有风扇处于 manual（接管未释放）"
        }
        try refresh()
        return ok
    }

    /// 关闭 Ftst 闸门（幂等：当前为 1 才写 0），并确认没有风扇仍处 manual
    private func resetFtstIfArmed() {
        guard ftstAvailable, !fans.contains(where: { $0.isManual }) else { return }
        if let cur = (try? smc.read("Ftst")) ?? nil, cur == 1 {
            if let type = try? smc.keyType("Ftst") {
                _ = try? smc.write("Ftst", data: SMCCodec.encode(type: type, value: 0))
                _ = try? verify(key: "Ftst", expected: 0, tolerance: 0.5)
            }
        }
        ftstArmed = false
    }
}

// MARK: - 阈值分档（替换"92/95 一刀切"）

/// 实测依据：本机 10 核 CPU 满载稳定在 110–112°C，GPU 负载峰值 112.8°C，
/// Apple Silicon 结温规格约 110°C。若按 92°C 就告警，用户一天会被打扰几十次
/// → 告警必然被关掉，安全机制形同虚设。**告警必须稀有才有价值。**
public struct ThermalThresholds {
    public var elevatedTemp: Double = 88
    public var maxFanTemp: Double = 95
    public var notifyTemp: Double = 100
    public var alarmTemp: Double = 105
    public var notifyDwell: TimeInterval = 10
    public var alarmDwell: TimeInterval = 5
    public var jumpDelta: Double = 25
    public static let `default` = ThermalThresholds()
}
