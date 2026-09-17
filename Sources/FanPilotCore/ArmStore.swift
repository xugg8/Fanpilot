import Foundation

/// 「自动守护」的持久化状态。
///
/// 为什么需要它：早期版本的 helper **只有在你手动点「清凉 / 最强清凉」之后才会跑控制环**。
/// 结果就是 2026-09-13 那次真实事故：用户跑了本地模型，温度一路到 **104.6°C**，
/// FanPilot 的 `controlling` 一直是 0 —— 它什么都没做，直到用户手动去点按钮。
///
/// 现在改成：App 打开「自动守护」后，helper 会在**启动时就带着档位跑控制环**
/// （用 `.daily` 激发策略：凉的时候完全被动，达到激发温度或功率门槛后自动接管）。
/// 状态落盘在 root 目录，于是：
///   · 关掉 App / 关掉界面 → 守护继续；
///   · helper 崩溃被 launchd 拉起 → **自动恢复守护**（配合"启动即交还"仍是安全的）；
///   · 重启电脑 → 守护继续。
public struct ArmedState: Codable, Equatable {
    /// 档位名（cool / maxCool / custom / fixed…）
    public var profile: String
    /// 自定义档位（曲线编辑器来的），存在时优先
    public var custom: CustomProfileData?
    /// true = 忽略激发门限（一直按目标温度控，等于"常驻压制"）
    public var alwaysOn: Bool
    /// 何时开启的（诊断用）
    public var since: TimeInterval

    public init(profile: String, custom: CustomProfileData? = nil,
                alwaysOn: Bool = false, since: TimeInterval = Date().timeIntervalSince1970) {
        self.profile = profile; self.custom = custom
        self.alwaysOn = alwaysOn; self.since = since
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = (try? c.decodeIfPresent(String.self, forKey: .profile)) ?? "cool"
        custom = try? c.decodeIfPresent(CustomProfileData.self, forKey: .custom)
        alwaysOn = (try? c.decodeIfPresent(Bool.self, forKey: .alwaysOn)) ?? false
        since = (try? c.decodeIfPresent(TimeInterval.self, forKey: .since)) ?? 0
    }
}

/// 自动守护状态的读写（**纯文件操作，可单测**）
public struct ArmStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// 默认位置：root 自己的目录（helper 以 root 运行；不写用户目录）
    public static func defaultURL() -> URL {
        URL(fileURLWithPath: "/usr/local/var/fanpilot/armed.json")
    }

    public static let shared = ArmStore(fileURL: ArmStore.defaultURL())

    public var isArmed: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func load() -> ArmedState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ArmedState.self, from: data)
    }

    public func save(_ s: ArmedState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try enc.encode(s).write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
