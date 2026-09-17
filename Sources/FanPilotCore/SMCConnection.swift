import Foundation
import IOKit

/// AppleSMC 连接：**唯一**的 SMC 读取/写入入口。
///
/// 协议要点（全部为本机实测结论，详见 Docs/M4Max-SensorMap.md §8）：
///  1. `IOServiceOpen("AppleSMC", 0)`，命令走 `IOConnectCallStructMethod(conn, 2, ...)`
///  2. 键总数：命令 7 的返回值写在 `[44:48]`，按 **大端** UInt32 解码
///  3. 按键索引取键名（命令 8）：返回的 4 字节是**反序**的
///  4. 读值两步：命令 9 取 dataSize/dataType，命令 5 读，且必须**预置 dataSize = 32**
///  5. 写入（命令 6）在无 root 时返回 `result=0x00` **但被静默丢弃** → 必须回读校验
public final class SMCConnection {
    private var conn: io_connect_t = 0
    private let lock = NSLock()          // SMC 通道必须串行化

    private let cmdReadKey: UInt8 = 5
    private let cmdWriteKey: UInt8 = 6
    private let cmdKeyCount: UInt8 = 7
    private let cmdKeyFromIndex: UInt8 = 8
    private let cmdKeyInfo: UInt8 = 9
    private let kernelIndexSMC: UInt32 = 2

    public init() throws {
        guard let matching = IOServiceMatching("AppleSMC") else { throw SMCError.serviceNotFound }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed(kernReturn: kr) }
    }

    /// 仅测试用：不建立真实连接
    private init(placeholder: Void) {}

    static func __placeholder() -> SMCConnection { SMCConnection(placeholder: ()) }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    // MARK: - 底层调用

    private func call(_ input: SMCKeyDataBuffer) throws -> SMCKeyDataBuffer {
        lock.lock(); defer { lock.unlock() }
        var inBytes = input.raw
        var outBytes = [UInt8](repeating: 0, count: SMCKeyDataBuffer.size)
        var outSize = SMCKeyDataBuffer.size
        let kr = IOConnectCallStructMethod(conn, kernelIndexSMC,
                                           &inBytes, SMCKeyDataBuffer.size,
                                           &outBytes, &outSize)
        guard kr == KERN_SUCCESS else { throw SMCError.callFailed(kernReturn: kr) }
        return SMCKeyDataBuffer(raw: outBytes)
    }

    // MARK: - 枚举

    public var keyCount: Int {
        var input = SMCKeyDataBuffer(); input.data8 = cmdKeyCount
        guard let out = try? call(input) else { return 0 }
        let n = Int(out.keyCountBigEndian)
        return (n > 16 && n < 1_000_000) ? n : 0
    }

    public func key(at index: Int) -> String? {
        var input = SMCKeyDataBuffer()
        input.data8 = cmdKeyFromIndex
        input.data32 = UInt32(index)
        guard let out = try? call(input) else { return nil }
        let k = out.keyAtReversed
        guard k != "\0\0\0\0", k.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) else { return nil }
        return k
    }

    public func allKeys() -> [String] {
        let n = keyCount
        var out: [String] = []
        out.reserveCapacity(n)
        for i in 0..<n { if let k = key(at: i) { out.append(k) } }
        return out
    }

    // MARK: - 键信息与取值

    /// ★ 串行化所有 SMC 调用。
    /// AppleSMC 的 user client 不保证并发调用安全，而且 `read()` 是
    /// **keyInfo + read 两步**，两个线程交叉会拿到配错对的 size/type。
    /// （helper 里控制线程与 socket 线程都会读写 SMC。）
    private let ioLock = NSRecursiveLock()

    public func keyInfo(_ key: String) throws -> (size: Int, type: SMCDataType) {
        ioLock.lock(); defer { ioLock.unlock() }
        var input = SMCKeyDataBuffer()
        input.key = key
        input.data8 = cmdKeyInfo
        let out = try call(input)
        return (Int(out.dataSize), SMCDataType(code: out.dataTypeCode))
    }

    public func read(_ key: String) throws -> Double? {
        ioLock.lock(); defer { ioLock.unlock() }
        let (size, type) = try keyInfo(key)
        guard size > 0, size <= SMCKeyDataBuffer.payloadSize else { throw SMCError.keyNotFound(key) }
        var input = SMCKeyDataBuffer()
        input.key = key
        input.data8 = cmdReadKey
        input.dataSize = UInt32(SMCKeyDataBuffer.payloadSize)   // ★ 不预置会得到 result=0x89
        let out = try call(input)
        return SMCCodec.decode(type: type, size: size, bytes: Array(out.payload.prefix(size)))
    }

    public func readRaw(_ key: String) throws -> (type: SMCDataType, bytes: [UInt8]) {
        ioLock.lock(); defer { ioLock.unlock() }
        let (size, type) = try keyInfo(key)
        var input = SMCKeyDataBuffer()
        input.key = key
        input.data8 = cmdReadKey
        input.dataSize = UInt32(SMCKeyDataBuffer.payloadSize)
        let out = try call(input)
        return (type, Array(out.payload.prefix(max(size, 0))))
    }

    /// 底层写入。**不要直接用它做风扇控制** —— 用 `FanActuator`（它带回读校验）。
    /// 返回 result 字节；注意 **0x00 也可能意味着"被静默丢弃"**。
    @discardableResult
    func writeRaw(_ key: String, payload: [UInt8]) throws -> UInt8 {
        ioLock.lock(); defer { ioLock.unlock() }
        var input = SMCKeyDataBuffer()
        input.key = key
        input.data8 = cmdWriteKey
        input.dataSize = UInt32(payload.count)
        input.payload = payload
        let out = try call(input)
        return out.result
    }
}
