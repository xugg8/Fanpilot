import Foundation

/// App ↔ 特权 helper 之间的协议（换行分隔的 JSON）。
///
/// 为什么用 Unix domain socket 而不是 XPC：
///  - XPC + `SMAppService` 注册特权 daemon **要求 Developer ID 签名**（付费账号），
///    自签在系统设置放行环节容易卡住（见实施计划 §6 的降险决策）；
///  - Unix socket 只需一个 `sudo` 安装的 root LaunchDaemon，完全可控、可脚本化、可测；
///  - 代价：需要自己做调用方校验 → 用 `getpeereid()` 检查对端 UID（见 helper）。
/// helper 能力标识（App 用它判断"要不要提示重装"）
public enum HelperFeatures {
    /// 自动守护（arm/disarm + 崩溃自动恢复）
    public static let guardSupport = "guard"
    /// status 里带 hotspotRaw（即时值）
    public static let hotspotRaw = "hotspotRaw"
    /// status 里带每台风扇目标转速
    public static let fanTargets = "fanTargets"
    /// 传感器/SMC/风扇读写已加锁（修掉 SIGABRT 崩溃）
    public static let threadSafeIO = "threadSafeIO"

    public static let current = [guardSupport, hotspotRaw, fanTargets, threadSafeIO]

    public static func supports(_ feature: String, in list: [String]?) -> Bool {
        (list ?? []).contains(feature)
    }
}

public enum HelperCommand: String, Codable {
    case ping
    case status          // 只读状态
    case takeover        // 接管风扇（可带 profile / rpm）
    case auto            // 交还系统
    case setRPM          // 固定转速（隐式接管）
    case arm             // ★ 自动守护：让 helper 带着档位跑控制环（凉时被动，热了自动接管）
    case disarm          // 关闭自动守护（并交还系统）
}

public struct HelperRequest: Codable {
    public var cmd: HelperCommand
    public var rpm: Double?
    public var profile: String?      // auto / cool / maxCool / custom / fixed
    public var alwaysOn: Bool?       // 忽略激发门限（调试/烤机用）
    public var handbackTemp: Double?
    /// 自定义档位（App 的曲线编辑器）—— 存在时优先于 `profile` 预设
    public var custom: CustomProfileData?

    public init(cmd: HelperCommand, rpm: Double? = nil, profile: String? = nil,
                alwaysOn: Bool? = nil, handbackTemp: Double? = nil,
                custom: CustomProfileData? = nil) {
        self.cmd = cmd; self.rpm = rpm; self.profile = profile
        self.alwaysOn = alwaysOn; self.handbackTemp = handbackTemp; self.custom = custom
    }
}

public struct HelperStatus: Codable {
    /// 协议版本：App 与 helper 版本不一致时据此提示（**不匹配也要能解码**）
    public static let currentProtocolVersion = 2
    public var protocolVersion: Int = HelperStatus.currentProtocolVersion
    public var ok: Bool
    public var message: String?
    public var ts: TimeInterval = Date().timeIntervalSince1970

    // 传感器
    public var hotspot: Double?
    /// 即时热点（未经峰值保持）。旧版 helper 不发送 → nil
    public var hotspotRaw: Double?
    public var cpuHot: Double?
    public var gpuHot: Double?
    public var memHot: Double?
    public var vrmHot: Double?
    public var power: Double?

    // 风扇
    public var fanRPM: [Double] = []
    /// 每台风扇的目标转速（与 fanRPM 一一对应）
    public var fanTargets: [Double] = []
    public var fanMin: Double?
    public var fanMax: Double?
    public var targetRPM: Double?
    public var modes: [Double] = []
    public var ftst: Double?
    /// ★ mode 回读怪癖：controlling 但 mode 读回非 manual，而 F%dTg 仍精确等于
    /// 我方最近写入值（写路径有效，转速跟手）。压测实测的 SMC 回读不一致现象，
    /// 监控端据此把"声称接管但模式非 manual"降级为提示而非告警。旧版 helper 不发送 → nil
    public var modeQuirk: Bool?

    // 状态
    /// 本机是否有可控风扇（MacBook Air 全系为 false）
    public var hasFans: Bool = true
    public var controlling: Bool = false
    /// 是否处于「自动守护」状态（helper 正在跑控制环，哪怕此刻是 passive）
    public var armed: Bool = false
    /// 守护用的档位名
    public var armedProfile: String?
    /// ★ 当前**实际生效**的目标温度 / 重载目标（来自正在跑的档位，不是预设值）。
    /// 为什么必须有：曲线页改的是"自定义档位"，与「清凉」预设互相独立，
    /// 用户在监控页看到"清凉"就以为 88 生效了 —— 实测踩到（改了 85 但面板还显示 88）。
    public var targetTemp: Double?
    public var targetTempHeavy: Double?
    /// ★ helper 的能力清单。旧版 helper 不发送 → 空数组。
    /// 为什么需要它：`armed=false` 无法区分"新版但没开守护"和"旧版根本没有守护功能"，
    /// 结果用户看到开关点了没反应却不知道为什么（实测踩到）。
    public var features: [String] = []
    public var profile: String?
    public var reason: String?
    public var helperPID: Int32?

    public var modeIsManual: Bool { modes.contains { abs($0 - 1) < 0.5 } }
    public var modeDescription: String {
        if modeIsManual { return "manual（本软件接管）" }
        if modes.contains(where: { abs($0 - 3) < 0.5 }) { return "system（固件缓解态）" }
        return "auto（系统管理）"
    }

    public init(ok: Bool, message: String? = nil) {
        self.ok = ok
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, ok, message, ts
        case hotspot, hotspotRaw, cpuHot, gpuHot, memHot, vrmHot, power
        case fanRPM, fanTargets, fanMin, fanMax, targetRPM, modes, ftst, modeQuirk
        case hasFans, controlling, armed, armedProfile, features, targetTemp, targetTempHeavy, profile, reason, helperPID
    }

    /// ★ 手工解码：**每个字段都可缺失**。
    ///
    /// 为什么必须这样：Swift 自动合成的 `init(from:)` 对**非可选字段**要求键必须存在，
    /// 否则抛 `keyNotFound` → 整个响应解码失败。
    /// 现实中 App 与 helper 是两个独立安装的二进制，**版本不一致是常态**
    /// （已实际踩到：helper 旧版没有 `fanTargets`，App 新版解码直接失败，
    ///  界面上表现为"特权组件无响应"，极易误判成权限或连接问题）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = (try? c.decodeIfPresent(Int.self, forKey: .protocolVersion))
            ?? HelperStatus.currentProtocolVersion
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? false
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        ts = (try? c.decodeIfPresent(TimeInterval.self, forKey: .ts)) ?? 0
        hotspot = try? c.decodeIfPresent(Double.self, forKey: .hotspot)
        hotspotRaw = try? c.decodeIfPresent(Double.self, forKey: .hotspotRaw)
        cpuHot = try? c.decodeIfPresent(Double.self, forKey: .cpuHot)
        gpuHot = try? c.decodeIfPresent(Double.self, forKey: .gpuHot)
        memHot = try? c.decodeIfPresent(Double.self, forKey: .memHot)
        vrmHot = try? c.decodeIfPresent(Double.self, forKey: .vrmHot)
        power = try? c.decodeIfPresent(Double.self, forKey: .power)
        fanRPM = (try? c.decodeIfPresent([Double].self, forKey: .fanRPM)) ?? []
        fanTargets = (try? c.decodeIfPresent([Double].self, forKey: .fanTargets)) ?? []
        fanMin = try? c.decodeIfPresent(Double.self, forKey: .fanMin)
        fanMax = try? c.decodeIfPresent(Double.self, forKey: .fanMax)
        targetRPM = try? c.decodeIfPresent(Double.self, forKey: .targetRPM)
        modes = (try? c.decodeIfPresent([Double].self, forKey: .modes)) ?? []
        ftst = try? c.decodeIfPresent(Double.self, forKey: .ftst)
        modeQuirk = try? c.decodeIfPresent(Bool.self, forKey: .modeQuirk)
        hasFans = (try? c.decodeIfPresent(Bool.self, forKey: .hasFans)) ?? true
        controlling = (try? c.decodeIfPresent(Bool.self, forKey: .controlling)) ?? false
        armed = (try? c.decodeIfPresent(Bool.self, forKey: .armed)) ?? false
        armedProfile = try? c.decodeIfPresent(String.self, forKey: .armedProfile)
        features = (try? c.decodeIfPresent([String].self, forKey: .features)) ?? []
        targetTemp = try? c.decodeIfPresent(Double.self, forKey: .targetTemp)
        targetTempHeavy = try? c.decodeIfPresent(Double.self, forKey: .targetTempHeavy)
        profile = try? c.decodeIfPresent(String.self, forKey: .profile)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        helperPID = try? c.decodeIfPresent(Int32.self, forKey: .helperPID)
    }

    /// helper 版本是否比 App 旧（UI 可据此提示"建议重装特权组件"）
    public var helperIsOutdated: Bool { protocolVersion < HelperStatus.currentProtocolVersion }
}

/// 换行分隔 JSON 的编解码
public enum HelperWire {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        var d = (try? JSONEncoder().encode(value)) ?? Data()
        d.append(0x0A)                     // '\n'
        return d
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) -> T? {
        let trimmed = line.drop { $0 == 0x0A || $0 == 0x0D || $0 == 0x20 }
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(trimmed))
    }

    public static let defaultSocketPath = "/var/run/fanpilot.sock"
    public static var socketPath: String {
        ProcessInfo.processInfo.environment["FANPILOT_SOCKET"] ?? defaultSocketPath
    }
}
