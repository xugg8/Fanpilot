import Foundation

// MARK: - 可序列化的档位数据（App 编辑 ↔ helper 执行）

/// 曲线锚点（温度 → 转速）
public struct CurvePointData: Codable, Equatable, Identifiable {
    public var id: Double { temp }
    public var temp: Double
    public var rpm: Double
    public init(temp: Double, rpm: Double) { self.temp = temp; self.rpm = rpm }
}

/// 前馈锚点（功率 → 转速）
public struct PowerPointData: Codable, Equatable {
    public var watts: Double
    public var rpm: Double
    public init(watts: Double, rpm: Double) { self.watts = watts; self.rpm = rpm }
}

/// 用户可编辑的完整档位定义。默认值 = 参考机型标定出的"清凉"档。
///
/// 自定义档的决策语义（2026-09-14 定稿）：**期望 = max(曲线, 前馈) + PI 修正**。
/// - 曲线（温度 → 转速）：响应温度，定"热到什么程度给多少转速"；
/// - 前馈（功率 → 转速）：**抢跑** —— 功率到位后温度要 ~16s 才到峰值，
///   这段盲区里曲线是瞎的，前馈按功率先把转速垫起来；谁算出来的高听谁的。
/// 关掉前馈则退回纯温度曲线（滞后响应）。
public struct CustomProfileData: Codable, Equatable {
    public var name: String = "自定义"
    public var targetTemp: Double = 88
    public var targetTempHeavy: Double = 95
    public var heavyPowerThreshold: Double = 110
    /// 怠速地板：nil = 关闭（空闲回落至硬件下限，风扇可停转）
    public var idleFloorRPM: Double? = nil
    public var kp: Double = 40
    public var ki: Double = 2
    public var trimPositive: Double = 1500
    public var trimNegative: Double = 600
    /// 功率前馈开关：开 = max(曲线, 前馈) 抢跑；关 = 纯温度曲线（滞后响应）
    public var enableFeedForward: Bool = true
    public var curve: [CurvePointData] = [
        // 2026-09-14 压测定稿：怠速段 50–70°C 压平（吸收热点传感器 53↔77°C 跳变，目标不动不吵）；
        // 70–95°C 一条直线缓抬（每 tick 目标步进小，风扇贴得住）；抢跑交给功率前馈。
        CurvePointData(temp: 50, rpm: 1350), CurvePointData(temp: 70, rpm: 1350),
        CurvePointData(temp: 85, rpm: 3800), CurvePointData(temp: 95, rpm: 5777),
    ]
    /// 前馈锚点默认抄清凉档的实测表 —— 该表已在本机标定过，是合理的抢跑起点
    public var feedForward: [PowerPointData] = [
        PowerPointData(watts: 30, rpm: 1350), PowerPointData(watts: 45, rpm: 1900),
        PowerPointData(watts: 60, rpm: 2600), PowerPointData(watts: 75, rpm: 3400),
        PowerPointData(watts: 90, rpm: 4200), PowerPointData(watts: 110, rpm: 5000),
        PowerPointData(watts: 130, rpm: 5777),
    ]
    /// 是否参与"轻负载不激发"策略（关闭 = 常驻接管）
    public var respectsActivationGate: Bool = true

    public init() {}

    /// 归一化：曲线/前馈按各自自变量升序排列（插值逻辑本身也会排序，这里让"所见即所用"一致）
    public func normalized() -> CustomProfileData {
        var c = self
        c.curve.sort { $0.temp < $1.temp }
        c.feedForward.sort { $0.watts < $1.watts }
        return c
    }

    /// 基本合法性检查 —— UI 与 helper 都要用它，避免把明显错误的参数下发到硬件
    public func validate() -> [String] {
        var issues: [String] = []
        if targetTemp < 60 || targetTemp > 105 { issues.append("目标温度应在 60–105°C（当前 \(Int(targetTemp))）") }
        if let heavy = targetTempHeavy as Double?, heavy < targetTemp {
            issues.append("重载目标温度不应低于普通目标温度")
        }
        if kp < 0 || kp > 300 { issues.append("Kp 应在 0–300 RPM/°C") }
        if ki < 0 || ki > 50 { issues.append("Ki 应在 0–50") }
        if trimPositive < 0 || trimPositive > 4000 { issues.append("正向修正上限应在 0–4000 RPM") }
        if trimNegative < 0 || trimNegative > 4000 { issues.append("负向修正上限应在 0–4000 RPM") }
        if let floor = idleFloorRPM, floor < 0 { issues.append("怠速地板不能为负") }
        if enableFeedForward && feedForward.count < 2 { issues.append("启用前馈时至少需要 2 个锚点") }
        if !curve.isEmpty {
            // 只拒绝**重复温度**（同一温度两个转速是有歧义的）；
            // 乱序是允许的 —— 插值前会统一排序（见 `normalized()`）
            let temps = curve.map(\.temp)
            if Set(temps).count != temps.count {
                issues.append("曲线中存在重复温度（同一温度只能有一个转速）")
            }
            if curve.contains(where: { $0.rpm < 0 }) { issues.append("曲线转速不能为负") }
        }
        return issues
    }
}

// MARK: - 持久化

/// 用户档位与偏好的本地存储：
/// `~/Library/Application Support/FanPilot/profiles.json`
public final class ProfileStore {
    public static let shared = ProfileStore()

    public struct Prefs: Codable {
        /// 退出 App 时是否交还系统控制。**默认 true（更安全）**：
        /// 否则用户关掉界面后可能忘了风扇还处于接管状态。
        public var releaseOnQuit: Bool = true
        /// App 启动时是否自动接管（默认否，避免开机就改风扇行为）
        public var autoTakeoverOnLaunch: Bool = false
        /// 上次用的档位
        public var lastProfileKey: String = "cool"
        /// 在 Dock 也显示图标。默认 **false**（纯菜单栏 App，不占 Dock）。
        /// 若菜单栏确实放不下，可打开此项作为保底入口。
        public var showInDock: Bool = false
        /// 启动时自动打开独立主窗口。默认 **true**：
        /// 菜单栏 popover 空间有限（内容要滚动），主窗口能一次看全。
        public var openWindowOnLaunch: Bool = true
        /// 高温通知（>100°C 持续 10s / >105°C 持续 5s / >112°C 立即）。默认开。
        public var notifyOnHighTemp: Bool = true
        /// 记录会话 CSV（`~/Library/Application Support/FanPilot/logs/`）。默认开。
        public var logToCSV: Bool = true
        /// CSV 采样间隔（秒）
        public var logInterval: Double = 5
        /// ★ 自动守护（默认**开**）：helper 常驻跑控制环，凉时被动、达到激发温度或功率门槛后自动接管。
        /// 2026-09-13 的事故证明"必须手动点按钮"是不可接受的默认值。
        public var autoGuard: Bool = true
        /// 守护用的档位（cool=目标88°C / maxCool=目标82°C）
        public var guardProfile: String = "cool"
    }

    public private(set) var profiles: [CustomProfileData] = []
    public var prefs = Prefs()

    public let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("profiles.json") }

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FanPilot", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let firstRun = !FileManager.default.fileExists(atPath: fileURL.path)
        load()
        if firstRun { save() }      // 首次运行就落盘，用户能直接看到/编辑这份配置
    }

    private struct Stored: Codable {
        var prefs: Prefs
        var profiles: [CustomProfileData]
    }

    public func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            profiles = [CustomProfileData()]     // 首次运行给一个默认自定义档
            return
        }
        prefs = stored.prefs
        profiles = stored.profiles.isEmpty ? [CustomProfileData()] : stored.profiles
    }

    public func save() {
        let stored = Stored(prefs: prefs, profiles: profiles)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(stored) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 把用户档位转成控制引擎使用的完整档位定义（由 ControlEngine 侧扩展完成）
    public func profile(named name: String) -> CustomProfileData? {
        profiles.first { $0.name == name }
    }

    /// 新增或覆盖同名档位，并落盘
    public func upsert(_ profile: CustomProfileData) {
        if let i = profiles.firstIndex(where: { $0.name == profile.name }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    public func remove(named name: String) {
        profiles.removeAll { $0.name == name }
        if profiles.isEmpty { profiles = [CustomProfileData()] }
        save()
    }
}
