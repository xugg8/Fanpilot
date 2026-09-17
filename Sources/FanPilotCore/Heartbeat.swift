import Foundation

/// 心跳写入器（helper 存活标志，供 App/launchd 判断进程是否活着）。
///
/// 审核优化（2026-09-14）：旧实现每个心跳都 `Data.write(toFile:atomically:true)`——
/// 即"写临时文件 + rename"，每秒最多 3 处（心跳线程 1/s + ControlRunner 每 tick 2/s）。
/// 系统对该模式发出磁盘写入量告警：helper 一天脏化 2.1GB（52KB/s，超限 2 倍）。
///
/// 改为：
///  1. **原地覆写**（open → write → truncate），不再每秒产生临时文件与目录改名；
///  2. **节流**：两次真实写入间隔不小于 `minInterval`，高频调用方（控制环 tick）自动合并。
///
/// 原地写的崩溃窗口极小（最多留下半截心跳），而心跳本身是"时间戳新鲜度"语义，
/// 半截内容只会让读方判过期 → 走"helper 未响应"的安全路径，可接受。
public final class HeartbeatWriter {
    private let path: String
    private let minInterval: TimeInterval
    private var lastBeat: Date = .distantPast

    public init(path: String, minInterval: TimeInterval = 1.0) {
        self.path = path
        self.minInterval = minInterval
    }

    /// 写一次心跳；距上次真实写入不足 `minInterval` 时静默跳过。
    /// 任何失败都不抛出——心跳失败绝不能影响控制环。
    ///
    /// ★ 时钟回拨防御（单测抓出来的真实缺陷）：NTP 校时/休眠唤醒可能让
    ///   `Date()` 倒退，此时 `now - lastBeat` 为负。旧逻辑 `t >= minInterval`
    ///   恒 false → 心跳被冻结，直到墙钟追回 lastBeat 为止 —— 最坏情况
    ///   App 侧心跳过期误判 helper 死亡。规则改为：**回拨或超过间隔都写**，
    ///   只跳过"正常前进但间隔不足"的情况。
    public func beat(now: Date = Date()) {
        let dt = now.timeIntervalSince(lastBeat)
        if dt >= 0 && dt < minInterval { return }
        lastBeat = now
        writeInPlace("\(Int(now.timeIntervalSince1970))")
    }

    /// 绕过节流强制写（App 侧"立即标记存活"场景备用）
    public func forceBeat(now: Date = Date()) {
        lastBeat = now
        writeInPlace("\(Int(now.timeIntervalSince1970))")
    }

    private func writeInPlace(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: data)
            return
        }
        guard let fh = FileHandle(forWritingAtPath: path) else { return }
        defer { try? fh.close() }
        fh.seek(toFileOffset: 0)
        try? fh.write(contentsOf: data)
        try? fh.truncate(atOffset: UInt64(data.count))
    }
}
