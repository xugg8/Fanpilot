import Foundation

/// AppleSMC 的 `SMCKeyData_t` 访问层。
///
/// ## 为什么不直接用 Swift struct
/// 最初用 Swift struct 镜像 C 结构体，结果 `MemoryLayout.size` 得到 **76 而非 80**
/// （Swift 的尾部对齐规则与 C 不同）。任何偏移错误都会让内核读到垃圾命令字节，
/// 返回"看似成功"的无效结果 —— 这类 bug 极难排查。
///
/// 因此这里改为**显式 80 字节缓冲区 + 具名偏移访问器**：偏移全部写死并可由测试断言，
/// 与 Swift/C 的布局规则彻底解耦。
///
/// 偏移表（在 M4 Max / macOS 26.6.2 上逐项实测）：
/// ```
///   0  key        UInt32  四字符键名（大端字符序）
///   4  vers       6 字节
///  12  pLimitData 16 字节
///  28  dataSize   UInt32  小端
///  32  dataType   UInt32  四字符（字节反序！）
///  40  result     UInt8
///  41  status     UInt8
///  42  data8      UInt8   命令字节
///  44  data32     UInt32
///  48  bytes      32 字节 载荷
///  80  总长
/// ```
public struct SMCKeyDataBuffer {
    public static let size = 80
    public static let offsetKey = 0
    public static let offsetDataSize = 28
    public static let offsetDataType = 32
    public static let offsetResult = 40
    public static let offsetData8 = 42
    public static let offsetData32 = 44
    public static let offsetPayload = 48
    public static let payloadSize = 32

    public var raw: [UInt8]

    public init() { raw = [UInt8](repeating: 0, count: Self.size) }
    public init(raw: [UInt8]) {
        var b = raw
        if b.count < Self.size { b += [UInt8](repeating: 0, count: Self.size - b.count) }
        self.raw = Array(b.prefix(Self.size))
    }

    // MARK: 具名访问器

    /// 键名（'TC0P' 之类）。
    ///
    /// ★★ 关键认知（踩坑实录）：key 字段在内核眼里是**主机序的 UInt32 fourcc**，
    /// 不是字符数组。Apple Silicon 是小端，所以 `"FNum"` 在内存里是 `6D 75 4E 46`（反的）。
    /// 早期把它当字符数组按顺序写入 → 内核一律回 `result=0x84`（键不存在）。
    public var key: String {
        get { String(bytes: [raw[3], raw[2], raw[1], raw[0]], encoding: .ascii) ?? "????" }
        set {
            var p = Array(newValue.utf8.prefix(4))
            while p.count < 4 { p.append(0x20) }
            raw[0] = p[3]; raw[1] = p[2]; raw[2] = p[1]; raw[3] = p[0]   // 小端 UInt32
        }
    }

    public var dataSize: UInt32 {
        get { u32(28, littleEndian: true) }
        set { setU32(28, newValue, littleEndian: true) }
    }

    /// 四字符类型码。★ 内核回填的字节顺序是反的（"flt " 存成 20 74 6C 66）
    public var dataTypeCode: String {
        String(bytes: [raw[35], raw[34], raw[33], raw[32]], encoding: .ascii) ?? "????"
    }

    public var result: UInt8 { raw[40] }
    public var status: UInt8 { raw[41] }

    /// 命令字节：5=READ, 6=WRITE, 7=KEYCOUNT, 8=KEYAT, 9=KEYINFO
    public var data8: UInt8 {
        get { raw[42] }
        set { raw[42] = newValue }
    }

    public var data32: UInt32 {
        get { u32(44, littleEndian: true) }
        set { setU32(44, newValue, littleEndian: true) }
    }

    /// 键总数：命令 7 的返回值写在 [44:48]，按**大端**读（不是 data32 的小端）
    public var keyCountBigEndian: UInt32 {
        UInt32(raw[44]) << 24 | UInt32(raw[45]) << 16 | UInt32(raw[46]) << 8 | UInt32(raw[47])
    }

    /// 按键索引取键名（命令 8）的返回值：同样是主机序 UInt32，需按字符序还原
    public var keyAtReversed: String {
        String(bytes: [raw[3], raw[2], raw[1], raw[0]], encoding: .ascii) ?? "????"
    }

    public var payload: [UInt8] {
        get { Array(raw[48..<(48 + Self.payloadSize)]) }
        set {
            for i in 0..<Self.payloadSize {
                raw[48 + i] = i < newValue.count ? newValue[i] : 0
            }
        }
    }

    // MARK: 小工具

    private func u32(_ off: Int, littleEndian: Bool) -> UInt32 {
        if littleEndian {
            return UInt32(raw[off]) | UInt32(raw[off + 1]) << 8 | UInt32(raw[off + 2]) << 16 | UInt32(raw[off + 3]) << 24
        }
        return UInt32(raw[off]) << 24 | UInt32(raw[off + 1]) << 16 | UInt32(raw[off + 2]) << 8 | UInt32(raw[off + 3])
    }

    private mutating func setU32(_ off: Int, _ v: UInt32, littleEndian: Bool) {
        if littleEndian {
            raw[off] = UInt8(v & 0xFF); raw[off + 1] = UInt8(v >> 8 & 0xFF)
            raw[off + 2] = UInt8(v >> 16 & 0xFF); raw[off + 3] = UInt8(v >> 24 & 0xFF)
        } else {
            raw[off] = UInt8(v >> 24 & 0xFF); raw[off + 1] = UInt8(v >> 16 & 0xFF)
            raw[off + 2] = UInt8(v >> 8 & 0xFF); raw[off + 3] = UInt8(v & 0xFF)
        }
    }
}

/// SMC 键的数据类型：**每键不同，必须按 KEYINFO 结果编解码，绝不假设**。
public enum SMCDataType: String {
    case float = "flt "
    case sp78 = "sp78"
    case ui8 = "ui8 "
    case ui16 = "ui16"
    case ui32 = "ui32"
    case flag = "flag"
    case hex = "hex_"
    case fpe2 = "fpe2"
    case unknown = "????"

    public init(code: String) { self = SMCDataType(rawValue: code) ?? .unknown }
}

public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kernReturn: Int32)
    case callFailed(kernReturn: Int32)
    case keyNotFound(String)
    case layoutMismatch(got: Int, want: Int)
    /// ★ 关键：SMC 对**被拒绝的写入**同样返回 result=0x00，只有回读能识破
    case writeRejected(key: String, requested: Double, readBack: Double)

    public var description: String {
        switch self {
        case .serviceNotFound: return "找不到 AppleSMC 服务"
        case .openFailed(let kr): return "IOServiceOpen 失败 (kern_return=\(kr))"
        case .callFailed(let kr): return "IOConnectCallStructMethod 失败 (kern_return=\(kr))"
        case .keyNotFound(let k): return "键不存在: \(k)"
        case .layoutMismatch(let got, let want): return "SMCKeyData 缓冲区长度不符: \(got) != \(want)"
        case .writeRejected(let k, let req, let rb):
            return "写入被拒绝（回读校验失败）: \(k) 请求 \(req) 实际 \(rb)"
        }
    }
}

// MARK: - 编解码

public enum SMCCodec {
    public static func decode(type: SMCDataType, size: Int, bytes: [UInt8]) -> Double? {
        switch type {
        case .float:
            guard size >= 4, bytes.count >= 4 else { return nil }
            // ★ 载荷是**小端** float32
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case .sp78:
            guard size >= 2, bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))   // 大端 8.8 定点
            return Double(raw) / 256.0
        case .ui8:
            return bytes.count >= 1 ? Double(bytes[0]) : nil
        case .ui16:
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
        case .ui32:
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        case .fpe2:
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0   // 大端 14.2 定点
        case .flag:
            return bytes.count >= 1 ? Double(bytes[0]) : nil
        case .hex, .unknown:
            return nil
        }
    }

    public static func encode(type: SMCDataType, value: Double) -> [UInt8] {
        switch type {
        case .float:
            let bits = Float(value).bitPattern
            return [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24 & 0xFF)]
        case .ui8:
            return [UInt8(clamping: Int(value.rounded()))]
        case .ui16:
            let v = UInt16(clamping: Int(value.rounded()))
            return [UInt8(v & 0xFF), UInt8(v >> 8)]
        case .sp78:
            let u = UInt16(bitPattern: Int16(clamping: Int((value * 256).rounded())))
            return [UInt8(u >> 8), UInt8(u & 0xFF)]
        case .fpe2:
            let v = UInt16(clamping: Int((value * 4).rounded()))
            return [UInt8(v >> 8), UInt8(v & 0xFF)]
        default:
            return []
        }
    }
}
