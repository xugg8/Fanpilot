import Foundation

/// 开机自启（登录时自动启动 App）
///
/// 为什么用 **LaunchAgent plist** 而不是 `SMAppService.mainApp`：
///   · 本项目是自签/无付费账号的早期预览版，`SMAppService` 对签名与安装位置
///     （通常要求 `/Applications`）较敏感，失败时只给一个模糊错误；
///   · LaunchAgent 完全可控、可读、可删、可脚本化验证 —— 与 helper 用
///     sudo LaunchDaemon 的取舍一致（见 Docs/FanPilot-Implementation-Plan-v2.md §6）。
///   将来上了 Developer ID，可以无痛点换成 SMAppService（接口不变）。
public enum LaunchAtLogin {

    public static let label = "com.fanpilot.app"

    /// `~/Library/LaunchAgents/com.fanpilot.app.plist`
    public static func plistURL(home: URL? = nil) -> URL {
        let h = home ?? FileManager.default.homeDirectoryForCurrentUser
        return h.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var isEnabled: Bool { isEnabled(in: nil) }

    /// 指定 home（测试用）
    public static func isEnabled(in home: URL?) -> Bool {
        FileManager.default.fileExists(atPath: plistURL(home: home).path)
    }

    /// 生成 plist 内容（**纯函数**，便于单测）
    ///
    /// 注意用 `/usr/bin/open -a` 而不是直接写可执行文件路径：
    ///   · 走 LaunchServices 启动，App 的激活策略 / 图标 / 单实例行为都正常；
    ///   · 直接 exec 一个 `LSUIElement` 的 bundle 内二进制容易出现"起了但没有 UI"。
    public static func plist(executablePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/usr/bin/open</string>
            <string>-a</string>
            <string>\(executablePath)</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><false/>
          <key>LimitLoadToSessionType</key><string>Aqua</string>
          <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
    }

    public enum LaunchError: LocalizedError {
        case notAnAppBundle(String)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notAnAppBundle(let p):
                return "开机自启需要 App 包（.app），当前路径不是：\(p)"
            case .writeFailed(let m):
                return "写入 LaunchAgent 失败：\(m)"
            }
        }
    }

    /// 开启自启。`appURL` 必须是 `.app` 包（例如 `…/build/FanPilot.app`）。
    public static func enable(appURL: URL, home: URL? = nil) throws {
        guard appURL.pathExtension == "app" else {
            throw LaunchError.notAnAppBundle(appURL.path)
        }
        let target = plistURL(home: home)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try plist(executablePath: appURL.path).write(to: target, atomically: true, encoding: .utf8)
        } catch {
            throw LaunchError.writeFailed(error.localizedDescription)
        }
        // 立刻让 launchd 认到它（不 load 也行：下次登录会读，但 load 之后可以马上验证）
        _ = run("/bin/launchctl", ["load", "-w", target.path])
    }

    /// 关闭自启：先 unload 再删 plist
    @discardableResult
    public static func disable(home: URL? = nil) -> Bool {
        let target = plistURL(home: home)
        guard FileManager.default.fileExists(atPath: target.path) else { return true }
        _ = run("/bin/launchctl", ["unload", "-w", target.path])
        do {
            try FileManager.default.removeItem(at: target)
            return true
        } catch {
            return false
        }
    }

    /// 人类可读状态（面板里显示）：从 plist 里读出被启动的 App 路径，
    /// 好让用户确认"指向的是不是当前这份 App"
    public static func statusText(home: URL? = nil) -> String {
        guard isEnabled(in: home) else { return "未开启" }
        guard let data = try? Data(contentsOf: plistURL(home: home)),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any],
              let args = dict["ProgramArguments"] as? [String] else {
            return "已开启（plist 解析失败）"
        }
        if let app = args.last, app.hasSuffix(".app") {
            return "已开启 → \(app)"
        }
        return "已开启"
    }

    /// plist 里记录的 App 路径（供 UI 判断"自启指向的是不是当前这份"）
    public static func registeredAppPath(home: URL? = nil) -> String? {
        guard let data = try? Data(contentsOf: plistURL(home: home)),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any],
              let args = dict["ProgramArguments"] as? [String],
              let app = args.last, app.hasSuffix(".app") else { return nil }
        return app
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
