import Foundation
import AppKit
import SwiftUI
import Charts
import Combine
import UserNotifications
import FanPilotCore
import ControlEngine
signal(SIGPIPE, SIG_IGN)   // 客户端写 socket 时对端消失也不许杀进程

// ─────────────────────────────────────────────────────────────────────
// FanPilot 菜单栏 App
//
//   监控页：各族温度、功率、风扇/模式/Ftst、真实接管状态、快捷接管与交还
//   曲线页：目标温度 / 前馈抢跑 / 修正增益 / 自定义曲线编辑，校验后下发
//   底栏：  退出 App 时是否交还系统（默认交还，更安全）
// ─────────────────────────────────────────────────────────────────────

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var status: HelperStatus?
    @Published var helperDiagnosis: String = "检查中…"
    @Published var titleText: String = "FanPilot"
    @Published var isControlling: Bool = false
    /// 当前真正生效的档位+目标温度。
    /// 数据优先取 helper 回传的**真值**；旧版 helper 不报这两个字段时按档位本地兜底
    /// （宁可显示预设值，也不要让用户对着"88"猜自己在跑 85）。
    var effectiveTargetText: String {
        let name = status?.profile ?? "—"
        let key = status?.armedProfile ?? guardProfile
        var t = status?.targetTemp
        var heavy = status?.targetTempHeavy
        if t == nil {
            switch key {
            case "cool": t = 88; heavy = 95
            case "maxCool": t = 82; heavy = 90
            case "custom":
                if let c = store.profiles.first { t = c.targetTemp; heavy = c.targetTempHeavy }
            default: break
            }
        }
        guard let t else { return "生效：\(name)" }
        let h = heavy.map { String(format: " / 重载 %.0f°C", $0) } ?? ""
        let src = status?.targetTemp != nil ? "" : "（旧版组件，按档位推算）"
        return String(format: "生效：%@ %.0f°C%@%@", name, t, h, src)
    }

    /// helper 是否支持「自动守护」（旧版 helper 没有 arm 命令，点了也没用）
    var helperSupportsGuard: Bool {
        HelperFeatures.supports(HelperFeatures.guardSupport, in: status?.features)
    }
    /// helper 在线但版本过旧（能报状态，却没有新功能）—— 需要提示重装
    var helperIsOutdated: Bool {
        helperDiagnosis.hasPrefix("正常") && !helperSupportsGuard
    }
    /// 本次接管的开始时刻（用于显示"已接管时长"）
    @Published var controllingSince: Date?

    /// 菜单栏图标上显示的温度（热点）+ 接管状态
    @Published var iconTemp: Double?
    /// 菜单栏图标温度下方显示的实时整机功率（W），来自 helper status.power
    @Published var iconPower: Double?
    /// 图标温度（hotspot）当前来自哪个传感器族，如 "CPU"/"GPU"/"内存"/"供电 VRM"。
    /// hotspot 是四族聚合值的 max（自适应跟随真热点），标注来源是为了可解释性。
    @Published var hotspotSourceName: String?
    @Published var editing: CustomProfileData
    @Published var issues: [String] = []
    @Published var lastActionMessage: String = ""
    /// 系统负载（CPU/内存 Top3、GPU 利用率、热告警）—— 本地采集，不经过 helper
    @Published var stats: SystemStats = .empty
    /// 本次运行期间的温度峰值（用于判断"这轮到底有多热"）
    @Published var sessionPeak: Double?
    @Published var sessionPeakAt: Date?
    /// 温度实时曲线（曲线页底部）：每 2s 一个样本，保留最近 15 分钟
    @Published var tempHistory: [TempSample] = []
    /// 菜单栏 popover 是否已展开为完整面板（false = 迷你模式：只显示实时曲线）
    @Published var popoverExpanded = false

    struct TempSample: Identifiable {
        let t: Date
        let temp: Double          // hotspot（四族 max + 8s 峰值保持），用于配色/告警
        var cpu: Double? = nil    // 四族分量：nil = 该族本轮无有效读数
        var gpu: Double? = nil
        var mem: Double? = nil
        var vrm: Double? = nil
        let id = UUID()
    }
    /// 当前生效的高温警示级别（nil = 正常）
    @Published var alertLevel: TempAlertPolicy.Level?
    /// 通知授权状态的人类可读描述（面板里显示，便于排查"为什么不弹通知"）
    @Published var notificationStatus: String = "未询问"
    @Published var launchAtLoginEnabled: Bool = LaunchAtLogin.isEnabled
    /// 自动守护是否开启（真值来自 helper，不是本地偏好 —— 偏好只是"我想要"）
    @Published var guardArmed: Bool = false
    @Published var guardProfile: String = "custom"
    /// 上一次见到的 helper pid，用来发现"helper 崩溃后被拉起"
    private var lastHelperPID: Int32?
    private var helperRestarts = 0
    /// 本次会话是否已同步过守护偏好（避免每 2 秒重复下发）
    private var didSyncGuard = false
    /// helper 上次是否在线 —— 由"离线→在线"那一刻触发重新同步守护
    /// （用户装好 helper 之后不用重启 App，守护会自己接上）
    private var helperWasOnline = false

    let store = ProfileStore.shared
    private let client = HelperClient()
    private var timer: Timer?
    private var localMonitor: LocalMonitor?
    private var localMonitorFailed = false
    /// 后台队列：SMC/helper 的阻塞式读取都在这里做，**不阻塞主线程**
    /// （实测教训：在 applicationDidFinishLaunching / 主线程定时器里做阻塞 I/O，
    ///   会让状态栏项一直停在"未布局"位置 x=0,y<0 —— 即看不见）
    private let ioQueue = DispatchQueue(label: "fanpilot.io", qos: .utility)
    private var ioInFlight = false

    // ── P4：高温通知 + 会话 CSV ──
    private var alertPolicy = TempAlertPolicy.default
    private lazy var sessionLog = SessionLog(directory: SessionLog.defaultDirectory(),
                                            minInterval: store.prefs.logInterval,
                                            enabled: store.prefs.logToCSV)
    /// 上一次的接管状态，用来在 CSV 里写"接管/交还"事件行
    private var lastControllingLogged: Bool?

    private init() {
        editing = ProfileStore.shared.profiles.first ?? CustomProfileData()
        // 2026-09-16 档位精简：守护固定跑自定义档（预设只剩代码里的兜底定义，UI 已撤）。
        // 旧偏好迁移：防止冷启动按旧的 cool 偏好把守护开回预设档。
        if ProfileStore.shared.prefs.guardProfile != "custom" {
            ProfileStore.shared.prefs.guardProfile = "custom"
            ProfileStore.shared.save()
            appLog("守护档位偏好迁移：→ custom（档位选择器已移除，固定自定义）")
        }
    }

    func start() {
        requestNotificationPermission()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// 由定时器调用：把阻塞读取丢到后台，主线程立即返回
    func refresh() {
        guard !ioInFlight else { return }
        ioInFlight = true
        ioQueue.async { [weak self] in
            guard let self else { return }
            let diag = self.client.diagnose()
            var st = self.client.status()
            var failed = false
            if st == nil {
                if self.localMonitor == nil, !self.localMonitorFailed {
                    do { self.localMonitor = try LocalMonitor() }
                    catch { self.localMonitorFailed = true; failed = true }
                }
                st = self.localMonitor?.status()
            }
            let stats = SystemStats.sample()
            DispatchQueue.main.async {
                self.stats = stats
                self.helperDiagnosis = diag
                self.localMonitorFailed = self.localMonitorFailed || failed
                self.apply(st)
                self.ioInFlight = false
            }
        }
    }

    /// 主线程：只做 UI 更新
    private func apply(_ st: HelperStatus?) {
        status = st                              // ★ 必须赋值：面板所有字段都读它
        let wasControlling = isControlling
        isControlling = st?.controlling ?? false
        if isControlling && !wasControlling { controllingSince = Date() }
        if !isControlling { controllingSince = nil }

        // 温度：测试钩子优先（用于验证配色而不必把机器烧热）
        if let fake = ProcessInfo.processInfo.environment["FANPILOT_FAKE_TEMP"], let v = Double(fake) {
            iconTemp = v
            iconPower = 45                   // 测试钩子给个假功率，保证菜单栏布局可验证
            hotspotSourceName = nil          // 测试钩子没有真实来源族
        } else if let st {
            iconTemp = st.hotspot
            iconPower = st.power
            // 热点来源族：与 ThermalSnapshot.hotspotFamily 相同的 max 判据，App 端本地计算
            //（HelperStatus 本就携带四族聚合值，无需改协议/重装 helper）
            let pairs: [(String, Double?)] = [("CPU", st.cpuHot), ("GPU", st.gpuHot),
                                              ("内存", st.memHot), ("供电 VRM", st.vrmHot)]
            hotspotSourceName = pairs.compactMap { k, v in v.map { (k, $0) } }
                .max { $0.1 < $1.1 }?.0
        } else {
            iconTemp = nil
            iconPower = nil
            hotspotSourceName = nil
        }
        // helper 重启检测：崩溃被 launchd 拉起时 pid 会变。
        // 这是"风扇转一分钟就停"那类事故的第一现场证据，必须留痕并提醒用户。
        if let pid = st?.helperPID {
            if let last = lastHelperPID, last != pid {
                helperRestarts += 1
                let msg = "⚠️ 特权组件重启（pid \(last) → \(pid)，第 \(helperRestarts) 次）—— 控制会被短暂中断"
                appLog(msg)
                sessionLog.event("HELPER_RESTART \(last)->\(pid) count=\(helperRestarts)")
                if store.prefs.notifyOnHighTemp { notify(title: "FanPilot 特权组件重启", body: msg) }
            }
            lastHelperPID = pid
        }
        if let a = st?.armed, a != guardArmed { guardArmed = a }
        if let ap = st?.armedProfile {
            if guardProfile != ap { appLog("守护档位同步：\(guardProfile) → \(ap)") }
            guardProfile = ap
            // 偏好也一起对齐：否则守护状态文件被清掉后（卸载重装），
            // 冷启动会按旧偏好把守护开回 cool，把用户选的自定义档位顶掉。
            if store.prefs.guardProfile != ap {
                store.prefs.guardProfile = ap
                store.save()
            }
        }

        syncAutoGuard()
        feedAlertsAndLog()
        if let h = iconTemp, sessionPeak == nil || h > (sessionPeak ?? 0) {
            sessionPeak = h; sessionPeakAt = Date()
        }

        // 温度历史采样（曲线页实时图）：有读数才记，2s × 450 ≈ 15 分钟窗口
        if let h = iconTemp {
            // 四族分量来自 helper status；测试钩子模式下四族都取假值，保证图表仍可渲染
            let fake = ProcessInfo.processInfo.environment["FANPILOT_FAKE_TEMP"] != nil
            tempHistory.append(TempSample(t: Date(), temp: h,
                cpu: fake ? h : st?.cpuHot, gpu: fake ? h : st?.gpuHot,
                mem: fake ? h : st?.memHot, vrm: fake ? h : st?.vrmHot))
            if tempHistory.count > 450 { tempHistory.removeFirst(tempHistory.count - 450) }
        }

        if let st, let h = st.hotspot {
            let rpm = st.fanRPM.first.map { Int($0) } ?? 0
            titleText = st.hasFans ? (isControlling ? "⚡️\(Int(h))° \(rpm)" : "\(Int(h))° \(rpm)")
                                   : "\(Int(h))°"
        } else {
            titleText = localMonitorFailed ? "FanPilot ✖︎" : "FanPilot …"
        }
        logTitle()
    }

    private func logTitle() {
        let st = stats
        let cpuTop = st.topCPU.map { "\($0.name):\(Int($0.cpu))%" }.joined(separator: " ")
        let memTop = st.topMem.map { "\($0.name):\(Int($0.memMB))MB" }.joined(separator: " ")
        let band = TempBand.name(for: iconTemp)
        _ = band
        let tempStr = iconTemp.map { String(format: "%.0f", $0) } ?? "-"
        // ⚠️ 这里必须用 %@：用 %s 传 Swift String 会让 String(format:) 崩溃（已踩过）
        let fanInfo = status.map { "fans=\($0.fanRPM.map { String(format: "%.0f", $0) }) rng=\(String(format: "%.0f-%.0f", $0.fanMin ?? 0, $0.fanMax ?? 0)) mode=\($0.modes) pid=\($0.helperPID ?? -1) v\($0.protocolVersion)" } ?? "status=nil"
        let line = String(format: "%.0f\t%@\t%@\t%@\ticon=%@° level=%@ %@ gpu=%d mem=%.0f/%.0f cpuTop=[%@] memTop=[%@] peak=%@ thermal=%@\n",
                          Date().timeIntervalSince1970, titleText, helperDiagnosis,
                          isControlling ? "接管中" : "未接管", tempStr, band,
                          fanInfo, st.gpuUtil, st.memUsedGB, st.memTotalGB, cpuTop, memTop,
                          sessionPeak.map { String(format: "%.0f", $0) } ?? "-", st.thermalWarning)
        if let fh = FileHandle(forWritingAtPath: "/tmp/fanpilot-app.log") {
            fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); try? fh.close()
        } else {
            try? line.write(toFile: "/tmp/fanpilot-app.log", atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 菜单栏图标外观

    /// 温度配色阈值（用户指定）：< 93 绿；93–112 橙；> 112 红
    enum TempBand {
        static let greenUpperBound: Double = 93      // 低于此值 = 绿
        static let orangeUpperBound: Double = 112    // 高于此值 = 红

        static func color(for temp: Double?) -> NSColor {
            guard let t = temp else { return .secondaryLabelColor }
            if t < greenUpperBound { return .systemGreen }
            if t <= orangeUpperBound { return .systemOrange }
            return .systemRed
        }

        static func name(for temp: Double?) -> String {
            guard let t = temp else { return "无读数" }
            if t < greenUpperBound { return "green" }
            if t <= orangeUpperBound { return "orange" }
            return "red"
        }
    }

    /// 接管中用实心风扇，未接管用线框
    func iconSymbolName() -> String { isControlling ? "fanblades.fill" : "fanblades" }

    // MARK: - 动作

    func takeover(profile: String) {
        // 守护开着的时候点档位按钮 = 换守护档位（要落盘，否则崩溃重启会回到旧档位）
        if guardArmed, profile == "cool" || profile == "maxCool" || profile == "custom" {
            setAutoGuard(true, profile: profile)
            return
        }
        let rpm: Double? = (profile == "fixed") ? 4000 : nil
        runControl("正在接管（冷机解锁最长约 12 秒）…") { [self] in
            client.takeover(profile: profile, rpm: rpm)
        }
    }

    /// 控制类命令统一入口：先显示进行中，再在后台等待（最长 30s），完成后刷新
    private func runControl(_ pendingMessage: String, _ work: @escaping () -> HelperStatus?) {
        lastActionMessage = pendingMessage
        ioQueue.async { [weak self] in
            let r = work()
            DispatchQueue.main.async {
                guard let self else { return }
                if let r, r.ok {
                    self.lastActionMessage = r.message ?? "已执行"
                } else if !self.helperSupportsGuard {
                    // 旧版 helper 不认识新命令 → 说清楚原因并给出下一步，
                    // 不要让用户看到"read() = -1 errno=35"这种看不懂的报错。
                    self.lastActionMessage = "失败：当前特权组件是旧版（没有「自动守护」功能）。"
                        + "请点「🔧 重装 / 修复特权组件」，在终端输入一次密码即可。"
                    self.refresh()
                } else {
                    self.lastActionMessage = r?.message ?? "操作失败（\(self.helperDiagnosis)）"
                }
                self.ioInFlight = false
                self.refresh()
            }
        }
    }

    func setRPM(_ rpm: Double) {
        runControl("正在设为固定 \(Int(rpm)) RPM…") { [self] in
            client.takeover(profile: "fixed", rpm: rpm, alwaysOn: true)
        }
    }

    func applyCustom() {
        editing = editing.normalized()
        issues = editing.validate()
        guard issues.isEmpty else { lastActionMessage = "参数有误，未下发"; return }
        let c = editing
        // ★ 守护开着的时候，必须把**守护档位**也切到「自定义」。
        //   否则：曲线页点了「应用到风扇」→ 自定义生效 → 但守护仍按 guardProfile=cool 同步
        //   → 33 秒后被「清凉 88°C」顶回去（用户实测："监控页清凉温度咋不变"）。
        if guardArmed || store.prefs.autoGuard {
            store.prefs.autoGuard = true
            setAutoGuard(true, profile: "custom")
            return
        }
        runControl("正在应用自定义档位…") { [self] in client.takeover(custom: c) }
    }

    func release() {
        // 交还系统 = 用户明确不要自动干预了 → 偏好也一起关掉。
        // 否则下次启动 App 的 syncAutoGuard 会把守护又打开，用户会觉得"说了交还怎么又接管"。
        if store.prefs.autoGuard {
            store.prefs.autoGuard = false
            store.save()
            appLog("用户点击交还系统 → 同步关闭自动守护偏好")
        }
        guardArmed = false
        runControl("正在交还系统…") { [self] in client.releaseToAuto() }
    }

    func saveProfile() {
        editing = editing.normalized()
        issues = editing.validate()
        guard issues.isEmpty else { lastActionMessage = "参数有误，未保存"; return }
        store.upsert(editing)
        lastActionMessage = "已保存到 \(store.directory.path)/profiles.json"
    }

    private func report(_ r: HelperStatus?, fallback: String) {
        if let r, r.ok { lastActionMessage = r.message ?? "已执行" }
        else { lastActionMessage = r?.message ?? "\(fallback)（\(helperDiagnosis)）" }
        refresh()
    }

    /// 一键安装/修复特权组件。
    ///
    /// ⚠️ **不能用 `do shell script ... with administrator privileges`**：
    /// 那个 root shell 读取 `~/Documents` 下的脚本会被 TCC 拒绝，
    /// 实测报错 `Operation not permitted (126)` —— 和 `--dev` 模式踩的是同一个坑。
    /// 改为打开 `.command` 文件：由**终端**执行，而终端已被授予该目录访问权限。
    // MARK: - P4：高温通知 + 会话 CSV + 开机自启

    /// 请求通知权限。**必须在 main bundle 里运行**：`UNUserNotificationCenter.current()`
    /// 对无 bundleIdentifier 的裸可执行文件会直接抛异常。
    func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else {
            notificationStatus = "非 App 包运行，通知不可用"
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, err in
            DispatchQueue.main.async {
                if let err {
                    self?.notificationStatus = "授权失败：\(err.localizedDescription)"
                    return
                }
                self?.notificationStatus = granted ? "已授权" : "被拒绝（系统设置 → 通知 → FanPilot）"
                appLog("通知授权：\(granted ? "已授权" : "被拒绝")")
            }
        }
    }

    /// 每条采样：跑一遍高温策略 + 写一行 CSV
    private func feedAlertsAndLog() {
        let now = Date()
        let hotspot = status?.hotspot

        // ── 高温通知 ──
        if store.prefs.notifyOnHighTemp {
            if let alert = alertPolicy.step(temp: hotspot, now: now) {
                post(alert)
            }
            let lvl = alertPolicy.activeLevel
            if lvl != alertLevel { alertLevel = lvl }
        } else if alertLevel != nil {
            alertLevel = nil
            alertPolicy.reset()
        }

        // ── 会话 CSV ──
        let log = sessionLog
        log.enabled = store.prefs.logToCSV
        log.minInterval = store.prefs.logInterval
        guard store.prefs.logToCSV else { return }
        if lastControllingLogged != isControlling {
            log.event("接管=\(isControlling ? 1 : 0) 档位=\(store.prefs.lastProfileKey) 原因=\(status?.reason ?? "-")")
            lastControllingLogged = isControlling
        }
        log.sample(SessionLog.Sample(
            hotspot: hotspot, hotspotRaw: status?.hotspotRaw, peak: sessionPeak,
            fanRPM: status?.fanRPM ?? [], fanTargets: status?.fanTargets ?? [],
            modes: status?.modes ?? [], power: status?.power,
            gpu: Double(stats.gpuUtil),
            memUsedGB: stats.memUsedGB, memTotalGB: stats.memTotalGB,
            load1: stats.loadAvg,
            controlling: isControlling, helper: helperDiagnosis), now: now)
    }

    private func post(_ alert: TempAlertPolicy.Alert) {
        appLog("高温通知：[\(alert.level.rawValue)] \(alert.title)")
        sessionLog.event("ALERT \(alert.level.rawValue) \(String(format: "%.1f", alert.temp))°C")
        notify(title: alert.title, body: alert.body,
               critical: alert.level != .warn,
               id: "fanpilot-\(alert.level.rawValue)-\(Int(Date().timeIntervalSince1970))")
    }

    /// 发一条系统通知（高温 / helper 崩溃等）。非 App 包运行时静默跳过。
    private func notify(title: String, body: String, critical: Bool = false, id: String? = nil) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = critical ? .defaultCritical : .default
        // 立刻送达（trigger=nil）：告警不能等
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id ?? "fanpilot-\(UUID().uuidString)",
                                  content: content, trigger: nil))
    }

    // MARK: - 自动守护

    /// 开启/关闭自动守护。开启后 helper 会**常驻**跑控制环（凉时被动、热了自动接管），
    /// 状态落盘在 root 目录 → 关掉 App、helper 崩溃重启、重启电脑都会自动恢复。
    func setAutoGuard(_ on: Bool, profile: String? = nil) {
        store.prefs.autoGuard = on
        if let profile { store.prefs.guardProfile = profile }
        store.save()
        let want = profile ?? store.prefs.guardProfile
        appLog("自动守护：请求 \(on ? "开启（\(want)）" : "关闭")")
        // profile == "custom" 时要把**用户自己编的曲线**一起下发，
        // 否则 helper 只会用 ThermalProfile.from(custom:) 的缺省值。
        let custom: CustomProfileData? = (want == "custom") ? store.profiles.first : nil
        if want == "custom" && custom == nil {
            lastActionMessage = "还没有保存过自定义档位：请先在「曲线」页填好参数并点「保存」"
            logTitle(); return
        }
        // 走后台队列：arm 属于控制类命令，冷机解锁最坏要十几秒，不能卡住界面
        runControl(on ? "正在开启自动守护（冷机解锁最长约 12 秒）…" : "正在关闭自动守护…") { [self] in
            on ? client.arm(profile: want, custom: custom) : client.disarm()
        }
        if on {
            sessionLog.event("ARM_REQUEST profile=\(want)")
            guardArmed = true
            guardProfile = want
        } else {
            sessionLog.event("DISARM_REQUEST")
            guardArmed = false
        }
    }

    /// App 启动 / helper 恢复后，把偏好同步给 helper。
    /// （helper 自己也会用落盘状态恢复守护；这里只负责"偏好与真实状态对齐"。）
    func syncAutoGuard() {
        let online = helperDiagnosis == "正常"
        // helper 从"不在线"变成"在线"（刚装好 / 刚重启）→ 允许再同步一次
        if online && !helperWasOnline {
            didSyncGuard = false
            // 这条日志是"装的是新版还是旧版 helper"的现场证据（我没有截图权限，靠它验证 UI 分支）
            appLog("helper 已上线 → 重新同步自动守护；features=\(status?.features ?? []) 支持守护=\(helperSupportsGuard)")
            appLog("生效档位=\(status?.profile ?? "-") 守护档位=\(status?.armedProfile ?? guardProfile) → \(effectiveTargetText)")
        }
        helperWasOnline = online
        guard online, !didSyncGuard else { return }
        didSyncGuard = true
        if store.prefs.autoGuard, !guardArmed {
            appLog("按偏好同步自动守护：开启（\(store.prefs.guardProfile)）")
            setAutoGuard(true)
        } else if !store.prefs.autoGuard, guardArmed {
            appLog("按偏好同步自动守护：关闭")
            setAutoGuard(false)
        } else {
            appLog("自动守护状态已与偏好一致（armed=\(guardArmed)）")
        }
    }

    /// 「测试通知」按钮：让用户在真机上确认权限与显示是否正常（我也能靠日志验证）
    func sendTestNotification() {
        notificationStatus = "非 App 包运行，通知不可用"
        requestNotificationPermission()
        let alert = TempAlertPolicy.Alert(level: .warn, temp: 100,
                                          title: "✅ 高温通知测试",
                                          body: "看到这条说明通知正常。真实触发条件：≥100°C 持续 10 秒 / ≥105°C 持续 5 秒 / ≥112°C 立即。")
        post(alert)
        lastActionMessage = "已发送测试通知（若没看到，检查 系统设置 → 通知 → FanPilot）"
    }

    func openLogFolder() {
        let dir = SessionLog.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([sessionLog.fileURL()])
        lastActionMessage = "日志目录：\(dir.path)"
        logTitle()
    }

    /// 导出今日 CSV 到用户选择的位置（NSSavePanel）
    func exportTodayCSV() {
        sessionLog.flush()
        let src = sessionLog.fileURL()
        guard FileManager.default.fileExists(atPath: src.path) else {
            lastActionMessage = "今天还没有记录（开关是否打开？）"
            logTitle(); return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = src.lastPathComponent
        panel.canCreateDirectories = true
        panel.title = "导出 FanPilot 今日 CSV"
        if panel.runModal() == .OK, let dst = panel.url {
            try? FileManager.default.removeItem(at: dst)
            do {
                try FileManager.default.copyItem(at: src, to: dst)
                lastActionMessage = "已导出 → \(dst.path)"
            } catch {
                lastActionMessage = "导出失败：\(error.localizedDescription)"
            }
        }
        logTitle()
    }

    /// 开机自启开关（LaunchAgent 方案，见 FanPilotCore/LaunchAtLogin.swift）
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                // App 包路径：从 Bundle.main 取（无论从哪启动都能拿到 .app 本身）
                let appURL = Bundle.main.bundleURL
                try LaunchAtLogin.enable(appURL: appURL)
                lastActionMessage = "已开启开机自启 → \(appURL.path)"
            } else {
                _ = LaunchAtLogin.disable()
                lastActionMessage = "已关闭开机自启"
            }
        } catch {
            lastActionMessage = "开机自启设置失败：\(error.localizedDescription)"
        }
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
        appLog("开机自启：\(LaunchAtLogin.statusText())")
        logTitle()
    }

    func installHelper() {
        // ★★ 不要把 ~/Documents 下的脚本直接丢给终端执行 ★★
        //   ~/Documents 受 TCC 保护：`do shell script ... with administrator privileges`
        //   或终端读它会得到 "Operation not permitted (126)" —— 用户看到的就是「安装不成功」。
        //   做法：把「安装脚本 + 已构建好的 helper 二进制」一起暂存到
        //   ~/Library/Application Support/FanPilot/installer（不受 TCC 保护），
        //   再打开终端跑那份副本。终端完全不需要访问「文稿文件夹」。
        do {
            let command = try stageInstaller()
            let ok = NSWorkspace.shared.open(command)
            lastActionMessage = ok
                ? "已打开终端执行安装：输入登录密码 → 看到「✅ helper 进程已运行」即成功（日志：/tmp/fanpilot-install-last.log）"
                : "无法打开终端。请手动执行：\nsudo \"\(command.deletingLastPathComponent().path)/install-helper.sh\""
        } catch {
            lastActionMessage = "准备安装文件失败：\(error.localizedDescription)"
            appLog("installHelper 失败：\(error.localizedDescription)")
        }
        logTitle()
    }

    /// 定位仓库根目录：从 App 包位置向上找 Package.swift（也支持 FANPILOT_REPO 覆盖）
    func repoRoot() -> URL? {
        let fm = FileManager.default
        if let e = ProcessInfo.processInfo.environment["FANPILOT_REPO"], !e.isEmpty {
            return URL(fileURLWithPath: e)
        }
        var dir = Bundle.main.bundleURL
        for _ in 0..<6 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/FanPilot", isDirectory: true)
        return fm.fileExists(atPath: fallback.appendingPathComponent("Package.swift").path)
            ? fallback : nil
    }

    /// 把安装所需文件暂存到非 TCC 目录，返回可直接双击/打开的 .command
    func stageInstaller() throws -> URL {
        let fm = FileManager.default
        guard let repo = repoRoot() else {
            throw NSError(domain: "FanPilot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "找不到 FanPilot 仓库（没有 Package.swift）"])
        }
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            .appendingPathComponent("FanPilot/installer", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        // 1) 安装脚本
        let srcScript = repo.appendingPathComponent("Tools/install-helper.sh")
        guard fm.fileExists(atPath: srcScript.path) else {
            throw NSError(domain: "FanPilot", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "缺少 \(srcScript.path)"])
        }
        let dstScript = base.appendingPathComponent("install-helper.sh")
        try? fm.removeItem(at: dstScript)
        try fm.copyItem(at: srcScript, to: dstScript)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstScript.path)

        // 2) helper 二进制（脚本会优先用同目录下的这一份）
        let candidates = ["release", "debug"].map {
            repo.appendingPathComponent(".build/\($0)/fanpilot-helper")
        }
        guard let bin = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            throw NSError(domain: "FanPilot", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "还没构建 helper，请先在终端跑： cd \(repo.path) && swift build"])
        }
        let dstBin = base.appendingPathComponent("fanpilot-helper")
        try? fm.removeItem(at: dstBin)
        try fm.copyItem(at: bin, to: dstBin)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstBin.path)

        // 3) 终端启动脚本（同时把输出 tee 到固定路径，装不上时我能直接读日志）
        let cmdURL = base.appendingPathComponent("安装FanPilot特权组件.command")
        let cmd = """
        #!/bin/bash
        # 由 FanPilot App 生成：在本目录（非 TCC 保护目录）内完成安装
        cd "$(dirname "$0")" || exit 1
        clear
        cat <<'BANNER'
        ╔══════════════════════════════════════════════════════════════╗
        ║  FanPilot · 安装 / 修复特权组件（helper）                     ║
        ╠══════════════════════════════════════════════════════════════╣
        ║  接下来会要求你输入一次登录密码（sudo）。                     ║
        ║                                                              ║
        ║  它会做什么：                                                 ║
        ║   1. 把 helper 装到 /usr/local/libexec/fanpilot-helper        ║
        ║   2. 注册 root LaunchDaemon（开机自启、崩溃自动拉起）          ║
        ║   3. 启动并打印状态                                           ║
        ║                                                              ║
        ║  安全设计：                                                   ║
        ║   · helper 启动时**第一时间交还系统风扇控制**（红线）          ║
        ║   · 只监听 Unix socket，并用 getpeereid() 校验对端 UID        ║
        ╚══════════════════════════════════════════════════════════════╝

        BANNER
        LOG="/tmp/fanpilot-install-last.log"
        echo "▸ 安装前置自检："
        sudo ./install-helper.sh diagnose 2>&1 | tee "$LOG"
        echo
        echo "▸ 开始安装（请输入密码）…"
        sudo ./install-helper.sh install 2>&1 | tee -a "$LOG"
        echo
        echo "════════════════════════════════════════════"
        if pgrep -f /usr/local/libexec/fanpilot-helper >/dev/null 2>&1; then
          echo "✅ 安装成功：helper 正在运行。回到 FanPilot 面板即可看到「正常」，守护会自动恢复。"
        else
          echo "❌ 安装未成功。日志已保存在：$LOG"
          echo "   把这份日志发给开发者即可定位（多数是 launchd 竞态，重跑一次通常就好了）。"
          echo "   手动重试： sudo ./install-helper.sh install"
        fi
        echo "════════════════════════════════════════════"
        read -n 1 -s -r -p "按任意键关闭此窗口…"
        """
        try cmd.write(to: cmdURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cmdURL.path)
        appLog("安装文件已暂存：\(base.path)（避开 ~/Documents 的 TCC 限制）")
        return cmdURL
    }

    func releaseOnQuitIfNeeded() {
        // ★ 「自动守护」优先于「退出时交还系统」。
        //   否则关掉 App 就等于把守护关掉，和"关掉 App 也会继续守护"的承诺自相矛盾
        //   （而且用户正是为了"人不在也压得住温度"才开守护的）。
        //   想真正收手：用面板里的「交还系统」或 fanpilot disarm，那会显式关掉守护。
        if guardArmed && store.prefs.autoGuard {
            appLog("退出：自动守护已开启 → 保持守护，不交还系统（收手请用「交还系统」）")
            sessionLog.event("QUIT_KEEP_GUARD profile=\(guardProfile)")
            sessionLog.flush()
            return
        }
        sessionLog.event("QUIT releaseOnQuit=\(store.prefs.releaseOnQuit) controlling=\(isControlling)")
        sessionLog.flush()
        guard isControlling else { return }
        if store.prefs.releaseOnQuit {
            _ = client.releaseToAuto()
            NSLog("[FanPilot] 退出：已交还系统控制")
        } else {
            NSLog("[FanPilot] 退出：按设置保留接管状态（手动交还请执行 fanpilot auto）")
        }
    }
}

// MARK: - 监控页

struct MonitorTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        // scrollIndicators(.visible)：macOS 默认隐藏滚动条，用户会以为"下面没内容了"
        ScrollView { content.padding(.trailing, 2) }
            .scrollIndicators(.visible)
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            guardBanner
            header
            Divider()
            if state.status?.hasFans == false {
                Text("此机型无风扇（被动散热）—— 仅提供温度监控")
                    .font(.system(size: 11)).foregroundColor(.orange)
            } else {
                sensors; Divider(); fans
            }
            Divider()
            loadSection
            Divider()
            detailSection
            Divider()
            controls
            Spacer(minLength: 0)
        }
    }

    /// 守护档位显示名（含 custom——2026-09-16 修复：此前 custom 落到 else 分支误显示为「清凉」）
    private func guardProfileName(_ p: String) -> String {
        switch p {
        case "maxCool": return "最强清凉"
        case "custom":  return "自定义"
        default:        return "清凉"
        }
    }

    /// ★ 自动守护状态条：放在最顶上。
    /// 2026-09-13 的事故就是"以为有人在管，其实没人管"—— 这个状态必须一眼可见。
    private var guardBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: state.guardArmed ? "shield.lefthalf.filled"
                                : (state.helperIsOutdated ? "exclamationmark.triangle" : "shield.slash"))
                    .font(.system(size: 13))
                    .foregroundColor(state.guardArmed ? .green : .orange)
                Text(state.helperIsOutdated ? "自动守护不可用（组件过旧）"
                     : (state.guardArmed
                        ? "自动守护中 · \(guardProfileName(state.guardProfile))"
                        : "自动守护未开启"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(state.guardArmed ? .primary : .orange)
                if state.guardArmed {
                    Text(state.isControlling ? "⚡️ 正在强制散热" : "被动待命")
                        .font(.system(size: 10))
                        .foregroundColor(state.isControlling ? .orange : .secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { state.guardArmed },
                    set: { state.setAutoGuard($0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(!state.helperSupportsGuard)
                    .help(state.helperSupportsGuard
                          ? "开启后 helper 常驻守护：温度 <\(Int(ActivationPolicy.daily.engageTemp))°C 且功率 <\(Int(ActivationPolicy.daily.engagePower))W 时完全不干预，超过任一门限自动接管"
                          : "当前特权组件版本过旧，不支持自动守护 —— 请先点下方「🔧 重装 / 修复特权组件」")
            }
            HStack(spacing: 6) {
                // 2026-09-16 档位精简：选择器移除，守护固定跑自定义档（预设保留在代码里作兜底）。
                Text("档位").font(.system(size: 10)).foregroundColor(.secondary)
                Text("自定义（在「曲线」页编辑）").font(.system(size: 10, weight: .medium))
                // ★ 显示**实际生效**的温度（来自 helper），不再让用户猜 85 还是 88 在跑
                Text(state.effectiveTargetText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .help("这是特权组件当前真正在用的目标温度（曲线页改的是「自定义」档位）")
            }
            Text(state.helperIsOutdated
                 ? "特权组件是旧版（不支持自动守护）→ 点下面「🔧 重装 / 修复特权组件」，一条密码即可"
                 : (state.guardArmed
                    ? "关掉 App 也会继续守护；helper 崩溃重启、重启电脑都会自动恢复"
                    : "⚠️ 现在没有任何自动干预：温度再高风扇也不会被本软件拉起来"))
                .font(.system(size: 9))
                .foregroundColor(state.helperIsOutdated ? .orange : .secondary)
                .lineLimit(2)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(state.guardArmed ? Color.green.opacity(0.10) : Color.orange.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(state.guardArmed ? Color.green.opacity(0.35) : Color.orange.opacity(0.5),
                    lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(state.status?.hotspot.map { String(format: "%.0f°C", $0) } ?? "--")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.isControlling ? "⚡️ FanPilot 接管中" : "○ 系统自动管理")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(state.isControlling ? .orange : .secondary)
                Text(state.status?.reason ?? state.helperDiagnosis)
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
            }
            Spacer()
        }
    }

    private var sensors: some View {
        let s = state.status
        return VStack(alignment: .leading, spacing: 3) {
            row("CPU 核心", s?.cpuHot, "°C"); row("GPU", s?.gpuHot, "°C")
            row("内存簇", s?.memHot, "°C"); row("供电 VRM", s?.vrmHot, "°C")
            row("系统功率", s?.power, "W")
        }
    }

    private var fans: some View {
        let s = state.status
        let rpms = s?.fanRPM ?? []
        let targets = s?.fanTargets ?? []
        return VStack(alignment: .leading, spacing: 3) {
            // 两台风扇分别显示（之前只显示 F0，看不到 F1 的状态）
            ForEach(Array(rpms.enumerated()), id: \.offset) { i, rpm in
                HStack {
                    Text("风扇 F\(i)").font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    let t = i < targets.count ? targets[i] : 0
                    Text(String(format: "%.0f / 目标 %.0f RPM", rpm, t))
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            HStack {
                Text("上限 / 模式 / Ftst").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f  %@  Ftst=%.0f", s?.fanMax ?? 0,
                            s?.modeDescription ?? "--", s?.ftst ?? -1))
                    .font(.system(size: 11))
            }
        }
    }

    /// 系统负载区：CPU/内存占用排名、GPU 利用率、会话峰值、系统热告警
    private var loadSection: some View {
        let st = state.stats
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("GPU 利用率").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Text("\(st.gpuUtil)%").font(.system(size: 11, design: .monospaced))
                Text("  内存").font(.system(size: 11)).foregroundColor(.secondary)
                Text(String(format: "%.0f/%.0f GB", st.memUsedGB, st.memTotalGB))
                    .font(.system(size: 11, design: .monospaced))
            }
            if !st.topCPU.isEmpty {
                Text("CPU 占用 Top\(st.topCPU.count)").font(.system(size: 10)).foregroundColor(.secondary)
                ForEach(st.topCPU) { p in
                    HStack {
                        Text(p.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(String(format: "%.0f%%", p.cpu)).font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            if !st.topMem.isEmpty {
                Text("内存占用 Top\(st.topMem.count)").font(.system(size: 10)).foregroundColor(.secondary)
                ForEach(st.topMem) { p in
                    HStack {
                        Text(p.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(p.memText).font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            HStack {
                Text("本次运行峰值").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                if let peak = state.sessionPeak {
                    Text(String(format: "%.1f°C", peak) + (state.sessionPeakAt.map { "  " + timeText($0) } ?? ""))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(nsColor: AppState.TempBand.color(for: peak)))
                } else { Text("--").font(.system(size: 11)) }
            }
            HStack {
                Text("系统热告警").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Text("\(st.thermalWarning) / 性能 \(st.perfWarning)")
                    .font(.system(size: 11))
                    .foregroundColor(st.thermalWarning == "无" ? .secondary : .orange)
            }
        }
    }

    /// Apple 原厂曲线此刻会给多少转速（按本机实测点粗略拟合，用于对比）
    private func appleReferenceRPM(temp: Double?) -> Double? {
        guard let t = temp else { return nil }
        // 实测（见 Docs/M4Max-SensorMap.md §7）：95°C 以下几乎恒为最低转速；
        // 96→1350、108→1391、110→3235、112→2686（不同场景，取包络）
        if t <= 95 { return 1350 }
        let ratio = min(1.0, (t - 95) / 17.0)          // 95→112°C 缓慢爬升
        return 1350 + ratio * (3200 - 1350)
    }

    /// 接管细节 + 环境信息。档位目标/系数等参数已在曲线页直观呈现，不再重复罗列。
    private var detailSection: some View {
        let s = state.status
        let apple = appleReferenceRPM(temp: s?.hotspot)
        return VStack(alignment: .leading, spacing: 3) {
            Text("接管状态").font(.system(size: 10)).foregroundColor(.secondary)
            HStack {
                Text("当前档位").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Text(s?.profile ?? "auto").font(.system(size: 11, design: .monospaced))
            }
            HStack {
                Text("已接管时长").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                if let since = state.controllingSince, state.isControlling {
                    Text(timeText(since) + " 起").font(.system(size: 11, design: .monospaced))
                } else { Text("—").font(.system(size: 11)) }
            }
            HStack {
                Text("Apple 原厂此刻").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Text(apple.map { String(format: "≈ %.0f RPM", $0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // 档位目标/系数等参数已在曲线页直观呈现（目标虚线、实时曲线），此处不再重复罗列
            HStack {
                Text("helper PID / 协议").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Text("\(s?.helperPID.map(String.init) ?? "—") / v\(s?.protocolVersion ?? 0)")
                    .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.status?.helperIsOutdated == true {
                Text("ℹ️ 特权组件版本较旧（缺少每风扇目标转速），建议重装：")
                    .font(.system(size: 10)).foregroundColor(.orange)
                Text("sudo ~/Documents/FanPilot/Tools/install-helper.sh")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            // ★ 安装/修复按钮**永远显示**。
            //   踩过的坑：旧代码只在 `helperDiagnosis != "正常"` 时显示它，
            //   于是"helper 在线但版本过旧、需要重装"这个最常见的场景下按钮反而消失了，
            //   用户根本找不到入口（实测反馈："面板里找不到安装修复特权组件了"）。
            if !state.helperDiagnosis.hasPrefix("正常") {
                Text("⚠️ \(state.helperDiagnosis)").font(.system(size: 10)).foregroundColor(.orange)
                Button("🔧 安装特权组件") { state.installHelper() }
                    .controlSize(.small)
                Text("（在终端里安装，输入一次登录密码）")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            } else if state.helperIsOutdated {
                Text("⚠️ 特权组件版本过旧：不支持「自动守护」，高温时不会自动干预")
                    .font(.system(size: 10)).foregroundColor(.orange)
                Button("🔧 重装 / 修复特权组件") { state.installHelper() }
                    .controlSize(.small)
                Text("（点一下 → 终端里输入密码即可，约 10 秒；装完无需重启 App）")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                HStack(spacing: 6) {
                    Button("🔧 重装 / 修复特权组件") { state.installHelper() }.controlSize(.small)
                    Text("组件正常，一般不需要").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            // 2026-09-16：删除「清凉 / 最强清凉 / 4000 RPM」手动按钮——自动守护
            // （被动待命 + 自定义曲线 + 前馈抢跑）全面接管后已无使用场景，且误点
            // 会把守护从自定义档切回旧预设。保留「交还系统」= 唯一的总开关。
            HStack(spacing: 6) {
                Button("交还系统") { state.release() }
                    .help("关闭自动守护并交还风扇控制权（fanpilot disarm 的等价操作）")
            }
            .controlSize(.small)
            .disabled(state.status?.hasFans == false || !state.helperDiagnosis.hasPrefix("正常"))
            if !state.lastActionMessage.isEmpty {
                Text(state.lastActionMessage).font(.system(size: 10))
                    .foregroundColor(.secondary).lineLimit(3)
            }
        }
    }

    private func row(_ name: String, _ value: Double?, _ unit: String) -> some View {
        HStack {
            Text(name).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            Text(value.map { unit == "W" ? String(format: "%.0f W", $0) : String(format: "%.1f\(unit)", $0) } ?? "--")
                .font(.system(size: 11, design: .monospaced))
        }
    }
}

// MARK: - 曲线页

struct CurveTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView { content.padding(.trailing, 2) }
            .scrollIndicators(.visible)
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 2026-09-16：预设档已从 UI 撤下，"与清凉/最强清凉互相独立"的警示语随之过期删除。
            VStack(alignment: .leading, spacing: 2) {
                Text("改完点「应用到风扇」才会生效；守护开着时会自动把守护档位切成「自定义」。")
                    .font(.system(size: 9)).foregroundColor(.secondary)
                if !state.store.profiles.isEmpty {
                    Text("当前生效：\(state.effectiveTargetText)")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.10)))
            HStack {
                Text("档位名").font(.system(size: 11)).foregroundColor(.secondary)
                TextField("自定义", text: $state.editing.name).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                numField("目标温度", $state.editing.targetTemp, "°C")
                numField("重载目标", $state.editing.targetTempHeavy, "°C")
            }
            HStack(spacing: 12) {
                numField("Kp", $state.editing.kp, ""); numField("Ki", $state.editing.ki, "")
                numField("正修正", $state.editing.trimPositive, "")
                numField("负修正", $state.editing.trimNegative, "")
            }
            Toggle("功率前馈抢跑（负载先动，不等温度）", isOn: $state.editing.enableFeedForward).font(.system(size: 11))
            Toggle("轻负载不接管（日常不打扰）", isOn: $state.editing.respectsActivationGate).font(.system(size: 11))
            HStack {
                Toggle("怠速地板", isOn: Binding(
                    get: { state.editing.idleFloorRPM != nil },
                    set: { state.editing.idleFloorRPM = $0 ? 2000 : nil }))
                    .font(.system(size: 11))
                if state.editing.idleFloorRPM != nil {
                    TextField("", value: Binding(
                        get: { state.editing.idleFloorRPM ?? 2000 },
                        set: { state.editing.idleFloorRPM = $0 }), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 62)
                    Text("RPM").font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()
            HStack {
                Text("自定义曲线（温度 → 转速）").font(.system(size: 11, weight: .medium))
                Spacer()
                Button { state.editing.curve.append(CurvePointData(temp: 90, rpm: 4500)) } label: {
                    Image(systemName: "plus")
                }.controlSize(.mini)
            }
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Array(state.editing.curve.enumerated()), id: \.offset) { idx, _ in
                        HStack(spacing: 4) {
                            TextField("°C", value: $state.editing.curve[idx].temp, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).frame(width: 56)
                            Text("→").font(.system(size: 10)).foregroundColor(.secondary)
                            TextField("RPM", value: $state.editing.curve[idx].rpm, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).frame(width: 66)
                            Spacer()
                            Button { state.editing.curve.remove(at: idx) } label: {
                                Image(systemName: "trash")
                            }.controlSize(.mini)
                        }
                    }
                }
            }
            // 2026-09-16：高度自适应点数（约 31pt/行，上限 168 约 5 行）——
            // 之前写死 168，4 个点时下方留 3 行空白（用户反馈）。
            .frame(height: min(168, CGFloat(state.editing.curve.count) * 31 + 10))

            if !state.issues.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.issues, id: \.self) { i in
                        Text("• \(i)").font(.system(size: 10)).foregroundColor(.orange)
                    }
                }
            }

            HStack(spacing: 6) {
                Button("保存") { state.saveProfile() }
                Button("应用到风扇") { state.applyCustom() }
                Spacer()
                Text("\(state.editing.curve.count) 个点").font(.system(size: 10)).foregroundColor(.secondary)
                Text("谨慎修改").font(.system(size: 9)).foregroundColor(.secondary)
                // 2026-09-17：恢复出厂默认——只重置编辑缓冲区，不自动保存/下发，避免误触直接改硬件行为
                Button("恢复默认") {
                    state.editing = CustomProfileData()
                    state.issues = state.editing.validate()
                    state.lastActionMessage = "已恢复默认参数（仅编辑区，尚未保存；确认后点「保存」或「应用到风扇」）"
                }
                .help("把上方所有数字恢复为出厂标定值：目标 88°C / 重载 95°C / Kp 40 / Ki 2 / 修正 +1500/-600 / 四点曲线 50·70→1350、85→3800、95→5777")
            }
            .controlSize(.small)
            .disabled(state.status?.hasFans == false || !state.helperDiagnosis.hasPrefix("正常"))

            if !state.lastActionMessage.isEmpty {
                Text(state.lastActionMessage).font(.system(size: 10))
                    .foregroundColor(.secondary).lineLimit(3)
            }
            Divider()
            guardDetailSection
            Divider()
            // 2026-09-16：温度实时曲线与「记录与通知」上下对调——曲线是高频关注内容，提到日志区上面
            TempHistoryCard(state: state)
            Divider()
            loggingSection
        }
    }

    /// 自动守护的细节说明（开关本体在「监控」页顶部状态条，这里给原理与落盘位置）
    private var guardDetailSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("自动守护").font(.system(size: 11, weight: .medium))
                Spacer()
                Text(state.guardArmed ? "🛡 已开启" : "⚠️ 未开启")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(state.guardArmed ? .green : .orange)
            }
            Text("激发门限：温度 ≥\(Int(ActivationPolicy.daily.engageTemp))°C **或** 功率 ≥\(Int(ActivationPolicy.daily.engagePower))W 持续 \(Int(ActivationPolicy.daily.engageDwell)) 秒 → 自动接管；"
                 + "回落到 <\(Int(ActivationPolicy.daily.releaseTemp))°C 且 <\(Int(ActivationPolicy.daily.releasePower))W 持续 \(Int(ActivationPolicy.daily.releaseDwell)) 秒 → 自动退出。凉的时候完全不碰风扇。")
                .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(3)
            Text("状态存在 /usr/local/var/fanpilot/armed.json（root）→ 关掉 App、"
                 + "helper 崩溃重启、重启电脑都会自动恢复守护。")
                .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(3)
        }
    }

    /// 记录与通知（P4）：高温通知 / 会话 CSV / 开机自启
    private var loggingSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text("记录与通知").font(.system(size: 11, weight: .medium))
                Spacer()
                if let lvl = state.alertLevel {
                    Text(lvl == .warn ? "⚠️ 温度偏高" : "🔥 温度告警")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(lvl == .warn ? .orange : .red)
                }
            }
            HStack(spacing: 12) {
                Toggle("高温通知", isOn: Binding(
                    get: { state.store.prefs.notifyOnHighTemp },
                    set: { state.store.prefs.notifyOnHighTemp = $0; state.store.save() }))
                    .toggleStyle(.checkbox)
                Toggle("记录 CSV", isOn: Binding(
                    get: { state.store.prefs.logToCSV },
                    set: { state.store.prefs.logToCSV = $0; state.store.save() }))
                    .toggleStyle(.checkbox)
                Toggle("开机自启", isOn: Binding(
                    get: { state.launchAtLoginEnabled },
                    set: { state.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox)
            }
            .font(.system(size: 10))
            HStack(spacing: 6) {
                Button("测试通知") { state.sendTestNotification() }.controlSize(.small)
                Button("打开日志目录") { state.openLogFolder() }.controlSize(.small)
                Button("导出今日 CSV") { state.exportTodayCSV() }.controlSize(.small)
            }
            // 自启状态与上方「开机自启」开关重复，不再单独展示
                .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
            Text("触发：≥100°C 持续 10s 提醒 / ≥105°C 持续 5s 报警 / ≥112°C 立即响铃")
                .font(.system(size: 9)).foregroundColor(.secondary)
        }
    }



    private func numField(_ title: String, _ value: Binding<Double>, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundColor(.secondary)
            HStack(spacing: 2) {
                TextField("", value: value, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 62)
                if !unit.isEmpty { Text(unit).font(.system(size: 10)).foregroundColor(.secondary) }
            }
        }
    }
}

// MARK: - 面板

/// 温度实时曲线卡片（15 分钟窗口，2s 采样）—— 曲线页底部与菜单栏迷你面板共用
struct TempHistoryCard: View {
    @ObservedObject var state: AppState

    /// 四族曲线定义（与 ThermalSnapshot 的族一致；颜色需要在本机浅色/深色主题下都区分明显）。
    /// ★ 用户指定样式（2026-09-14）：CPU/GPU/内存三条淡化到 30%，VRM 保持全不透明并加粗——
    ///   热点通常跟随供电，VRM 是判断"功率冲击"的主线，其余三族退为背景参照。
    private struct FamilySeries {
        let name: String
        let color: Color
        let value: (AppState.TempSample) -> Double?
        /// 主线（不淡化、加粗）；nil 视为 false
        var isPrimary: Bool { primary }
        let primary: Bool

        init(name: String, color: Color, primary: Bool = false,
             value: @escaping (AppState.TempSample) -> Double?) {
            self.name = name; self.color = color; self.primary = primary; self.value = value
        }
        /// 绘制用颜色：非主线淡化到 30%
        var strokeColor: Color { primary ? color : color.opacity(0.3) }
        /// 主线略粗（1.4 → 1.8）
        var lineWidth: CGFloat { primary ? 1.8 : 1.4 }
    }
    private let families: [FamilySeries] = [
        FamilySeries(name: "CPU", color: .blue, value: { $0.cpu }),
        FamilySeries(name: "GPU", color: .purple, value: { $0.gpu }),
        FamilySeries(name: "内存", color: .orange, value: { $0.mem }),
        FamilySeries(name: "VRM", color: .teal, primary: true, value: { $0.vrm }),
    ]

    var body: some View { tempChartSection }

    private var tempChartSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("温度实时曲线").font(.system(size: 11, weight: .medium))
                Text("（最近 15 分钟 · 每 2s 采样）").font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                if let last = state.tempHistory.last {
                    Text(String(format: "热点 %.1f°C", last.temp))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(nsColor: AppState.TempBand.color(for: last.temp)))
                }
            }
            // 图例：各族当前读数（该族本轮无读数则不显示）——字号加大保证一眼可读；
            // 圆点透明度与曲线一致（主线全色，其余 30%）
            HStack(spacing: 12) {
                ForEach(families, id: \.name) { f in
                    if let v = state.tempHistory.last.flatMap(f.value) {
                        HStack(spacing: 4) {
                            Circle().fill(f.strokeColor).frame(width: 8, height: 8)
                            Text("\(f.name) \(Int(v.rounded()))°")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.primary)
                        }
                    }
                }
                Spacer()
            }
            Group {
                if state.tempHistory.count < 2 {
                    Text("正在采样…（每 2 秒一个点，稍等片刻出现曲线）")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 140)
                } else {
                    tempChart
                }
            }
        }
        .padding(.top, 2)
    }

    /// 摊平后的画图数据点：带族名标签，让 Swift Charts 按族自动分组成四条独立曲线
    private struct FamilyPoint: Identifiable {
        let family: String
        let t: Date
        let v: Double
        var id: String { "\(family)-\(t.timeIntervalSince1970)" }
    }

    private var tempChart: some View {
        let samples = state.tempHistory
        let target = state.editing.targetTemp
        let points: [FamilyPoint] = samples.flatMap { s in
            families.compactMap { f in f.value(s).map { FamilyPoint(family: f.name, t: s.t, v: $0) } }
        }
        // Y 域：覆盖四族全部读数 + 热点（峰值保持可能瞬时高于所有族当前值）+ 目标线
        let allVals = samples.flatMap { s in [s.temp, s.cpu, s.gpu, s.mem, s.vrm].compactMap { $0 } }
        var lo = allVals.min().map { floor(($0 - 4) / 10) * 10 } ?? 40
        lo = min(lo, target - 8)
        var hi = max(target + 8, (allVals.max() ?? 60) + 6)
        hi = max(hi, lo + 40)
        return Chart {
            ForEach(points) { p in
                LineMark(x: .value("时间", p.t), y: .value("温度", p.v))
                    .foregroundStyle(by: .value("传感器族", p.family))
                    // 主线（VRM）略粗；淡化族的线宽不变，透明度由颜色 scale 控制
                    .lineStyle(StrokeStyle(lineWidth:
                        (families.first { $0.name == p.family }?.lineWidth ?? 1.4),
                        lineCap: .round))
            }
            .interpolationMethod(.catmullRom)

            RuleMark(y: .value("目标", target))
                .foregroundStyle(Color.secondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .topTrailing) {
                    Text(String(format: "目标 %.0f°C", target))
                        .font(.system(size: 8)).foregroundColor(.secondary)
                }
        }
        // ★ 颜色必须在这里锁死：不指定 scale 时 Charts 用默认调色板（第一条=蓝）。
        //   淡化族的透明度在 scale 里用 color.opacity(0.3) 实现（用户指定 30%）
        .chartForegroundStyleScale(domain: families.map(\.name),
                                   range: families.map(\.strokeColor))
        .chartLegend(.hidden)   // 图例已在图上方自定义显示（带实时数值），隐藏 Charts 自动生成的下方标注
        .chartYScale(domain: lo...hi)
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 5)) {
                AxisValueLabel(format: .dateTime.minute().second(), centered: true)
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { m in
                if let v = m.as(Double.self) {
                    AxisValueLabel(String(format: "%.0f°", v))
                }
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
            }
        }
        .frame(height: 160)
    }
}

/// 菜单栏迷你面板：默认只显示 15 分钟实时温度曲线（横向窄条，基本不遮挡其它窗口），
/// 点「更多」后由 AppDelegate 切换为完整面板。
struct MiniPanelView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 6) {
            TempHistoryCard(state: state)
            Divider()
            HStack {
                Text(state.isControlling ? "⚡️ 接管中" : "○ 系统自动管理")
                    .font(.system(size: 10))
                    .foregroundColor(state.isControlling ? .orange : .secondary)
                Spacer()
                Button("更多 ▸") { state.popoverExpanded = true }
                    .controlSize(.small)
                    .help("展开完整面板（监控 / 曲线 / 记录与通知）")
            }
        }
        .padding(10)
        .frame(width: 420)
    }
}


struct PanelView: View {
    @ObservedObject var state: AppState
    /// true = 独立主窗口模式：**尺寸跟随窗口**（内容能一次看全）
    /// false = 菜单栏 popover 模式：固定尺寸（popover 不能由内容撑开）
    var flexible: Bool = false
    /// 当前选中的标签页 —— 面板高度随页自适应，消除页尾空白（2026-09-16）
    @State private var tab: Int = 0
    /// 各页内容实测高（--measure-panel：监控 525 / 曲线 767）+ 余量；
    /// 页面内容变动后请跑 `FanPilotMenu --measure-panel` 复核这两个数。
    private var adaptiveHeight: CGFloat {
        tab == 0 ? 600 : 830   // 内容高 + TabView 内边距 20 + 页脚 ~34 + 余量
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                MonitorTab(state: state).tabItem { Text("监控") }.tag(0)
                CurveTab(state: state).tabItem { Text("曲线") }.tag(1)
            }
            .padding(10)
            Divider()
            HStack {
                Toggle("退出时交还系统", isOn: Binding(
                    get: { state.store.prefs.releaseOnQuit },
                    set: { state.store.prefs.releaseOnQuit = $0; state.store.save() }))
                    .font(.system(size: 10)).toggleStyle(.checkbox)
                    .help("仅在「自动守护」关闭时生效 —— 守护开着的话，关掉 App 也会继续守护")
                Toggle("在 Dock 显示", isOn: Binding(
                    get: { state.store.prefs.showInDock },
                    set: { newValue in
                        state.store.prefs.showInDock = newValue; state.store.save()
                        NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                    }))
                    .font(.system(size: 10)).toggleStyle(.checkbox)
                Toggle("启动开窗", isOn: Binding(
                    get: { state.store.prefs.openWindowOnLaunch },
                    set: { state.store.prefs.openWindowOnLaunch = $0; state.store.save() }))
                    .font(.system(size: 10)).toggleStyle(.checkbox)
                    .help("启动时打开可缩放的主窗口（能看到全部内容）")
                Spacer()
                if !flexible {
                    Button("◂ 收起") { state.popoverExpanded = false }
                        .controlSize(.small)
                        .help("回到迷你面板（只显示温度曲线）")
                }
                Button("⤢ 窗口") { (NSApp.delegate as? AppDelegate)?.showPanelWindow() }
                    .controlSize(.small)
                    // 2026-09-17：已是独立窗口时按钮置灰——「窗口」入口只保留在菜单栏面板里
                    .disabled(flexible)
                    .help(flexible ? "已经是窗口模式" : "在主窗口中打开（可自由缩放，内容一屏看全）")
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Button("退出") { NSApplication.shared.terminate(nil) }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        // ★ 主窗口模式不写死尺寸（可自由缩放），但**切换标签页时由 onChange 调整窗口高**；
        //   popover 模式高度直接随标签页自适应。
        //   （2026-09-16：原写死 930，内容瘦身后监控页下方留白 ~350pt，用户两次反馈。）
        .frame(minWidth: flexible ? 440 : 430,
               idealWidth: flexible ? 560 : 430,
               maxWidth: flexible ? .infinity : 430,
               minHeight: flexible ? 440 : adaptiveHeight,
               idealHeight: adaptiveHeight,
               maxHeight: flexible ? .infinity : adaptiveHeight)
        .onAppear { if flexible { resizeWindow() } }
        .onChange(of: tab) { _ in if flexible { resizeWindow() } }
    }

    /// 主窗口模式：把窗口高度调到当前页内容高（顶边固定，宽度与用户位置不动）。
    private func resizeWindow() {
        (NSApp.delegate as? AppDelegate)?.resizePanelWindow(height: adaptiveHeight)
    }
}

// MARK: - App 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover = NSPopover()
    var panelWindow: NSWindow?
    /// 最近一次实际渲染到菜单栏的样式（字符串+颜色名），供日志自检
    private var lastRenderedStyle = "-"
    // 菜单栏双行内容（上温度/下功率）——见 installMenuBarContentView
    private var menuBarStack: NSStackView?
    private var menuBarIconView: NSImageView?
    private var menuBarTempLabel: NSTextField?
    private var menuBarPowerLabel: NSTextField?

    /// 在状态栏按钮里安装双行内容：[风扇图标] [温度 / 功率]。
    /// 为什么不用 attributedTitle：单行文本放不下"温度下再显示功率"的布局。
    /// 模板图标 + 动态文字颜色由系统按菜单栏明暗自动适配。
    private func installMenuBarContentView() {
        guard let button = statusItem.button else { return }
        let icon = NSImageView()
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let temp = NSTextField(labelWithString: "–°")
        temp.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let power = NSTextField(labelWithString: "")
        power.font = .monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        // ★ 用户指定：功率数字用白色
        power.textColor = .white
        let vStack = NSStackView(views: [temp, power])
        vStack.orientation = .vertical
        vStack.alignment = .centerX
        vStack.spacing = 0
        let hStack = NSStackView(views: [icon, vStack])
        hStack.orientation = .horizontal
        hStack.alignment = .centerY
        hStack.spacing = 3
        button.addSubview(hStack)
        hStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hStack.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            hStack.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        menuBarStack = hStack
        menuBarIconView = icon
        menuBarTempLabel = temp
        menuBarPowerLabel = power
    }
    let state = AppState.shared
    private var cancellables = Set<AnyCancellable>()
    /// 迷你面板（仅曲线）与完整面板（全部内容）的尺寸
    private let miniPopoverSize = NSSize(width: 420, height: 228)
    /// 完整面板尺寸。高度是**上限**（超过才滚动），实测内容 843pt → 取 890 留余量。
    /// 屏幕可视高 1084，放得下。
    private let fullPopoverSize = NSSize(width: 430, height: 930)
    /// 状态项是否真的落在菜单栏区域（false = 被 macOS 挤到屏幕外）
    private(set) var statusItemInMenuBar = true
    private var offBarStreak = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 默认**在 Dock 显示**：菜单栏可能被其它图标挤满（实测本机 x=0 被挤到最左），
        // Dock 图标是保底入口。用户在面板里确认菜单栏图标可见后可关掉。
        NSApp.setActivationPolicy(ProfileStore.shared.prefs.showInDock ? .regular : .accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = ""
            button.toolTip = "FanPilot"
            button.action = #selector(togglePopover(_:))
            button.target = self
            // ★ 双行内容：上行温度（带配色）、下行功率（W）。不再用 button.image/title，
            //   全部画进自定义 stack（模板图标自动适配菜单栏明暗）。
            installMenuBarContentView()
        }
        state.popoverExpanded = false
        applyPopoverMode(expanded: false)
        popover.behavior = .transient
        state.start()

        // ★ popover 双模式：默认迷你（仅 15 分钟曲线，横条不挡窗口），
        //   点「更多」展开完整面板；完整面板页脚「◂ 收起」返回迷你模式。
        state.$popoverExpanded
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                guard let self, self.popover.isShown else { return }
                self.applyPopoverMode(expanded: expanded)
            }
            .store(in: &cancellables)

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateStatusItemAppearance()
            self.logStatusItemGeometry()
        }
        // 注意：温度/功率画在自定义双行 stack 里（installMenuBarContentView），
        // 不再用 button.attributedTitle（单行，放不下两行内容）
        updateStatusItemAppearance()
        logStatusItemGeometry()
        appLog("启动；helper：\(state.helperDiagnosis)；菜单栏项在栏内=\(statusItemInMenuBar)")

        // ★ 菜单栏放不下时（macOS 会把项移到屏幕外，用户根本找不到），
        //   自动弹出一个独立窗口作为入口。
        // 启动 6 秒后用真实数据自检面板高度（离线自检用不到真实传感器/风扇数据）
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            self?.logPanelFitCheck()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            // 连续多次判定才动手：单次几何读数可能不准（实测偶尔会读到 x=0）
            if self.offBarStreak >= 3 {
                appLog("连续 \(self.offBarStreak) 次判定菜单栏项不在栏内 → 改用独立窗口")
                self.showPanelWindow()
            } else if self.state.store.prefs.openWindowOnLaunch {
                appLog("启动开窗已启用 → 打开主窗口（可缩放，内容一屏看全）")
                self.showPanelWindow()
            } else {
                appLog("菜单栏项已就位（不在栏内的连续次数=\(self.offBarStreak)）→ 不打开窗口")
            }
        }
    }

    /// 更新菜单栏外观：双行内容（上行温度带配色 / 下行功率）+ 模板风扇图标
    func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        let tempText: String
        let tempColor: NSColor
        if let t = state.iconTemp {
            tempText = "\(Int(t.rounded()))°"
            tempColor = AppState.TempBand.color(for: t)
        } else {
            tempText = "–°"
            tempColor = .secondaryLabelColor
        }
        menuBarTempLabel?.stringValue = tempText
        menuBarTempLabel?.textColor = tempColor
        let powerText = state.iconPower.map { "\(Int($0.rounded()))W" } ?? ""
        menuBarPowerLabel?.stringValue = powerText
        menuBarPowerLabel?.isHidden = powerText.isEmpty
        if let img = NSImage(systemSymbolName: state.iconSymbolName(),
                             accessibilityDescription: "FanPilot") {
            img.isTemplate = true
            menuBarIconView?.image = img
        }
        // 宽度跟随内容（stack 尺寸变化时同步 statusItem 长度，避免被截断或留白）
        if let stack = menuBarStack {
            statusItem.length = ceil(stack.fittingSize.width) + 10
        }
        // 自检留痕：确认颜色与内容真的写进了标签（看不到屏幕时靠它验证）
        let colorName: String
        switch tempColor {
        case NSColor.systemGreen: colorName = "green"
        case NSColor.systemOrange: colorName = "orange"
        case NSColor.systemRed: colorName = "red"
        case NSColor.secondaryLabelColor: colorName = "secondary"
        default: colorName = "other"
        }
        lastRenderedStyle = "\(tempText)|\(powerText)|\(colorName)"

        var tip = "FanPilot\n" + state.titleText
        if let p = state.iconPower {
            tip += String(format: "\n功率 %.0fW", p)
        }
        if let src = state.hotspotSourceName {
            tip += "\n来源：\(src)（四族传感器取最热）"
        }
        tip += "\n温度配色：<93°C 绿 / 93–112°C 橙 / >112°C 红"
        button.toolTip = tip
    }

    /// 测量完整面板的自然内容高度（监控/曲线两个 tab 取大者 + 页脚等 chrome）
    func measuredFullPanelHeight() -> CGFloat {
        let chrome: CGFloat = 54          // TabView padding(10×2) + Divider + 页脚
        let monitor = NSHostingView(rootView: MonitorTab(state: state).content).fittingSize.height
        let curve = NSHostingView(rootView: CurveTab(state: state).content).fittingSize.height
        return max(monitor, curve) + chrome
    }

    /// 面板高度自检：内容高 vs popover 可用高。
    /// 「窗口显示内容有限」这类问题的定量证据就靠它（我没有截图权限）。
    func logPanelFitCheck() {
        let need = measuredFullPanelHeight()
        let avail = fullPopoverSize.height   // ★ 自适应模式下这是高度上限（超出才滚动）
        let verdict = need <= avail ? "✅ 一屏放得下" : "⚠️ 缺 \(Int(need - avail)) pt，会滚动"
        appLog(String(format: "面板自检：内容需 %.0f pt，popover 上限 %.0f pt → %@",
                      need, avail, verdict))
    }

    /// 把状态栏项的真实几何与可见性写进日志 —— 用户"找不到图标"时靠它定位原因
    func logStatusItemGeometry() {
        let visible = statusItem.isVisible
        var onScreen = CGRect.zero
        if let button = statusItem.button, let win = button.window {
            onScreen = win.convertToScreen(button.convert(button.bounds, to: nil))
        }
        let screenH = NSScreen.main?.frame.height ?? 0
        // 菜单栏区域：屏幕顶部 ~28 点
        let inMenuBar = onScreen.minY > screenH - 40 && onScreen.width > 0
        statusItemInMenuBar = inMenuBar
        offBarStreak = inMenuBar ? 0 : offBarStreak + 1
        let winClass = statusItem.button?.window.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        let rendered = lastRenderedStyle
        let line = String(format: "%.0f\tSTATUSITEM\tvisible=%@ inMenuBar=%@ x=%.0f y=%.0f w=%.0f win=%@ rendered=%@\n",
                          Date().timeIntervalSince1970, visible ? "true" : "false",
                          inMenuBar ? "true" : "false",
                          onScreen.origin.x, onScreen.origin.y, onScreen.width, winClass, rendered)
        if let fh = FileHandle(forWritingAtPath: "/tmp/fanpilot-app.log") {
            fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); try? fh.close()
        } else {
            try? line.write(toFile: "/tmp/fanpilot-app.log", atomically: true, encoding: .utf8)
        }
    }

    /// popover 双模式内容切换：迷你（仅实时曲线）↔ 完整面板
    func applyPopoverMode(expanded: Bool) {
        if expanded {
            popover.contentViewController = NSHostingController(rootView: PanelView(state: state, flexible: false))
            // ★ 高度自适应内容：底部不再留大片空白；上限 840（内容超高才滚动）
            let need = measuredFullPanelHeight()
            popover.contentSize = NSSize(width: fullPopoverSize.width,
                                         height: min(max(need, 420), fullPopoverSize.height))
        } else {
            popover.contentViewController = NSHostingController(rootView: MiniPanelView(state: state))
            popover.contentSize = miniPopoverSize
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        appLog("面板被点击打开（popover 模式）")
        if popover.isShown { popover.performClose(sender) }
        else {
            state.popoverExpanded = false          // ★ 每次打开都回到迷你模式
            applyPopoverMode(expanded: false)
            state.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// 点击 Dock 图标 → 打开面板。
    /// 菜单栏项若被挤到屏幕外，popover 也会跟着跑到屏幕外 —— 此时改用独立窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !statusItemInMenuBar {
            showPanelWindow()
        } else if !popover.isShown {
            togglePopover(nil)
        }
        return true
    }

    /// 切换标签页时把主窗口高度调到当前页内容高（顶边固定；宽度/位置不动）。
    /// 用户手动拉大的窗口会在下次切换页时被收回——按 2026-09-16 反馈"消除空白"为准。
    func resizePanelWindow(height: CGFloat) {
        guard let w = panelWindow, w.isVisible, abs(w.frame.height - height) > 1 else { return }
        var f = w.frame
        f.origin.y += f.height - height      // 顶边固定
        f.size.height = height
        w.setFrame(f, display: true, animate: true)
    }

    /// 独立窗口模式（菜单栏不可用时的兜底入口）
    func showPanelWindow() {
        if let w = panelWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 可缩放（内容多，用户能自己拉大）；尺寸记忆在 UserDefaults
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 420, height: 480)

        // ★ 尺寸决策只做一次：要么用**有效**的记忆值，要么用默认值。
        //   踩过的坑：旧代码在"记忆值无效"这条分支里只是删掉记忆、**没有套用默认尺寸**，
        //   于是窗口保持初始 contentRect 又被 contentMinSize/视图 fittingSize 拉小，
        //   实测开出来只有 440×492（内容看不全）。
        var wantSize = NSSize(width: 560, height: 900)
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            wantSize = NSSize(width: min(560, vf.width - 80),
                              height: min(900, vf.height - 60))
        }
        var frame = NSRect(origin: .zero, size: wantSize)
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            frame.origin = NSPoint(x: vf.midX - wantSize.width / 2,
                                   y: vf.maxY - wantSize.height - 24)
        }
        if let saved = UserDefaults.standard.string(forKey: "panelWindowFrame") {
            let f = NSRectFromString(saved)
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(f) }
            if onScreen && f.height >= 600 && f.width >= 440 {
                frame = f
            } else {
                appLog(String(format: "忽略无效的窗口记忆尺寸 %.0fx%.0f → 用默认 %.0fx%.0f",
                              f.width, f.height, wantSize.width, wantSize.height))
                UserDefaults.standard.removeObject(forKey: "panelWindowFrame")
            }
        }
        // ⚠️ 注意顺序：setFrame 必须在 contentViewController 赋值**之后**。
        //    先 setFrame 再设 contentViewController，AppKit 会按视图的 fittingSize
        //    重新调整窗口 → 实测被压成 440×532（内容看不全）。
        window.title = "FanPilot"
        window.contentViewController = NSHostingController(rootView: PanelView(state: state, flexible: true))
        window.contentMinSize = NSSize(width: 440, height: 440)
        window.setFrame(frame, display: true)          // ← 必须在 contentViewController 之后
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panelWindow = window
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                               object: window, queue: .main) { note in
            if let w = note.object as? NSWindow {
                UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: "panelWindowFrame")
            }
        }
        appLog(String(format: "独立窗口已创建 frame=%.0f,%.0f %.0fx%.0f visible=%@",
                      window.frame.origin.x, window.frame.origin.y,
                      window.frame.width, window.frame.height,
                      window.isVisible ? "true" : "false"))
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.releaseOnQuitIfNeeded()
    }
}

/// 同时写系统日志与 /tmp/fanpilot-app.log —— 后者让我能在没有屏幕的情况下验证行为
func appLog(_ message: String) {
    NSLog("[FanPilot] %@", message)
    let line = String(format: "%.0f\tEVENT\t%@\n", Date().timeIntervalSince1970, message)
    if let fh = FileHandle(forWritingAtPath: "/tmp/fanpilot-app.log") {
        fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); try? fh.close()
    } else {
        try? line.write(toFile: "/tmp/fanpilot-app.log", atomically: true, encoding: .utf8)
    }
}

// 自检入口：FanPilotMenu --measure-panel
// 量出「监控/曲线」两页内容的真实高度 —— 我没有屏幕截图权限，靠它确认窗口高度够不够、
// 内容会不会被截断（这正是用户反馈「窗口显示内容有限」的根源）。
if CommandLine.arguments.contains("--measure-panel") {
    let state = AppState.shared
    state.refresh()
    RunLoop.main.run(until: Date().addingTimeInterval(3.5))   // 等后台读数落到 @Published
    let widths: [CGFloat] = [430, 560, 700, 900]
    print("屏幕可视区: \(NSScreen.main.map { "\($0.visibleFrame.width)x\($0.visibleFrame.height)" } ?? "?")")
    print("数据来源: \(state.helperDiagnosis)  风扇=\(state.status.map { $0.hasFans ? "有" : "无" } ?? "?")")
    let whole = NSHostingView(rootView: PanelView(state: state, flexible: false))
    print(String(format: "整块面板(popover 固定模式) = %.0f x %.0f pt", whole.fittingSize.width, whole.fittingSize.height))
    let contentH = NSHostingView(rootView: MonitorTab(state: state).content).fittingSize.height
    let avail = whole.fittingSize.height - 20 - 34   // TabView padding(10×2) + 页脚
    print(String(format: "面板可用内容高 %.0f pt vs 监控页实际需要 %.0f pt → %@",
                 avail, contentH, contentH <= avail ? "✅ 一屏放得下，无需滚动" : "⚠️ 仍需滚动，缺口 \(Int(contentH - avail)) pt"))
    for w in widths {
        let host = NSHostingView(rootView: MonitorTab(state: state).content)
        host.frame = NSRect(x: 0, y: 0, width: w, height: 100)
        let h = host.fittingSize.height
        let host2 = NSHostingView(rootView: CurveTab(state: state).content)
        host2.frame = NSRect(x: 0, y: 0, width: w, height: 100)
        let h2 = host2.fittingSize.height
        print(String(format: "宽 %.0f → 监控页内容高 %.0f pt，曲线页 %.0f pt（窗口可用高 ≈ 屏高-页脚60）", w, h, h2))
    }
    exit(0)
}

// 自检入口（无人值守验证用）：FanPilotMenu --stage-installer
// 只做「暂存安装文件」这一步然后退出 —— 让我在没有屏幕/不能点按钮时也能验证安装路径。
if CommandLine.arguments.contains("--stage-installer") {
    do {
        let url = try AppState.shared.stageInstaller()
        print("✅ 已暂存安装文件：\(url.path)")
        print("   同目录内容：")
        let dir = url.deletingLastPathComponent()
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? [] {
            print("     \(f)")
        }
        exit(0)
    } catch {
        print("❌ 暂存失败：\(error.localizedDescription)")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
