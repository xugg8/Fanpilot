import Foundation

/// 会话 CSV 记录器 —— 把 FanPilot 看到的一切按固定列写成 CSV，供以后分析/对比。
///
/// 设计要点：
///   · **按天分文件**：`fanpilot-YYYY-MM-DD.csv`，跨天自动换文件（长跑不丢数据）；
///   · **固定列 + 固定小数位**：便于 pandas / Excel / `~/thermal_report.py` 直接读；
///   · 采样**限频**（默认 5s），避免 2s 的 UI 刷新把文件写爆；
///   · 事件（接管/交还/高温）单独写一行，`event` 列非空 —— 时间轴上能和温度对齐；
///   · 写入用 `FileHandle` 追加 + 立即 `synchronize()`，崩溃也不丢已写的行。
public final class SessionLog {

    /// 一行采样。字段全部可选 —— 读不到就留空，绝不用 0 冒充（0 会被误读成真实值）。
    public struct Sample {
        public var hotspot: Double?
        /// 即时值（未做峰值保持）——与 hotspot 并排记录，
        /// 以后回看 CSV 就能直接看出"抖动是传感器造成的还是真降温"
        public var hotspotRaw: Double?
        public var peak: Double?
        public var fanRPM: [Double]
        public var fanTargets: [Double]
        public var modes: [Double]
        public var power: Double?
        public var gpu: Double?
        public var memUsedGB: Double?
        public var memTotalGB: Double?
        public var load1: Double?
        public var controlling: Bool
        public var helper: String

        public init(hotspot: Double? = nil, hotspotRaw: Double? = nil, peak: Double? = nil,
                    fanRPM: [Double] = [], fanTargets: [Double] = [], modes: [Double] = [],
                    power: Double? = nil, gpu: Double? = nil,
                    memUsedGB: Double? = nil, memTotalGB: Double? = nil,
                    load1: Double? = nil, controlling: Bool = false, helper: String = "") {
            self.hotspot = hotspot; self.hotspotRaw = hotspotRaw; self.peak = peak
            self.fanRPM = fanRPM; self.fanTargets = fanTargets; self.modes = modes
            self.power = power; self.gpu = gpu
            self.memUsedGB = memUsedGB; self.memTotalGB = memTotalGB
            self.load1 = load1; self.controlling = controlling; self.helper = helper
        }
    }

    public static let header = "time,epoch,event,hotspot_c,peak_c,fan0_rpm,fan1_rpm,"
        + "fan0_target,fan1_target,fan0_mode,fan1_mode,power_w,gpu_pct,"
        + "mem_used_gb,mem_total_gb,load1,controlling,helper,hotspot_raw_c"

    public let directory: URL
    /// 两次采样之间最短间隔
    public var minInterval: TimeInterval
    /// 关闭后不再写（UI 开关）
    public var enabled: Bool

    private var lastWrite: Date?
    private var handle: FileHandle?
    private var openedDay: String?
    private let fm = FileManager.default
    private let lock = NSLock()

    public init(directory: URL, minInterval: TimeInterval = 5, enabled: Bool = true) {
        self.directory = directory
        self.minInterval = minInterval
        self.enabled = enabled
    }

    /// 默认目录：`~/Library/Application Support/FanPilot/logs`
    public static func defaultDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FanPilot/logs", isDirectory: true)
        return base
    }

    // MARK: - 写

    /// 事件行（接管 / 交还 / 高温 / 错误）。**不受 minInterval 限制**。
    public func event(_ text: String, now: Date = Date()) {
        guard enabled else { return }
        write(fields: Self.eventFields(text: text, now: now))
    }

    /// 采样行（受 minInterval 限频）。返回是否真的写了。
    @discardableResult
    public func sample(_ s: Sample, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        if let last = lastWrite, now.timeIntervalSince(last) < minInterval { return false }
        write(fields: Self.sampleFields(s, now: now))
        lastWrite = now
        return true
    }

    /// 当天文件路径（即使还没写过也能算出来，供「导出」按钮用）
    public func fileURL(for date: Date = Date()) -> URL {
        directory.appendingPathComponent("fanpilot-\(Self.dayString(date)).csv")
    }

    public func flush() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.synchronize()
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        openedDay = nil
    }

    // MARK: - 内部

    private func write(fields: [String]) {
        lock.lock(); defer { lock.unlock() }
        do {
            let h = try ensureHandle()
            let line = fields.map(Self.escape).joined(separator: ",") + "\n"
            try h.write(contentsOf: Data(line.utf8))
            try h.synchronize()
        } catch {
            // 记录失败不能影响控制/UI：静默降级（下次 ensureHandle 会重试）
            handle = nil
        }
    }

    private func ensureHandle() throws -> FileHandle {
        let day = Self.dayString(Date())
        if let h = handle, openedDay == day { return h }
        try? handle?.close()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL()
        let isNew = !fm.fileExists(atPath: url.path)
        if isNew {
            try (Self.header + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        openedDay = day
        return h
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    /// 空值 → 空字段（不是 0！）。数字统一 1 位小数。
    static func num(_ v: Double?, decimals: Int = 1) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(decimals)f", v)
    }

    static func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    static func sampleFields(_ s: Sample, now: Date) -> [String] {
        func at(_ a: [Double], _ i: Int) -> Double? { i < a.count ? a[i] : nil }
        return [
            timeString(now), String(Int(now.timeIntervalSince1970)), "",
            num(s.hotspot), num(s.peak),
            num(at(s.fanRPM, 0), decimals: 0), num(at(s.fanRPM, 1), decimals: 0),
            num(at(s.fanTargets, 0), decimals: 0), num(at(s.fanTargets, 1), decimals: 0),
            num(at(s.modes, 0), decimals: 0), num(at(s.modes, 1), decimals: 0),
            num(s.power, decimals: 0), num(s.gpu, decimals: 0),
            num(s.memUsedGB), num(s.memTotalGB), num(s.load1, decimals: 2),
            s.controlling ? "1" : "0", s.helper, num(s.hotspotRaw),
        ]
    }

    static func eventFields(text: String, now: Date) -> [String] {
        // 事件行：时间/epoch/event 有值，其余留空（列数必须与 header 一致）
        var f = [timeString(now), String(Int(now.timeIntervalSince1970)), text]
        f.append(contentsOf: Array(repeating: "", count: 16))
        return f
    }
}
