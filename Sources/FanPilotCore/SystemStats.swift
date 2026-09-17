import Foundation

/// 单个进程的资源占用
public struct ProcessUsage: Identifiable, Hashable {
    public var id: String { "\(pid)" }
    public let pid: Int
    public let name: String
    public let cpu: Double          // 百分比（可 >100，多核累加）
    public let memMB: Double
    public var memText: String {
        memMB >= 1024 ? String(format: "%.1f GB", memMB / 1024) : String(format: "%.0f MB", memMB)
    }
}

/// 系统级负载快照（App 侧本地采集，不经过 helper）
public struct SystemStats {
    public var topCPU: [ProcessUsage] = []
    public var topMem: [ProcessUsage] = []
    public var gpuUtil: Int = 0
    /// `pmset -g therm` 记录的热/性能告警（"none" 表示从未记录）
    public var thermalWarning: String = "-"
    public var perfWarning: String = "-"
    public var memUsedGB: Double = 0
    public var memTotalGB: Double = 0
    public var loadAvg: Double = 0

    public static let empty = SystemStats()

    /// 采集一次。全部为免特权读取，开销约 40–80ms（调用方应放在后台线程）。
    public static func sample() -> SystemStats {
        var s = SystemStats()
        s.loadAvg = loadAverage()

        // ① 进程 CPU：一次 ps 取全量，按 CPU 排序
        if let out = run("/bin/ps", ["-Ao", "pid,%cpu,comm"]) {
            var procs: [ProcessUsage] = []
            for line in out.split(separator: "\n").dropFirst() {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 3,
                      let pid = Int(parts[0]), let cpu = Double(parts[1])
                else { continue }
                let name = (parts[2...].joined(separator: " ") as NSString).lastPathComponent
                procs.append(ProcessUsage(pid: pid, name: name, cpu: cpu, memMB: 0))
            }
            // 排除瞬时噪声（<1% CPU），取前 5 名
            s.topCPU = procs.filter { $0.cpu >= 1.0 }.sorted { $0.cpu > $1.cpu }.prefix(5).map { $0 }
        }

        // ①b 进程内存：libproc 的 phys_footprint（与活动监视器"内存"列同口径）。
        // 2026-09-17 实锤：ps 的 RSS 不含被压缩的内存页，统一内存大模型负载 78.9G footprint
        // 时 RSS 只有 51G、重压缩时掉到 1.x G——按 RSS 排行会严重误导，故弃用。
        s.topMem = Self.topMemByFootprint(prefix: 5, minMB: 100)

        // ② GPU 利用率（免 root，ioreg）
        if let out = run("/usr/sbin/ioreg", ["-r", "-d", "1", "-c", "IOAccelerator", "-w", "0"]) {
            let vals = matches(in: out, pattern: #""(?:Device|Tiler|Renderer) Utilization %"=(\d+)"#).compactMap { Int($0) }
            s.gpuUtil = vals.max() ?? 0
        }

        // ③ 热/性能告警（macOS 自己记录的；非零说明系统认为发生过热或受限）
        if let out = run("/usr/bin/pmset", ["-g", "therm"]) {
            for line in out.split(separator: "\n") {
                let low = line.lowercased()
                if low.contains("thermal warning level") {
                    s.thermalWarning = low.contains("no thermal warning") ? "无" : String(line.split(separator: ":").last ?? "").trimmingCharacters(in: .whitespaces)
                }
                if low.contains("performance warning level") {
                    s.perfWarning = low.contains("no performance warning") ? "无" : String(line.split(separator: ":").last ?? "").trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // ④ 内存总量 / 已用：host_statistics64 直读（与活动监视器"内存使用"同口径：
        // internal 匿名页含 active+inactive + wired + 压缩器）。
        // 2026-09-17 修正：旧 vm_stat 公式 active+wired+compressed 漏掉 inactive 匿名页
        // （大模型内存降温后全部转 inactive），实测 65GB vs footprint 口径 93.8GB 自相矛盾。
        if let out = run("/usr/sbin/sysctl", ["-n", "hw.memsize"]), let total = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) {
            s.memTotalGB = total / 1_073_741_824
        }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { (p: UnsafeMutablePointer<vm_statistics64>) -> kern_return_t in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { q in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, q, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let used = Double(stats.internal_page_count + stats.wire_count + stats.compressor_page_count) * Double(vm_kernel_page_size)
            s.memUsedGB = used / 1_073_741_824
        } else if let out = run("/usr/bin/vm_stat", []) {   // 兜底（正常不会走到）
            func pages(_ key: String) -> Double {
                for line in out.split(separator: "\n") where line.contains(key) {
                    let digits = line.split(separator: ":").last.map { $0.filter { $0.isNumber } } ?? ""
                    return Double(String(digits)) ?? 0
                }
                return 0
            }
            let used = (pages("Pages active") + pages("Pages wired down") + pages("Pages occupied by compressor")) * 16384.0
            s.memUsedGB = used / 1_073_741_824
        }
        return s
    }

    // MARK: - 小工具

    /// 按 phys_footprint 取内存占用前 `prefix` 名（免特权，~µs/进程）。
    /// rusage_info_v0 布局见 sys/resource.h：ri_phys_footprint @72。
    private static func topMemByFootprint(prefix: Int, minMB: Double) -> [ProcessUsage] {
        let n0 = proc_listallpids(nil, 0)
        guard n0 > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n0) + 64)
        let n = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.stride * (Int(n0) + 64)))
        guard n > 0 else { return [] }

        var out: [ProcessUsage] = []
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, 4096) > 0 else { continue }
            var ru = rusage_info_v0()
            let rc = withUnsafeMutablePointer(to: &ru) { (p: UnsafeMutablePointer<rusage_info_v0>) -> Int32 in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { q in
                    proc_pid_rusage(pid, RUSAGE_INFO_V0, q)
                }
            }
            guard rc == 0 else { continue }
            let fpMB = Double(ru.ri_phys_footprint) / (1024 * 1024)
            guard fpMB >= minMB else { continue }
            let name = String(cString: path).split(separator: "/").last.map(String.init) ?? "?"
            out.append(ProcessUsage(pid: Int(pid), name: name, cpu: 0, memMB: fpMB))
        }
        return out.sorted { $0.memMB > $1.memMB }.prefix(prefix).map { $0 }
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    private static func loadAverage() -> Double {
        var load = [Double](repeating: 0, count: 3)
        return getloadavg(&load, 3) > 0 ? load[0] : 0
    }
}
