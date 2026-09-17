import Foundation
import FanPilotCore
import SafetyGuard

/// 特权 helper 的核心逻辑（可单独测试，不依赖 socket）。
///
/// 安全不变式：
///  - **启动第一件事：无条件交还系统**（红线 #8）—— 崩溃后被 launchd 拉起时，
///    这是唯一可靠的复位点；
///  - 所有写入都经 `FanActuator`（下限钳制 + 回读校验 + 沉降窗口）；
///  - 停止接管/出错/失明 → 立刻交还并复位 `Ftst`；
///  - 心跳写入文件，供外部看门狗判断"helper 是否还活着"。
public final class HelperCore {
    private let smc: SMCConnection
    private let actuator: FanActuator
    private let hub: SMCSensorHub
    private var engine: ControlEngine?
    private var runner: ControlRunner?
    private var controlThread: Thread?
    private let heartbeatPath: String
    private let log: (String) -> Void
    /// 「自动守护」状态落盘位置（root 目录，崩溃/重启后能自动恢复）
    private let armStore: ArmStore

    public private(set) var currentProfile: ThermalProfileKind = .auto
    /// 当前档位显示名（自定义档位时与 kind 无关）
    public private(set) var currentProfileName: String = "自动"
    public private(set) var controlling = false
    public private(set) var lastReason: String?
    /// 自动守护是否开启（= 控制环在跑，哪怕当前是被动等待）
    public private(set) var armed = false
    public private(set) var armedProfile: String?
    /// 当前生效档位的目标温度（供 App 显示"到底几度在生效"）
    public private(set) var activeTargetTemp: Double?
    public private(set) var activeTargetTempHeavy: Double?
    /// mode 回读怪癖的日志去抖（同类信息 60s 最多一条）
    private var lastQuirkLog = Date.distantPast

    public init(heartbeatPath: String = "/tmp/fanpilot-helper.heartbeat",
                armStore: ArmStore = .shared,
                log: @escaping (String) -> Void = { print($0) }) throws {
        self.smc = try SMCConnection()
        self.actuator = try FanActuator(smc: smc)
        self.hub = try SMCSensorHub(smc: smc)
        self.heartbeatPath = heartbeatPath
        self.armStore = armStore
        self.log = log

        // ★ 红线 #8：启动即复位
        let ok = (try? actuator.releaseToAuto(target: 0)) ?? false
        log(ok ? "[helper] 启动自检：已交还系统控制（Ftst 复位）"
               : "[helper] ⚠️ 启动自检：交还失败，请人工检查")
        log("[helper] 传感器族 \(hub.registeredFamilyCount) 个，风扇 \(actuator.fansSnapshot().count) 台，Ftst 可用 \(actuator.ftstAvailable)")
    }

    // MARK: - 状态

    public func status() -> HelperStatus {
        var st = HelperStatus(ok: true)
        let snap = hub.snapshot()
        st.hotspot = snap.hotspot
        st.hotspotRaw = snap.hotspotRaw
        st.cpuHot = snap.cpuHot; st.gpuHot = snap.gpuHot
        st.memHot = snap.memHot; st.vrmHot = snap.vrmHot
        st.power = snap.power
        try? actuator.refresh()
        // 审核修复：跨线程读风扇列表必须走持锁副本（见 FanActuator.fansSnapshot 注释）
        let fans = actuator.fansSnapshot()
        st.fanRPM = fans.map(\.actualRPM)
        st.fanTargets = fans.map(\.targetRPM)
        st.targetRPM = fans.first?.targetRPM
        st.fanMin = fans.first?.minRPM
        st.fanMax = fans.first?.maxRPM
        st.modes = fans.map(\.mode)
        st.ftst = (try? smc.read("Ftst")) ?? nil
        // mode 回读怪癖：接管中但 mode 读回非 manual，而目标寄存器仍是我方写入值。
        // 压测实测此状态下转速跟手、写路径有效 → 如实上报为怪癖而非"丢失控制"。
        if controlling, actuator.modeReadbackQuirk() {
            st.modeQuirk = true
            if Date().timeIntervalSince(lastQuirkLog) > 60 {
                lastQuirkLog = Date()
                log("[helper] ℹ️ mode 回读怪癖：mode=\(st.modes) 非 manual，但 F*Tg 仍为我方写入值（转速跟手，控制有效）")
            }
        } else {
            st.modeQuirk = false
        }
        st.controlling = controlling
        st.profile = currentProfileName
        st.reason = lastReason
        st.helperPID = ProcessInfo.processInfo.processIdentifier
        st.hasFans = actuator.hasFans
        // ★ 守护状态与能力清单必须回传：
        //   之前这几行因为锚点不匹配**没被加进去**，导致 App 拿到的 armed 永远是 false，
        //   界面表现为"点了开关又自己弹回去 / 显示失败"。
        st.armed = armed
        st.armedProfile = armedProfile
        st.features = HelperFeatures.current
        st.targetTemp = activeTargetTemp
        st.targetTempHeavy = activeTargetTempHeavy
        return st
    }

    // MARK: - 接管 / 交还

    @discardableResult
    public func takeover(profile: ThermalProfileKind, rpm: Double? = nil,
                         alwaysOn: Bool = false, handbackTemp: Double? = nil,
                         custom: CustomProfileData? = nil,
                         engageNow: Bool = true) -> HelperStatus {
        stopControlLoop()
        try? actuator.refresh()
        guard let f0 = actuator.fans.first else {
            controlling = false
            let msg = actuator.hasFans ? "未检测到可用风扇控制接口"
                                       : "此机型无风扇（被动散热），本软件仅提供温度监控"
            log("[helper] ⚠️ 接管被拒绝：\(msg)")
            return HelperStatus(ok: false, message: msg)
        }
        // 自定义档位优先；先做参数校验，非法直接拒绝（不要把错误参数下发到硬件）
        if let custom {
            let issues = custom.validate()
            if !issues.isEmpty {
                let msg = "自定义档位参数非法：" + issues.joined(separator: "；")
                log("[helper] ⚠️ 拒绝接管：\(msg)")
                return HelperStatus(ok: false, message: msg)
            }
        }
        // ★ 跨机型适配：把策略里的绝对 RPM 缩放到本机实际风扇范围
        var p = (custom.map { ThermalProfile.from(custom: $0) } ?? ThermalProfile.profile(profile))
            .scaled(toFanMin: f0.minRPM, fanMax: f0.maxRPM)
        if let rpm, profile == .fixed { p.fixedRPM = rpm }
        if alwaysOn { p.activation = .alwaysOn }
        if let hb = handbackTemp { p.activation.handbackTemp = hb }

        let eng = ControlEngine(config: .init(profile: p))
        let run = ControlRunner(engine: eng, actuator: actuator, source: hub,
                                heartbeatPath: heartbeatPath)
        engine = eng; runner = run
        currentProfile = profile

        do {
            if engageNow {
                guard try run.acquire() else {
                    let msg = actuator.lastError ?? "解锁失败"
                    log("[helper] ⚠️ 接管失败：\(msg)")
                    return HelperStatus(ok: false, message: msg)
                }
                controlling = true
                currentProfileName = p.name
                activeTargetTemp = p.targetTemp
                activeTargetTempHeavy = p.targetTempHeavy
                lastReason = "已接管（\(p.name)）"
                log("[helper] ✅ 已接管：\(p.name)  目标温度 \(Int(p.targetTemp))°C\(rpm.map { "  固定 \(Int($0)) RPM" } ?? "")")
            } else {
                // 守护路径（engageNow=false）：凉时**完全不碰风扇**（与 arm() 注释语义一致）。
                // 硬件留在固件手中（闲置停转）；达到激发门槛后由控制环的 .controlling 分支
                // 调 acquire() 正式接管。之前的实现是 arm 也立即 acquire —— 引擎随后的
                // passive 永远不触发 release（runner.isControlling 从未置 true），硬件被
                // 孤儿式锁在 manual@seedRPM 整夜（2026-09-15 凌晨 1350 之谜的真相）。
                controlling = false
                currentProfileName = p.name
                activeTargetTemp = p.targetTemp
                activeTargetTempHeavy = p.targetTempHeavy
                lastReason = "守护待命（\(p.name)，≥\(Int(p.activation.engageTemp))°C 或 ≥\(Int(p.activation.engagePower))W 接管）"
                log("[helper] 🛡 守护待命：\(p.name)（凉时不碰风扇，激发后接管）")
            }
            startControlLoop(run: run)
            return status()
        } catch {
            log("[helper] ⚠️ 接管异常：\(error)")
            return HelperStatus(ok: false, message: "\(error)")
        }
    }

    // MARK: - 自动守护（不用先点按钮，热了会自己介入）

    /// 开启自动守护：把档位落盘（崩溃/重启后自动恢复），并**立刻**开始跑控制环。
    ///
    /// 注意与 `takeover` 的区别：这里默认用档位自带的**激发策略**（`.daily`），
    /// 也就是凉的时候完全被动（不碰风扇）、超过激发温度或功率门槛才真正接管。
    /// 这样既满足"闲置时别乱转风扇"，又满足"负载上来一定有人管"。
    @discardableResult
    public func arm(profile: ThermalProfileKind, custom: CustomProfileData? = nil,
                    alwaysOn: Bool = false) -> HelperStatus {
        do {
            try armStore.save(ArmedState(profile: profile.rawValue, custom: custom,
                                         alwaysOn: alwaysOn))
            let ap = ActivationPolicy.daily
            log("[helper] 🛡 自动守护已开启：档位=\(profile.rawValue)"
                + (alwaysOn ? "（常驻压制）"
                    : "（≥\(Int(ap.engageTemp))°C 或 ≥\(Int(ap.engagePower))W 自动接管）"))
        } catch {
            log("[helper] ⚠️ 守护状态落盘失败（仍会本次生效）：\(error)")
        }
        // 先乐观置位再 takeover —— takeover 内部会调 status()，
        // 否则返回体里 armed 还是 false，App 状态条会先闪一下"未开启"。
        // engageNow=false：守护是"被动待命"，凉时不预占 manual（否则会孤儿式锁死当前转速）。
        armed = true
        armedProfile = profile.rawValue
        let st = takeover(profile: profile, alwaysOn: alwaysOn, custom: custom, engageNow: false)
        if !st.ok {
            armed = false; armedProfile = nil
            armStore.clear()   // 没接管成功就别假装守护着
        }
        return st
    }

    /// 关闭自动守护：清掉落盘状态并交还系统
    @discardableResult
    public func disarm() -> HelperStatus {
        armStore.clear()
        armed = false
        armedProfile = nil
        log("[helper] 🛡 自动守护已关闭")
        return releaseToAuto()
    }

    /// 启动时调用：如果上次开着守护，就**自动恢复**它。
    /// （崩溃被 launchd 拉起后也走这条路径 → 守护自己回来，不会一崩就撒手不管。）
    public func restoreAutoGuardIfNeeded() {
        guard let st = armStore.load() else { return }
        let kind = ThermalProfileKind(rawValue: st.profile) ?? .cool
        log("[helper] 🛡 检测到已开启的自动守护（\(st.profile)）→ 自动恢复")
        let r = arm(profile: kind, custom: st.custom, alwaysOn: st.alwaysOn)
        if !r.ok { log("[helper] ⚠️ 自动守护恢复失败：\(r.message ?? "-")") }
    }

    @discardableResult
    public func releaseToAuto() -> HelperStatus {
        stopControlLoop()
        let ok = (try? actuator.releaseToAuto(target: 0)) ?? false
        controlling = false
        armed = false
        armedProfile = nil
        activeTargetTemp = nil
        activeTargetTempHeavy = nil
        currentProfile = .auto
        lastReason = ok ? "已交还系统" : "交还失败（请检查 Ftst / 模式）"
        log("[helper] \(ok ? "✅ 已交还系统" : "❌ 交还失败")")
        var st = status()
        st.ok = ok
        st.message = lastReason
        return st
    }

    // MARK: - 控制环

    private func startControlLoop(run: ControlRunner) {
        // 关键事件（接管/接管失败/交还）写进 helper 日志 —— 2026-09-17 排查
        // "激发没发生"时发现这些事件此前静默丢弃，完全不可诊断。
        run.onEvent = { [weak self] msg in self?.log("[helper] ⚡️ \(msg)") }
        let t = Thread { [weak self] in
            guard let self else { return }
            // 常驻控制：默认时长设得很大，直到被 stopControlLoop 打断
            do {
                _ = try run.run(duration: 60 * 60 * 24, verbose: false) { [weak self] d in
                    guard let self else { return }
                    self.controlling = d.action.isControlling
                    self.lastReason = d.action.reason
                }
            } catch {
                self.log("[helper] ⚠️ 控制环异常退出：\(error)")
                _ = try? self.actuator.releaseToAuto(target: 0)   // 出错必须交还
            }
            self.controlling = false
        }
        t.name = "fanpilot.control"
        t.qualityOfService = .userInitiated
        controlThread = t
        t.start()
    }

    private func stopControlLoop() {
        runner?.requestStop()
        controlThread = nil
        runner = nil
        engine = nil
    }

    public func shutdown() {
        stopControlLoop()
        _ = try? actuator.releaseToAuto(target: 0)
        log("[helper] 退出：已交还系统")
    }
}
