import Foundation

/// 传感器族定义与**排除表**。
///
/// 排除表不是猜的：`Tf06/16/26/36/46` 在本机恒定在 97–116°C，`TVMX/TVMx/TVmS/TVms/TVxx`
/// 恒定 56.0°C —— 它们在 GPU/内存双相负载标定中**完全不动**。
/// 若把它们计入"取最大值"，风扇会永久 100%，而且看起来一切正常。
public enum SensorFamily: String, CaseIterable {
    case cpu = "Tp"          // CPU 核心簇
    case gpu = "Tg"          // GPU 簇
    case memory = "TCM"      // 内存/缓存
    case powerDelivery = "TCD"
    case vrm = "TVV"
    case efficiency = "Te0"
    case aux = "Tex"
    case battery = "TB0"
    case board = "TD0"
    case ambient = "Ta0"
    case unknownF = "Tf"
    case sensorBank0 = "Ts0"
}

public struct KeyRecord {
    public let key: String
    public let size: Int
    public let type: SMCDataType
    public var lastValue: Double?
    public var spread: Double = 0        // 观测到的极差（噪声谱）
    public var responsive: Bool = true   // 是否随负载变化
}

public final class SensorRegistry {
    public private(set) var records: [String: KeyRecord] = [:]

    /// ★★ 线程安全锁 ★★
    /// 崩溃教训（2026-09-13，真机跑了本地模型）：
    ///   控制线程 `ControlRunner.run → hub.snapshot() → poll()`
    ///   与 socket 线程 `HelperCore.status() → hub.snapshot() → poll()`
    ///   **同时遍历并写入同一个 Dictionary** → 内存损坏 → SIGABRT（Abort trap: 6）。
    ///   崩溃报告里的栈就是 `SensorRegistry.poll() ← SMCSensorHub.snapshot() ← ControlRunner.run`。
    ///   后果极严重：helper 每 60–90 秒崩一次 → launchd 拉起 → 启动即交还系统（红线 #8）
    ///   → 用户看到"点了最强清凉，风扇转一分钟就停，温度继续升"。
    private let lock = NSRecursiveLock()

    /// 在参考机型（M4 Max MacBook Pro 16"）上实测确认"恒定不变、必须排除"的键。
    ///
    /// ⚠️ **这不是通用名单**：其它机型可能有**不同的**恒定无效键，
    /// 而本名单里的键在别处可能反而是有效传感器。
    /// 因此这里是"已知坏键"（避免它们在参考机型上污染判据），
    /// 真正的通用防线是 `SensorAggregator` 的**运行时离群剔除**
    /// （与同族中位数偏离 >15°C 的样本一律丢弃）——它对任何机型都生效。
    public static let knownBogusOnReferenceModel: Set<String> = [
        "Tf06", "Tf16", "Tf26", "Tf36", "Tf46",
        "TVMX", "TVMx", "TVmS", "TVms", "TVxx",
        "TVMD", "TVmd",
        "Ta01", "Ta05", "Ta09", "Ta0L", "Ta0P", "Ta0S",
    ]

    private let smc: SMCAccess?

    public init(smc: SMCAccess, includeFamilies: Set<String>? = nil) throws {
        self.smc = smc
        _ = includeFamilies
        let families = includeFamilies ?? Set(SensorFamily.allCases.map(\.rawValue))
        for key in smc.allKeys() {
            guard key.hasPrefix("T") || key.hasPrefix("t") else { continue }
            guard !Self.knownBogusOnReferenceModel.contains(key) else { continue }
            guard families.contains(where: { key.hasPrefix($0) }) else { continue }
            let size = smc.keySize(key)
            guard size > 0, size <= 32 else { continue }
            guard let type = try? smc.keyType(key), type == .float || type == .sp78 else { continue }
            records[key] = KeyRecord(key: key, size: size, type: type)
        }
    }

    public func family(of key: String) -> SensorFamily? {
        SensorFamily.allCases.first { key.hasPrefix($0.rawValue) }
    }

    /// 偏离同族中位数 >25°C 的键。
    ///
    /// ⚠️ **不能据此判定"无效"**：真实热点核（如本机 Tp23/Tp1o）本来就比同族中位数高
    /// 20–30°C。区分"真热点"与"假读数"只能靠**响应性**（见 `fanpilot doctor` 的加载脉冲测试）。
    /// 本方法仅用于列出"值得留意的键"。
    public func keysFarFromFamilyMedian(_ threshold: Double = 25) -> [String] {
        var out: [String] = []
        // 审核修复：走持锁副本，杜绝绕锁直读（与 fansSnapshot 同一批次的竞态清理）
        let snapshot = recordsSnapshot()
        for family in SensorFamily.allCases {
            let vals = snapshot.values
                .filter { $0.key.hasPrefix(family.rawValue) && $0.lastValue != nil }
                .map { ($0.key, $0.lastValue!) }
            guard vals.count >= 3 else { continue }
            let sorted = vals.map(\.1).sorted()
            let median = sorted[sorted.count / 2]
            for (k, v) in vals where abs(v - median) > threshold { out.append(k) }
        }
        return out.sorted()
    }

    /// 仅测试用：注入固定值，不接触 SMC
    public static func __makeForTesting(_ values: [String: Double]) -> SensorRegistry {
        let reg = SensorRegistry(unsafeEmpty: ())
        for (k, v) in values {
            reg.records[k] = KeyRecord(key: k, size: 4, type: .float, lastValue: v)
        }
        return reg
    }

    private init(unsafeEmpty: Void) {
        self.smc = nil
    }

    /// 采集一轮：更新每个键的值与观测极差
    public func poll() {
        lock.lock(); defer { lock.unlock() }
        guard let smc else { return }

        // 先在**本地副本**上改，最后一次赋值 —— 避免"边遍历边写自身"
        var updated = records
        for (k, var rec) in records {
            guard let v = try? smc.read(k), v > 0, v < 200 else { continue }
            if let prev = rec.lastValue {
                rec.spread = max(rec.spread, abs(v - prev))
            }
            rec.lastValue = v
            updated[k] = rec
        }
        records = updated
    }

    /// 取一份**快照副本**（持锁）。聚合器在副本上算，就不可能与 poll 抢同一个 Dictionary。
    public func recordsSnapshot() -> [String: KeyRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }
}

/// 稳健聚合：解决 `Tp*` 单键噪声（实测 4 次采样内极差可达 **32°C**）。
///
/// 策略：丢弃与同族中位数偏离超过 `outlierBand` 的样本 → 取分位数（默认 p90）。
/// **不要用 max**：SMC 多路复用会偶发陈旧高值，会误触发安全动作。
public enum SensorAggregator {
    public struct Result {
        public let family: SensorFamily
        public let median: Double
        public let quantile: Double
        public let sampleCount: Int
        public let usedCount: Int
        public let spread: Double
    }

    /// 小族不做离群剔除的样本数门槛
    public static let minCountForOutlierFilter = 5

    public static func aggregate(_ registry: SensorRegistry,
                                 family: SensorFamily,
                                 quantile q: Double = 0.9,
                                 outlierBand: Double = 15.0) -> Result? {
        aggregate(registry.recordsSnapshot(), family: family, quantile: q, outlierBand: outlierBand)
    }

    /// 作用于**记录副本**的聚合（线程安全：调用方已持有一份不可被并发修改的副本）
    public static func aggregate(_ records: [String: KeyRecord],
                                 family: SensorFamily,
                                 quantile q: Double = 0.9,
                                 outlierBand: Double = 15.0) -> Result? {
        let vals = records.values
            .filter { $0.key.hasPrefix(family.rawValue) && $0.lastValue != nil }
            .map { $0.lastValue! }
        guard !vals.isEmpty else { return nil }
        let sorted = vals.sorted()
        let median = properMedian(sorted)
        // ★★ 只有样本足够多时才做「中位数±band」离群剔除 ★★
        //   踩过的坑（实测）：内存族 `TCM` 只有 2 个键 —— TCMz≈72°C、TCMb≈58°C，
        //   相差 16°C 刚好越过 outlierBand(15)。旧代码有两个问题：
        //     ① 偶数样本的"中位数"取 `sorted[n/2]` = **上中位数**（72），不是真中位数（65）；
        //     ② 于是 band 过滤把 58 那个键整个丢掉，usedCount=1，族值 = 72。
        //   再叠加 SMC 多路复用偶发读失败（某一轮只剩 TCMb），族值就在 72 与 58 之间反复跳，
        //   导致 hotspot 在 **79.6 ↔ 63.5°C** 之间抖 16°C（CSV 里肉眼可见）。
        //   两个键做统计离群剔除本来就没有依据，因此小族直接用全部有效读数。
        let kept: [Double]
        if sorted.count < minCountForOutlierFilter {
            kept = sorted
        } else {
            kept = sorted.filter { abs($0 - median) <= outlierBand }
        }
        let pool = kept.isEmpty ? sorted : kept
        let idx = min(pool.count - 1, max(0, Int((Double(pool.count - 1) * q).rounded())))
        return Result(family: family,
                      median: median,
                      quantile: pool[idx],
                      sampleCount: vals.count,
                      usedCount: pool.count,
                      spread: (sorted.last ?? 0) - (sorted.first ?? 0))
    }

    /// 真中位数：偶数个样本取中间两个的平均值。
    /// （旧实现 `sorted[n/2]` 在偶数样本时取上中位数，会系统性偏高 —— 对小族尤其致命。）
    public static func properMedian(_ sorted: [Double]) -> Double {
        let n = sorted.count
        guard n > 0 else { return .nan }
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
