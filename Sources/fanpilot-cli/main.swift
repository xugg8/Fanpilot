import Foundation
import FanPilotCore
import ControlEngine
import SafetyGuard
import Dispatch
signal(SIGPIPE, SIG_IGN)   // 客户端写 socket 时对端消失也不许杀进程

// fanpilot CLI —— P1 原型
//
// 用法:
//   fanpilot keys [前缀]          枚举 SMC 键
//   fanpilot sensors              读温度（分族稳健聚合）
//   fanpilot fans                 读风扇（转速/目标/上下限/模式）
//   fanpilot power                读功率 (PDTR / PHPS)
//   fanpilot set <rpm> --force    设置目标转速（需 root；带写后回读校验）
//   fanpilot auto                 恢复系统自动控制
//   fanpilot watch [秒]           连续监视
//   fanpilot arm [档位]           开启「自动守护」（凉时被动，热了自动接管；崩溃重启自动恢复）
//   fanpilot disarm               关闭自动守护并交还系统
//   fanpilot stability [n]        量化 hotspot 抖动（排查"温度乱跳"）

func fmt(_ v: Double?, _ unit: String = "", digits: Int = 1) -> String {
    guard let v else { return "  n/a " }
    return String(format: "%.\(digits)f\(unit)", v)
}

func modeMeaning(_ m: Double) -> String {
    switch Int(m.rounded()) {
    case 0: return "auto（系统管理）"
    case 1: return "manual（本软件接管中）"
    case 3: return "system（固件缓解态，需 Ftst 解锁）"
    default: return "未知模式"
    }
}

func openSMC() -> SMCConnection {
    do { return try SMCConnection() }
    catch {
        FileHandle.standardError.write("无法连接 AppleSMC: \(error)\n".data(using: .utf8)!)
        exit(2)
    }
}

func cmdKeys(_ args: [String]) {
    let smc = openSMC()
    let prefix = args.first ?? ""
    let keys = smc.allKeys()
    print("键总数: \(keys.count)")
    let filtered = prefix.isEmpty ? keys : keys.filter { $0.hasPrefix(prefix) }
    print("匹配 '\(prefix)': \(filtered.count)")
    for k in filtered.prefix(200) {
        if let (size, type) = try? smc.keyInfo(k), let v = try? smc.read(k) {
            print(String(format: "  %@  %@  size=%d  value=%@", k, type.rawValue, size, fmt(v, "", digits: 2)))
        }
    }
}

/// `fanpilot stability [n]` —— 采样 n 次，量化 hotspot 抖动。
/// 修「菜单栏温度乱跳」时用的就是这个：打印每族的即时值与保持后的 hotspot，最后给极差。
func cmdStability(_ n: Int) {
    let smc = openSMC()
    do {
        let hub = try SMCSensorHub(smc: smc)
        var raws: [Double] = [], helds: [Double] = []
        print("== hotspot 稳定性（\(n) 次，间隔 1.5s）==")
        print("   #    cpu    gpu    mem    vrm | 即时  保持  来源")
        for i in 1...max(1, n) {
            let s = hub.snapshot()
            if let r = s.hotspotRaw { raws.append(r) }
            if let h = s.hotspot { helds.append(h) }
            let f = { (v: Double?) in v.map { String(format: "%6.1f", $0) } ?? "     -" }
            let fam = s.hotspotRaw == s.cpuHot ? "cpu" : (s.hotspotRaw == s.memHot ? "mem"
                    : (s.hotspotRaw == s.gpuHot ? "gpu" : (s.hotspotRaw == s.vrmHot ? "vrm" : "-")))
            print(String(format: "  %3d %@ %@ %@ %@ | %@ %@  %@",
                         i, f(s.cpuHot), f(s.gpuHot), f(s.memHot), f(s.vrmHot),
                         f(s.hotspotRaw), f(s.hotspot), fam))
            if i < n { Thread.sleep(forTimeInterval: 1.5) }
        }
        func jitter(_ a: [Double]) -> String {
            guard let lo = a.min(), let hi = a.max() else { return "-" }
            return String(format: "%.1f–%.1f°C（极差 %.1f）", lo, hi, hi - lo)
        }
        print("\n  即时 hotspot 极差 : \(jitter(raws))")
        print("  保持 hotspot 极差 : \(jitter(helds))  ← 对外汇报值")
        print("  判据：保持值极差应明显小于即时值极差，且不掩盖真实降温")
    } catch {
        print("错误：\(error)")
    }
}

/// `fanpilot arm [档位] [--always-on]` —— 开启自动守护（状态落盘，崩溃/重启自动恢复）
func cmdArm(_ args: [String]) {
    let profile = args.first(where: { !$0.hasPrefix("--") }) ?? "cool"
    let alwaysOn = args.contains("--always-on")
    let c = HelperClient()
    guard c.isHelperInstalled else { print("特权组件未安装：sudo \"\(Bundle.main.bundlePath)/../../Tools/install-helper.sh\""); exit(1) }
    // `fanpilot arm custom` → 用「曲线」页保存过的自定义档位（profiles.json 里第一个）
    var custom: CustomProfileData?
    if profile == "custom" {
        guard let cp = ProfileStore.shared.profiles.first else {
            print("❌ 还没有保存过自定义档位：请先在 App 的「曲线」页填好并点「保存」"); exit(1)
        }
        let issues = cp.validate()
        guard issues.isEmpty else {
            print("❌ 自定义档位参数非法：" + issues.joined(separator: "；")); exit(1)
        }
        custom = cp
        print("使用自定义档位：「\(cp.name)」目标 \(Int(cp.targetTemp))°C / 重载 \(Int(cp.targetTempHeavy))°C")
    }
    guard let st = c.arm(profile: profile, alwaysOn: alwaysOn, custom: custom) else {
        print("❌ 开启失败：\(HelperClient.lastFailure)"); exit(1)
    }
    print("🛡 自动守护：\(st.ok ? "已开启" : "失败")  档位=\(st.profile ?? profile)  \(st.message ?? "")")
    if st.ok {
        print("   行为：温度 <85°C 且功率 <55W 时完全被动（不碰风扇）；超过任一门限自动接管。")
        print("   现在可以关掉 App / 关掉终端 —— 守护在 helper 里，崩溃重启也会自动恢复。")
    }
}

/// `fanpilot disarm` —— 关闭自动守护并交还系统
func cmdDisarm() {
    let c = HelperClient()
    guard let st = c.disarm() else { print("❌ 关闭失败：\(HelperClient.lastFailure)"); exit(1) }
    print("🛡 自动守护已关闭，已交还系统：\(st.ok ? "✅" : "⚠️")  \(st.message ?? "")")
}

func cmdSensors() {
    let smc = openSMC()
    do {
        let reg = try SensorRegistry(smc: smc)
        reg.poll()
        print("== 分族稳健聚合（剔除无效键 \(SensorRegistry.knownBogusOnReferenceModel.count) 个）==")
        for fam in SensorFamily.allCases {
            guard let r = SensorAggregator.aggregate(reg, family: fam) else { continue }
            print(String(format: "  %-16@ 中位 %6@°C   p90 %6@°C   样本 %3d(采用 %3d)  单轮极差 %5@",
                         fam.rawValue, fmt(r.median), fmt(r.quantile), r.sampleCount, r.usedCount, fmt(r.spread)))
        }
        print("\n★ 注意：Tp* 单轮极差可达 30°C+（SMC 多路复用），控制逻辑必须用 p90/中位数，禁止单键取值")
    } catch { print("错误: \(error)") }
}

func cmdFans() {
    let smc = openSMC()
    do {
        let act = try FanActuator(smc: smc)
        print("风扇数: \(act.fans.count)")
        for f in act.fans {
            let state = f.isStopped ? "停转（低温时正常）" : String(format: "%.0f RPM (%.0f%%)", f.actualRPM, f.percent)
            print("  F\(f.index): 实际 \(state)")
            print("      目标 \(fmt(f.targetRPM))  范围 \(fmt(f.minRPM))–\(fmt(f.maxRPM))")
            print("      模式键 \(f.modeKey) = \(fmt(f.mode, "", digits: 0))  \(modeMeaning(f.mode))")
        }
        if let st = HelperClient().status() {
            let guardText = st.armed ? "🛡 已开启（档位 \(st.armedProfile ?? "-")）" : "未开启"
            print("\n  自动守护: \(guardText)   helper pid \(st.helperPID.map { String($0) } ?? "-")")
            if st.armed && !st.controlling { print("            （当前被动等待：温度 <85°C 且功率 <55W）") }
        }
        print("\n  Ftst 键: \(act.ftstAvailable ? "存在（可用作全局解锁闸门）" : "不存在")")
        print("  模式语义: 0=auto  1=manual(手动)  3=system(AppleCLPC 缓解态，固件拒绝手动写入)")
    } catch { print("错误: \(error)") }
}

func cmdPower() {
    let smc = openSMC()
    for k in ["PDTR", "PHPS", "PDBR", "P5SR", "VD0R", "ID0R"] {
        if let v = try? smc.read(k) { print(String(format: "  %@ = %@", k, fmt(v, "", digits: 1))) }
    }
    print("\n★ PDTR = 系统直流功率（W）。实测：闲置 25–27 / 10核CPU满载 88 / GPU满载 136")
    print("  负载出现后 2 秒内响应，比温度早 10–14 秒 —— 前馈控制的主输入")
}

func cmdSet(_ args: [String]) {
    guard let rpmStr = args.first, let rpm = Double(rpmStr) else {
        print("用法: fanpilot set <rpm> --force"); exit(2)
    }
    guard args.contains("--force") else {
        print("拒绝执行：需要显式 --force（写入风扇属于接管系统热管理，必须明示）"); exit(3)
    }
    let smc = openSMC()
    do {
        let act = try FanActuator(smc: smc)
        print("== 解锁（两阶段：直写 → Ftst 回退）==")
        guard try act.unlockManual() else {
            for l in act.unlockLog { print("   " + l) }
            print("⚠️ 解锁失败：\(act.lastError ?? "未知原因")")
            print("   若提示 kIOReturnNotPrivileged → 未以 root 运行；")
            print("   若 Mode 3 解锁超时 → 检查 Ftst 是否被其他风扇工具占用。")
            exit(4)
        }
        for l in act.unlockLog { print("   " + l) }
        var allOK = true
        for f in act.fans {
            let clamped = act.clamp(rpm, fanIndex: f.index)
            let ok = try act.setTarget(rpm, fanIndex: f.index)
            print(String(format: "  F%d 目标设为 %.0f RPM（限幅后 %.0f）→ %@", f.index, rpm, clamped, ok ? "已确认" : "未确认"))
            allOK = allOK && ok
        }
        print(allOK ? "✅ 写入并经回读校验通过" : "❌ 部分写入未通过校验")
        if args.contains("--hold") {
            print("")
            print("⚠️ --hold：风扇**保持手动模式**。本进程退出后没有任何东西替它收尾")
            print("   （实测：系统在 12 秒内**不会**自动 reclaim）——收尾务必执行：")
            print("   sudo fanpilot auto")
        } else {
            Thread.sleep(forTimeInterval: 2)
            let released = try act.releaseToAuto(target: 0)
            print("")
            print(released
                  ? "✅ 已自动恢复系统控制（默认安全行为；需要保持手动请加 --hold）"
                  : "⚠️ 恢复未完成：\(act.lastError ?? "") —— 请手动执行 sudo fanpilot auto")
        }
    } catch { print("错误: \(error)"); exit(5) }
}

func cmdUnlock() {
    let smc = openSMC()
    do {
        let act = try FanActuator(smc: smc)
        print("== 解锁流程诊断 ==")
        print("   Ftst 键存在: \(act.ftstAvailable)")
        let t0 = Date()
        let ok = try act.unlockManual()
        let dt = Date().timeIntervalSince(t0)
        for l in act.unlockLog { print("   " + l) }
        print(String(format: "   耗时 %.1fs → %@", dt, ok ? "解锁成功" : "失败"))
        for f in act.fans {
            print("   F\(f.index) 模式=\(fmt(f.mode, "", digits: 0)) \(modeMeaning(f.mode)) 目标=\(fmt(f.targetRPM)) 实际=\(fmt(f.actualRPM))")
        }
        if ok {
            print("\n   注意：reclaim 有延迟但确实存在；维持手动必须周期重断言 + 常驻。")
            print("   结束请务必执行： sudo fanpilot auto")
            exit(0)
        }
        exit(5)
    } catch { print("错误: \(error)"); exit(7) }
}

/// 解析 --profile <name>
func parseProfile(_ args: [String]) -> ThermalProfile {
    var kind = ThermalProfileKind.cool
    if let i = args.firstIndex(of: "--profile"), i + 1 < args.count {
        kind = ThermalProfileKind(rawValue: args[i + 1]) ?? .cool
    }
    var p = ThermalProfile.profile(kind)
    // 可选：高温完全交还系统（默认关闭，见 ActivationPolicy 注释）
    if let i = args.firstIndex(of: "--handback-temp"), i + 1 < args.count,
       let v = Double(args[i + 1]) { p.activation.handbackTemp = v }
    // 可选：常驻接管（关闭激发门限，用于调试/长时间烤机）
    if args.contains("--always-on") { p.activation = .alwaysOn }
    // 可选：固定档指定转速
    if let i = args.firstIndex(of: "--rpm"), i + 1 < args.count, let v = Double(args[i + 1]) {
        p.fixedRPM = v
    }
    return p
}

func fmtRPM(_ v: Double) -> String { String(format: "%5.0f", v) }

/// 纯模拟：**不读也不写 SMC**，只把策略算出来给人看
func cmdPlan(_ args: [String]) {
    let profile = parseProfile(args)
    let hwMin = 1350.0, hwMax = 5777.0
    print("策略档位: \(profile.name)   目标温度 \(String(format: "%.0f", profile.targetTemp))°C")
    print("地板 \(profile.idleFloorRPM.map { String(format: "%.0f", $0) } ?? "硬件下限 1350") RPM  "
          + "｜Kp \(profile.kp) Ki \(profile.ki) 修正 +\(String(format: "%.0f", profile.trimLimit))/-\u{200B}\(String(format: "%.0f", profile.trimLimitNegative))  "
          + "｜升速 \(String(format: "%.0f", profile.slewUpRPMps)) 降速 \(String(format: "%.0f", profile.slewDownRPMps)) RPM/s")
    print()

    // ── 表 1：功率 × 温度 → 目标转速（每格独立新建引擎，代表"已稳定"状态）
    let powers: [Double] = [27, 45, 60, 75, 90, 110, 136]
    let temps: [Double] = [60, 75, 88, 95, 100, 105]
    print("【稳态目标转速 RPM】行 = 系统功率 PDTR(W)，列 = 热点温度(°C)")
    print("      " + temps.map { String(format: "%6.0f", $0) }.joined())
    for p in powers {
        var row = String(format: "%5.0f ", p)
        for t in temps {
            let eng = ControlEngine(config: .init(profile: profile))
            var snap = ThermalSnapshot(); snap.power = p; snap.cpuHot = t
            // 连续喂 30 个 tick（不推进时间 → 无突升判定），让它收敛到稳态
            var d = eng.decide(snap, hardwareMin: hwMin, hardwareMax: hwMax)
            for _ in 0..<30 {
                d = eng.decide(snap, hardwareMin: hwMin, hardwareMax: hwMax,
                               now: Date().addingTimeInterval(Double(eng.decisions.count) * 0.5))
            }
            row += String(format: "%6.0f", d.finalRPM)
        }
        print(row)
    }
    print("  （≥95°C 会被安全守护拉满到 5777；≥105°C 触发告警）")
    print()

    // ── 表 2：用真机实测时序回放，对比 Apple 自己的表现
    let scenarios: [(String, [(t: Double, power: Double, cpu: Double, gpu: Double, vrm: Double, apple: Double)])] = [
        ("CPU-only 满载（10 线程，实测 88W）", [
            (0, 27.5, 74.2, 55.4, 53.3, 1319), (2, 84.7, 96.0, 59.2, 56.0, 1355),
            (8, 86.7, 101.2, 64.9, 58.0, 1380), (14, 88.1, 106.2, 69.7, 60.0, 1340),
            (16, 89.9, 108.2, 71.0, 62.0, 1345), (24, 88.1, 112.3, 75.5, 64.0, 1702)]),
        ("GPU 满载（MPS，实测峰值 136W）", [
            (0, 25.0, 50.4, 49.6, 53.4, 1352), (5, 135.9, 58.7, 85.5, 96.5, 1343),
            (15, 135.3, 75.0, 96.0, 105.1, 1345), (20, 133.3, 85.4, 99.3, 108.7, 1485),
            (46, 124.3, 82.8, 100.0, 111.7, 2678), (70, 118.5, 84.0, 99.0, 110.0, 3235)]),
    ]
    for (title, series) in scenarios {
        print("【实测回放】\(title)")
        print("   时间   PDTR   热点   本策略   Apple实测")
        let eng = ControlEngine(config: .init(profile: profile))
        // ★ 用序列起始时刻做 seed，与 decide 的时间基准保持一致
        eng.seedFromCurrentRPM(1350, now: Date(timeIntervalSince1970: series[0].t))
        for f in series {
            var snap = ThermalSnapshot(timestamp: Date(timeIntervalSince1970: f.t))
            snap.power = f.power; snap.cpuHot = f.cpu; snap.gpuHot = f.gpu; snap.vrmHot = f.vrm
            let d = eng.decide(snap, hardwareMin: hwMin, hardwareMax: hwMax,
                               now: Date(timeIntervalSince1970: f.t))
            print(String(format: "   %4.0fs  %5.0fW  %5.0f°C  %@   %5.0f",
                         f.t, f.power, d.snapshot.hotspot ?? 0, fmtRPM(d.finalRPM), f.apple))
        }
        print()
    }
    // ── 表 3：一天的使用场景 —— 什么时候接管、什么时候交还
    print("【激发策略】日常使用场景模拟（默认：轻负载不接管）")
    let pol = profile.activation
    if !pol.enabled {
        print("   激发门限已关闭（常驻接管）")
    } else {
        print(String(format: "   激发：功率≥%.0fW 或 热点≥%.0f°C，持续 %.0fs", pol.engagePower, pol.engageTemp, pol.engageDwell))
        print(String(format: "   交还：功率<%.0fW 且 热点<%.0f°C，持续 %.0fs", pol.releasePower, pol.releaseTemp, pol.releaseDwell))
        print(String(format: "   重载目标温度：%.0f°C（功率≥%.0fW 时启用；普通负载 %.0f°C）",
                     profile.targetTempHeavy ?? profile.targetTemp, profile.heavyPowerThreshold, profile.targetTemp))
        print()
        let day: [(String, Double, Double, Double)] = [   // (场景, 时长s, 功率W, 温度°C)
            ("开机空闲（后台同步）", 60, 27, 55),
            ("日常轻工作（浏览/文档）", 120, 42, 66),
            ("编译/导出（真负载）", 120, 88, 84),
            ("负载结束回落到轻工作", 60, 42, 66),
            ("回到空闲", 120, 26, 52),
        ]
        let eng = ControlEngine(config: .init(profile: profile))
        var t = 0.0
        var lastState: Bool? = nil
        print("   时刻      场景                        功率   温度   状态")
        for (name, dur, pw, hot) in day {
            var tt = t
            while tt < t + dur {
                let d = eng.decide(ThermalSnapshot.make(power: pw, cpu: hot, t: tt),
                                   hardwareMin: hwMin, hardwareMax: hwMax,
                                   now: Date(timeIntervalSince1970: tt))
                if lastState == nil || lastState != d.action.isControlling {
                    let tag = d.action.isControlling ? "⚡️ 接管风扇" : "○ 系统自动（监控中）"
                    print(String(format: "   %5.0fs   %-24@  %4.0fW  %3.0f°C  %@",
                                 tt, name as NSString, pw, hot, tag))
                    if d.action.isControlling { print("            └ \(d.action.reason)") }
                    lastState = d.action.isControlling
                }
                tt += 0.5
            }
            t += dur
        }
    }
    print()
    print("提示：本命令**不接触硬件**。要真正接管请用： sudo fanpilot run --profile \(profile.kind.rawValue) --duration 60")
}

/// 真正接管风扇运行控制环（需要 root）
var signalSources: [DispatchSourceSignal] = []

func cmdRun(_ args: [String]) {
    let profile = parseProfile(args)
    var duration = 60.0
    var verbose = true
    if let i = args.firstIndex(of: "--duration"), i + 1 < args.count { duration = Double(args[i + 1]) ?? 60 }
    if args.contains("--quiet") { verbose = false }

    let smc = openSMC()
    do {
        let act = try FanActuator(smc: smc)
        let hub = try SMCSensorHub(smc: smc)
        guard let f0 = act.fans.first else {
            print(act.hasFans ? "❌ 未检测到可用风扇控制接口"
                              : "❌ 此机型无风扇（被动散热）—— FanPilot 仅支持温度监控")
            exit(3)
        }
        // 跨机型适配：按本机实际风扇范围缩放策略
        let engine = ControlEngine(config: .init(
            profile: profile.scaled(toFanMin: f0.minRPM, fanMax: f0.maxRPM)))
        let runner = ControlRunner(engine: engine, actuator: act, source: hub,
                                   heartbeatPath: "/tmp/fanpilot.heartbeat")
        // ★ 信号处理：Ctrl-C / SIGTERM 必须**先交还系统再退出**。
        //   若不处理，默认处置是立即终止进程 → 风扇会停留在手动模式（危险）。
        let sigQueue = DispatchQueue(label: "fanpilot.signals")
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)                       // 交给 DispatchSource 接管
            let src = DispatchSource.makeSignalSource(signal: sig, queue: sigQueue)
            src.setEventHandler {
                print("\n   ⚠️ 收到信号 \(sig)，正在交还系统控制…")
                runner.requestStop()
            }
            src.resume()
            signalSources.append(src)
        }

        print("═══ \(profile.name) 档启动 ═══  时长 \(Int(duration))s  目标温度 \(String(format: "%.0f", profile.targetTemp))°C")
        guard try runner.acquire() else {
            print("⚠️ 无法取得控制权：\(act.lastError ?? "")")
            for l in act.unlockLog { print("   " + l) }
            exit(4)
        }
        for l in act.unlockLog { print("   " + l) }
        defer {
            let ok = runner.release()
            print(ok ? "✅ 已交还系统控制" : "❌ 交还失败，请手动执行： sudo fanpilot auto")
        }
        let stats = try runner.run(duration: duration, verbose: verbose)
        print()
        print("═══ 小结 ═══")
        print("   tick \(stats.ticks)  下发成功 \(stats.writes)  失败 \(stats.writeFailures)  重断言 \(stats.reasserts)")
        print(String(format: "   目标范围 %.0f–%.0f RPM   实测最高热点 %.1f°C  目标变更 %d 次",
                     stats.minTarget.isFinite ? stats.minTarget : 0, stats.maxTarget,
                     stats.maxHotspot, stats.targetChanges))
        for e in Set(stats.safetyEvents).sorted() { print("   · \(e)") }
    } catch { print("错误: \(error)"); exit(5) }
}

func cmdMode(_ args: [String]) {
    guard let v = args.first, let mode = Double(v) else {
        print("用法: fanpilot mode <0|1>    （0=auto 系统自动，1=manual 手动接管）")
        exit(2)
    }
    let smc = openSMC()
    do {
        let act = try FanActuator(smc: smc)
        for f in act.fans {
            let type = try smc.keyType(f.modeKey)
            _ = try smc.write(f.modeKey, data: SMCCodec.encode(type: type, value: mode))
            let ok = try act.verify(key: f.modeKey, expected: mode, tolerance: 0.5)
            print("  \(f.modeKey) ← \(Int(mode))  \(ok ? "已确认" : "未确认")")
        }
        try act.refresh()
        for f in act.fans { print("  F\(f.index) 现为 \(fmt(f.mode, "", digits: 0)) \(modeMeaning(f.mode))") }
    } catch { print("错误: \(error)") }
}

func cmdAuto() {
    let smc = openSMC()
    do {
        let act = try FanActuator(smc: smc)
        let ok = try act.releaseToAuto(target: 0)      // 显式写 0 = 系统自动
        for f in act.fans {
            print("  F\(f.index): 模式 \(fmt(f.mode, "", digits: 0))  目标 \(fmt(f.targetRPM))  实际 \(fmt(f.actualRPM))")
        }
        if ok {
            print("✅ 已恢复系统自动控制（mode=0）")
            exit(0)
        }
        print("❌ 恢复失败：\(act.lastError ?? "未知原因") —— 风扇可能仍处手动")
        exit(6)
    } catch {
        // 非 root 时内核拒绝写入 → 必须如实报错，绝不谎报"已恢复"
        print("错误: \(error)")
        print("   风扇并未被交还系统（写入被拒）。请以 root 执行： sudo fanpilot auto")
        exit(7)
    }
}

/// 机型自检报告 —— 给 GitHub issue 用的"环境信息一键导出"
func cmdDoctor() {
    let smc = openSMC()
    print("═══ FanPilot 机型自检 ═══")
    print("macOS   : \(ProcessInfo.processInfo.operatingSystemVersionString)")
    let out = ProcessInfo.processInfo.environment["FANPILOT_MODEL"] ?? ""
    _ = out
    if let r = try? runCmd("/usr/sbin/sysctl", ["-n", "hw.model"]).trimmed { print("机型    : \(r)") }
    if let r = try? runCmd("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).trimmed { print("芯片    : \(r)") }
    if let r = try? runCmd("/usr/bin/uname", ["-m"]).trimmed { print("架构    : \(r)") }

    print("\n── 风扇接口 ──")
    do {
        let act = try FanActuator(smc: smc)
        print("FNum    : \(act.fans.count) 台\(act.hasFans ? "" : "  ⚠️ 无风扇机型（Air 类），仅支持监控")")
        for f in act.fans {
            print(String(format: "  F%d      : %@–%@ RPM  模式键 %@  当前 %@ RPM / 目标 %@",
                         f.index, fmt(f.minRPM), fmt(f.maxRPM), f.modeKey,
                         fmt(f.actualRPM), fmt(f.targetRPM)))
        }
        print("Ftst    : \(act.ftstAvailable ? "存在（M4 Max MacBook 类需要它解锁）" : "不存在（M1/M5/Mac mini 类通常直写即可）")")
        // 大小写探测结果
        let hasUpper = smc.keyExists("F0Md"), hasLower = smc.keyExists("F0md")
        print("模式键  : 大写 F0Md=\(hasUpper)  小写 F0md=\(hasLower)")
        print("\n── 转速策略缩放对照（以本机范围为准）──")
        if let f0 = act.fans.first {
            let scaled = ThermalProfile.profile(.cool).scaled(toFanMin: f0.minRPM, fanMax: f0.maxRPM)
            let anchors = scaled.feedForward.map { String(format: "%.0fW→%.0f", $0.watts, $0.rpm) }
            print("  \(anchors.joined(separator: "  "))")
        }
    } catch { print("  ❌ 风扇接口读取失败：\(error)") }

    print("\n── 温度传感器 ──")
    do {
        let reg = try SensorRegistry(smc: smc)
        reg.poll()
        var byFamily: [String: Int] = [:]
        for rec in reg.records.values {
            let fam = String(rec.key.prefix(3))
            byFamily[fam, default: 0] += 1
        }
        print("  有效键  : \(reg.records.count) 个")
        for (fam, n) in byFamily.sorted(by: { $0.value > $1.value }).prefix(12) {
            print("    \(fam): \(n)")
        }
        for fam in SensorFamily.allCases {
            if let r = SensorAggregator.aggregate(reg, family: fam) {
                print(String(format: "  %-8@: p90 %@°C  样本 %d（剔除 %d）",
                             fam.rawValue, fmt(r.quantile), r.sampleCount, r.sampleCount - r.usedCount))
            }
        }
        // ★ 响应性测试：区分"真热点"与"恒定假读数"的唯一可靠办法
        //   （仅凭偏离中位数不行 —— 真实热点核本来就偏高 20–30°C）
        print("\n── 加载脉冲响应性测试（4 秒，轻微）──")
        var baseline: [String: Double] = [:]
        for (k, rec) in reg.records { baseline[k] = rec.lastValue }
        let procs = (0..<4).map { _ -> Process in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "while :; do :; done"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); return p
        }
        Thread.sleep(forTimeInterval: 4)
        procs.forEach { $0.terminate() }
        reg.poll()
        var moved: [(String, Double)] = [], frozen: [String] = []
        for (k, rec) in reg.records {
            guard let b = baseline[k], let now = rec.lastValue else { continue }
            if abs(now - b) >= 1.5 { moved.append((k, now - b)) } else { frozen.append(k) }
        }
        moved.sort { abs($0.1) > abs($1.1) }
        print("  有响应（真传感器）: \(moved.count) 个，升高最多的：")
        for (k, d) in moved.prefix(10) { print(String(format: "    %@  %+.1f°C", k, d)) }
        let frozenHigh = frozen.filter { (reg.records[$0]?.lastValue ?? 0) > 80 }
        if !frozenHigh.isEmpty {
            print("  ⚠️ **恒定且数值偏高**（很可能是无效读数，建议加入排除表并提交 issue）：")
            print("     \(frozenHigh.sorted().joined(separator: " "))")
        } else {
            print("  ✅ 未发现「恒定且偏高」的可疑键")
        }
        print("  （本机参考：Tf06/16/26/36/46 恒定在 97–116°C，属无效读数）")
    } catch { print("  ❌ 传感器扫描失败：\(error)") }

    print("\n── 特权组件 ──")
    let client = HelperClient()
    print("  \(client.diagnose())")

    print("\n── 功率键 ──")
    for k in ["PDTR", "PHPS", "PDBR"] {
        if let v = (try? smc.read(k)) ?? nil { print(String(format: "  %@ = %.1f", k, v)) }
        else { print("  \(k) = 不存在（该机型前馈将退化为纯温度反馈）") }
    }
    print("\n（把以上内容整段贴进 GitHub issue 即可）")
}

struct CmdResult { let out: String; var trimmed: String { out.trimmingCharacters(in: .whitespacesAndNewlines) } }
func runCmd(_ path: String, _ args: [String]) throws -> CmdResult {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe
    try p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return CmdResult(out: String(data: d, encoding: .utf8) ?? "")
}

func cmdWatch(_ args: [String]) {
    let seconds = Double(args.first ?? "30") ?? 30
    let smc = openSMC()
    guard let reg = try? SensorRegistry(smc: smc) else { print("注册表失败"); exit(2) }
    print("时间       CPU(p90)  GPU(p90)  MEM(p90)  VRM(p90)   Tp极差   PDTR   风扇")
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds {
        reg.poll()
        let cpu = SensorAggregator.aggregate(reg, family: .cpu)
        let gpu = SensorAggregator.aggregate(reg, family: .gpu)
        let mem = SensorAggregator.aggregate(reg, family: .memory)
        let vrm = SensorAggregator.aggregate(reg, family: .vrm)
        let pdt = try? smc.read("PDTR")
        let fan = try? smc.read("F0Ac")
        print(String(format: "%@  %8@  %8@  %8@  %8@  %6@  %5@  %5@",
                     DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium),
                     fmt(cpu?.quantile), fmt(gpu?.quantile), fmt(mem?.quantile), fmt(vrm?.quantile),
                     fmt(cpu?.spread), fmt(pdt ?? nil, "", digits: 0), fmt(fan ?? nil, "", digits: 0)))
        Thread.sleep(forTimeInterval: 2)
    }
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else {
    print("""
    fanpilot —— M4 Max 风扇控制 CLI（P1 原型）

      fanpilot keys [前缀]        枚举 SMC 键
      fanpilot sensors            温度（分族稳健聚合）
      fanpilot fans               风扇状态（含模式语义与 Ftst）
      fanpilot unlock             解锁流程诊断（两阶段 + Ftst 闸门）
      fanpilot power              功率
      fanpilot set <rpm> --force  设置转速（需 root；带回读校验）
      fanpilot auto               恢复系统自动控制（写 mode=0）
      fanpilot mode <0|1>         直接写模式（诊断用）
      fanpilot watch [秒]         连续监视
      fanpilot doctor             机型自检（跨机型排障 / 提交 issue 用）
      fanpilot plan               策略模拟（不接触硬件，先看再跑）
      fanpilot run --profile P    接管控制（需 root，默认 cool 档）
                                  可选： --always-on（常驻接管） --handback-temp 102（高温交还系统）
    """)
    exit(0)
}

switch cmd {
case "keys":    cmdKeys(Array(argv.dropFirst()))
case "sensors": cmdSensors()
case "fans":    cmdFans()
case "unlock":  cmdUnlock()
case "mode":    cmdMode(Array(argv.dropFirst()))
case "plan":    cmdPlan(Array(argv.dropFirst()))
case "run":     cmdRun(Array(argv.dropFirst()))
case "power":   cmdPower()
case "set":     cmdSet(Array(argv.dropFirst()))
case "auto":    cmdAuto()
case "watch":   cmdWatch(Array(argv.dropFirst()))
case "doctor":  cmdDoctor()
case "stability": cmdStability(Int(CommandLine.arguments.dropFirst().first ?? "12") ?? 12)
case "arm":     cmdArm(Array(argv.dropFirst()))
case "disarm":  cmdDisarm()
default:        print("未知命令: \(cmd)"); exit(2)
}
