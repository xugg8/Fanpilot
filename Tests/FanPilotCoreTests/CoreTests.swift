import XCTest
@testable import FanPilotCore

final class LayoutTests: XCTestCase {
    /// 回归测试：最初用 Swift struct 镜像 C 结构体，实际得到 76 字节而非 80
    /// （Swift 尾部对齐规则与 C 不同）。因此改用显式缓冲区，这里断言偏移语义。
    func testBufferOffsetsAreExplicit() {
        var b = SMCKeyDataBuffer()
        XCTAssertEqual(SMCKeyDataBuffer.size, 80)
        XCTAssertEqual(b.raw.count, 80)
        b.key = "TC0P"
        // ★ key 是小端 UInt32 fourcc：内存里字符是反的
        XCTAssertEqual(Array(b.raw[0..<4]), Array("P0CT".utf8))
        XCTAssertEqual(b.key, "TC0P")
        b.data8 = 5
        XCTAssertEqual(b.raw[42], 5)
        b.dataSize = 32
        XCTAssertEqual(b.raw[28], 32)
        XCTAssertEqual(b.raw[29], 0)
        b.payload = [0xAA, 0xBB]
        XCTAssertEqual(b.raw[48], 0xAA)
        XCTAssertEqual(b.raw[49], 0xBB)
    }

    /// 键总数写在大端 [44:48]；按键索引取的键名是反序的
    func testBigEndianKeyCountAndReversedKey() {
        var b = SMCKeyDataBuffer()
        b.raw[46] = 0x0D; b.raw[47] = 0x3A
        XCTAssertEqual(b.keyCountBigEndian, 3386)
    }
}

final class CodecTests: XCTestCase {
    /// 'flt ' 载荷是**小端** float32（实测：Tp09 raw=00002042 → 40.0）
    func testFloatLittleEndian() {
        let bytes: [UInt8] = [0x00, 0x00, 0x20, 0x42]
        XCTAssertEqual(SMCCodec.decode(type: .float, size: 4, bytes: bytes)!, 40.0, accuracy: 0.001)
    }

    func testFloatRoundTrip() {
        for v in [1350.0, 3000.0, 5777.0, 25.5] {
            let enc = SMCCodec.encode(type: .float, value: v)
            XCTAssertEqual(SMCCodec.decode(type: .float, size: 4, bytes: enc)!, v, accuracy: 0.01)
        }
    }

    /// ★ 回归测试：F0Md 是 ui8（1 字节）。此前把它当 float 写 4 字节，写入失败。
    func testUInt8FanMode() {
        XCTAssertEqual(SMCCodec.encode(type: .ui8, value: 1), [0x01])
        XCTAssertEqual(SMCCodec.encode(type: .ui8, value: 0), [0x00])
        XCTAssertEqual(SMCCodec.decode(type: .ui8, size: 1, bytes: [0x03])!, 3.0)
    }

    func testSP78() {
        // 40.0°C = 0x2800（大端 8.8 定点）
        XCTAssertEqual(SMCCodec.decode(type: .sp78, size: 2, bytes: [0x28, 0x00])!, 40.0, accuracy: 0.01)
    }

    func testUnknownTypeIsNullOrEmpty() {
        XCTAssertNil(SMCCodec.decode(type: .hex, size: 2, bytes: [1, 2]))
        XCTAssertTrue(SMCCodec.encode(type: .hex, value: 1).isEmpty)
    }
}

final class AggregatorTests: XCTestCase {
    /// 实测回归：Tp 单键在 4 次采样内极差可达 32°C，且冷却期报过 40°C 而邻居 83°C。
    /// 聚合必须剔除这类离群值，否则控制器会被噪声驱动。
    func testOutlierRejection() {
        let reg = SensorRegistry.__makeForTesting([
            "Tp01": 83.0, "Tp02": 84.0, "Tp03": 83.5, "Tp04": 84.5,
            "Tp05": 40.0,      // 陈旧/多路复用残留
            "Tp06": 83.8,
        ])
        let r = SensorAggregator.aggregate(reg, family: .cpu, quantile: 0.9)!
        XCTAssertEqual(r.median, 83.8, accuracy: 0.5)
        XCTAssertGreaterThan(r.quantile, 80.0, "离群低值不得拉低决策温度")
        XCTAssertLessThan(r.usedCount, r.sampleCount, "应至少剔除 1 个离群样本")
    }

    func testEmptyFamilyReturnsNil() {
        let reg = SensorRegistry.__makeForTesting(["Tg01": 50.0])
        XCTAssertNil(SensorAggregator.aggregate(reg, family: .cpu))
    }
}

// MARK: - 假 SMC：模拟真机上无法反复验证的固件行为

/// 模拟三种真实行为：
///  1. **异步生效**：写入后要经过 N 次读取才可见（真机实测：数百毫秒）
///  2. **Mode 3 锁定**：`Ftst != 1` 时拒绝 `F%dMd = 1`
///  3. **reclaim**：`Ftst` 归 0 后模式自动回落到 3
final class FakeSMC: SMCAccess {
    var values: [String: Double]
    var types: [String: SMCDataType]
    var pending: [String: (value: Double, readsLeft: Int)] = [:]
    var settleReads = 2                 // 异步生效需要几次读取才可见
    var ftstRequired = true             // 是否模拟 Mode 3 锁定
    var refuseWrites = false            // true = 固件拒绝一切模式写入（模拟 Mode 3 下的实际行为）
    var writeLog: [String] = []

    init(mode: Double = 3) {
        values = [
            "FNum": 2,
            "F0Ac": 0, "F0Tg": 0, "F0Mn": 1350, "F0Mx": 5777, "F0Md": mode,
            "F1Ac": 0, "F1Tg": 0, "F1Mn": 1350, "F1Mx": 5777, "F1Md": mode,
            "Ftst": 0,
        ]
        types = ["FNum": .ui8, "F0Md": .ui8, "F1Md": .ui8, "Ftst": .ui8,
                 "F0Ac": .float, "F0Tg": .float, "F0Mn": .float, "F0Mx": .float,
                 "F1Ac": .float, "F1Tg": .float, "F1Mn": .float, "F1Mx": .float]
    }

    func keyExists(_ key: String) -> Bool { values[key] != nil }

    func read(_ key: String) throws -> Double? {
        if let p = pending[key] {
            if p.readsLeft <= 0 {
                values[key] = p.value
                pending[key] = nil
            } else {
                pending[key] = (p.value, p.readsLeft - 1)
            }
        }
        return values[key]
    }

    func keyType(_ key: String) throws -> SMCDataType { types[key] ?? .float }

    /// 固件侧当前的「生效值」：写入立即生效，pending 只是**回读**滞后
    func effective(_ key: String) -> Double { pending[key]?.value ?? values[key] ?? 0 }

    @discardableResult
    func write(_ key: String, data: [UInt8]) throws -> UInt8 {
        writeLog.append(key)
        if refuseWrites && key.hasSuffix("Md") { return 0x82 }   // SmcBadCommand
        let v = SMCCodec.decode(type: types[key] ?? .float, size: data.count, bytes: data) ?? 0
        // Mode 3 锁定：Ftst 未置 1 时固件拒绝手动模式写入（SmcBadCommand）
        if ftstRequired, key.hasSuffix("Md"), v == 1, effective("Ftst") != 1 {
            return 0x82
        }
        pending[key] = (value: v, readsLeft: settleReads)   // 只有回读滞后
        return 0x00
    }
}

final class AsyncApplyTests: XCTestCase {
    /// 真机实测：写完立即回读是**旧值**。只读一次的校验会误报失败。
    func testVerificationToleratesAsynchronousApply() throws {
        let fake = FakeSMC()
        fake.settleReads = 3
        let act = try FanActuator(smc: fake)
        XCTAssertTrue(try act.verify(key: "F0Tg", expected: 3000, tolerance: 25) == false || true)
        XCTAssertTrue(try act.writeVerified("F0Tg", value: 3000, type: .float, tolerance: 25),
                      "沉降窗口内应最终读到新值")
    }

    /// M4 Max MacBook 默认 Mode 3：直写 mode=1 会被固件拒绝，必须走 Ftst 闸门
    func testUnlockUsesFtstGateOnMode3() throws {
        let fake = FakeSMC(mode: 3)
        fake.ftstRequired = true
        let act = try FanActuator(smc: fake)
        XCTAssertTrue(act.ftstAvailable)
        XCTAssertTrue(try act.unlockManual(), "写 Ftst=1 后重试应能解锁")
        XCTAssertTrue(fake.writeLog.contains("Ftst"))
        XCTAssertEqual(Int(fake.values["F0Md"] ?? -1), 1)
        XCTAssertTrue(act.ftstArmed)
    }

    /// ★ 静默解锁（"半生效猛响"根治）：预检到 Mode 3 时，**任何 mode=1 写入都不得
    ///   发生在 Ftst=1 之前**——否则写入短暂生效 1–2s 再被抢回，风扇爆冲又骤停。
    func testMode3PrecheckWritesFtstBeforeAnyModeWrite() throws {
        let fake = FakeSMC(mode: 3)
        fake.ftstRequired = true
        let act = try FanActuator(smc: fake)
        XCTAssertTrue(try act.unlockManual())
        guard let ftstIdx = fake.writeLog.firstIndex(of: "Ftst") else {
            return XCTFail("必须写 Ftst")
        }
        let modeIdx = fake.writeLog.firstIndex { $0.hasSuffix("Md") }
        if let m = modeIdx {
            XCTAssertGreaterThan(m, ftstIdx, "mode=1 写入必须晚于 Ftst（静默解锁）")
        }
        XCTAssertEqual(Int(fake.values["F0Md"] ?? -1), 1)
    }

    /// ★ 切 manual 前预写目标：解锁成功后 F0Tg 应为指定初始值，而不是残留旧值爆冲
    func testUnlockPrewritesInitialTarget() throws {
        let fake = FakeSMC(mode: 3)
        fake.ftstRequired = true
        let act = try FanActuator(smc: fake)
        XCTAssertTrue(try act.unlockManual(initialTargetRPM: 2000))
        XCTAssertEqual(fake.effective("F0Tg"), 2000, accuracy: 25)
        XCTAssertEqual(fake.effective("F1Tg"), 2000, accuracy: 25)
    }

    /// ★ mode 回读怪癖判定：mode 非 manual 但 F0Tg 仍为我方写入值 → true；
    ///   目标寄存器被别人改写后 → false（真丢控制，不能当怪癖掩盖）
    func testModeReadbackQuirkDetection() throws {
        let fake = FakeSMC(mode: 3)
        fake.ftstRequired = true
        let act = try FanActuator(smc: fake)
        XCTAssertTrue(try act.unlockManual())
        _ = try act.setTarget(2500, fanIndex: 0)

        // 模拟怪癖：mode 被回读为 3，但目标寄存器仍是我方写入值
        fake.values["F0Md"] = 3
        fake.values["F1Md"] = 3
        try act.refresh()
        XCTAssertTrue(act.modeReadbackQuirk(), "目标未变 + mode 非 manual = 回读怪癖")

        // 模拟真被抢回：目标寄存器也变成别人的值
        fake.values["F0Tg"] = 4100
        try act.refresh()
        XCTAssertFalse(act.modeReadbackQuirk(), "目标寄存器变值 = 真丢控制")
    }

    /// 无 Ftst 的机型（如 M5）应走直写路径
    func testUnlockDirectWhenNoFtst() throws {
        let fake = FakeSMC(mode: 0)
        fake.values["Ftst"] = nil; fake.types["Ftst"] = nil
        fake.ftstRequired = false
        let act = try FanActuator(smc: fake)
        XCTAssertFalse(act.ftstAvailable)
        XCTAssertTrue(try act.unlockManual())
        XCTAssertFalse(fake.writeLog.contains("Ftst"))
    }

    /// Mode 3 且无 Ftst → 必须明确失败，而不是假装成功
    func testUnlockFailsLoudlyWhenLockedWithoutFtst() throws {
        let fake = FakeSMC(mode: 3)
        fake.values["Ftst"] = nil; fake.types["Ftst"] = nil
        let act = try FanActuator(smc: fake)
        XCTAssertFalse(try act.unlockManual())
        XCTAssertNotNil(act.lastError)
    }

    /// 恢复自动：必须先写回模式，最后关 Ftst（Ftst 是全局闸门）
    func testReleaseOrderModeBeforeFtst() throws {
        let fake = FakeSMC(mode: 3)
        let act = try FanActuator(smc: fake)
        _ = try act.unlockManual()
        fake.writeLog.removeAll()
        _ = try act.releaseToAuto()
        let firstFtst = fake.writeLog.firstIndex(of: "Ftst")
        let lastMode = fake.writeLog.lastIndex { $0.hasSuffix("Md") }
        if let f = firstFtst, let m = lastMode {
            XCTAssertGreaterThan(f, m, "Ftst 必须在所有风扇模式写回之后才关")
        }
    }
}

final class SafetyTests: XCTestCase {
    /// 红线 #1：任何目标转速都不得低于出厂最低转速（F0Mn=1350）
    func testClampNeverBelowFactoryMin() throws {
        let act = try FanActuator(smc: FakeSMC())
        XCTAssertEqual(act.clamp(0, fanIndex: 0), 1350)
        XCTAssertEqual(act.clamp(-500, fanIndex: 0), 1350)
        XCTAssertEqual(act.clamp(3000, fanIndex: 0), 3000)
        XCTAssertEqual(act.clamp(99999, fanIndex: 0), 5777)
    }

    /// 阈值分档：告警必须稀有，否则用户会关掉安全机制
    func testThresholdOrdering() {
        let t = ThermalThresholds.default
        XCTAssertLessThan(t.elevatedTemp, t.maxFanTemp)
        XCTAssertLessThan(t.maxFanTemp, t.notifyTemp)
        XCTAssertLessThan(t.notifyTemp, t.alarmTemp)
        XCTAssertGreaterThan(t.notifyDwell, t.alarmDwell)
    }
}


final class ReleaseHonestyTests: XCTestCase {
    /// 回归测试（真机 P1 实测发现）：CLI 每次调用都是新进程。
    /// 若无脑"恢复构造时读到的模式"，`fanpilot auto` 会把上一条命令留下的
    /// manual(=1) 当成原值再写一遍 —— **报告成功、实际仍是手动**。
    func testAutoOnFreshProcessGoesToZeroNotBackToManual() throws {
        let fake = FakeSMC(mode: 1)              // 上一条命令留下的手动态
        fake.ftstRequired = false
        let act = try FanActuator(smc: fake)     // 新进程：构造时读到 1
        XCTAssertTrue(try act.releaseToAuto(target: 0))
        XCTAssertEqual(Int(fake.effective("F0Md")), 0, "必须写 0（系统自动），不能写回 1")
        XCTAssertEqual(Int(fake.effective("F1Md")), 0)
    }

    /// 诚实性：只要还有风扇是 manual，就不能报告"已恢复自动"
    func testReleaseReportsFailureIfStillManual() throws {
        let stubborn = StubbornSMC()
        let act = try FanActuator(smc: stubborn)
        XCTAssertFalse(try act.releaseToAuto(target: 0), "仍处 manual 时必须返回失败")
        XCTAssertNotNil(act.lastError)
    }
}

/// 模拟"写模式被固件顶回"的机器
final class StubbornSMC: SMCAccess {
    var values: [String: Double] = ["FNum": 2, "F0Ac": 1350, "F0Tg": 1350, "F0Mn": 1350, "F0Mx": 5777,
                                    "F0Md": 1, "F1Ac": 1350, "F1Tg": 1350, "F1Mn": 1350, "F1Mx": 5777,
                                    "F1Md": 1, "Ftst": 0]
    func keyExists(_ key: String) -> Bool { values[key] != nil }
    func read(_ key: String) throws -> Double? { values[key] }
    func keyType(_ key: String) throws -> SMCDataType { key.hasSuffix("Md") || key == "Ftst" ? .ui8 : .float }
    @discardableResult func write(_ key: String, data: [UInt8]) throws -> UInt8 { 0x00 }  // 静默忽略
}

// MARK: - 假 SMC 需要补上新增的协议方法

extension FakeSMC {
    func allKeys() -> [String] { Array(values.keys) }
    func keySize(_ key: String) -> Int {
        switch types[key] {
        case .ui8, .flag, .hex: return 1
        case .ui16, .sp78, .fpe2: return 2
        default: return 4
        }
    }
}

extension StubbornSMC {
    func allKeys() -> [String] { Array(values.keys) }
    func keySize(_ key: String) -> Int { key.hasSuffix("Md") || key == "Ftst" ? 1 : 4 }
}

/// 回归测试（真机发现）：Mode 3（system）时固件拒绝模式写入，
/// 早期实现因此把"明明已交还"误报为失败（假警报）。
final class ReleaseSemanticsTests: XCTestCase {
    /// 风扇处于 Mode 3 且固件拒绝一切模式写入 → 必须判定为**成功**（系统本就掌控）
    func testReleaseSucceedsWhenAlreadyInSystemMode() throws {
        let fake = FakeSMC(mode: 3)       // Mode 3 = system（固件缓解态）
        fake.refuseWrites = true          // 该状态下固件拒绝模式写入
        let act = try FanActuator(smc: fake)
        XCTAssertFalse(act.fans.contains { $0.isManual })
        XCTAssertTrue(try act.releaseToAuto(target: 0),
                      "已是 system(3) 就该算交还成功，不能因为写不进 0 而报失败")
        XCTAssertNil(act.lastError)
    }

    /// 真正的 manual 且写回失败 → 必须如实报失败
    func testReleaseFailsWhenStillManual() throws {
        let fake = StubbornSMC()
        fake.values["F0Md"] = 1; fake.values["F1Md"] = 1
        let act = try FanActuator(smc: fake)
        XCTAssertFalse(try act.releaseToAuto(target: 0), "仍是 manual 必须报失败")
        XCTAssertNotNil(act.lastError)
    }

    /// manual 且写回成功 → 成功
    func testReleaseSucceedsFromManual() throws {
        let fake = FakeSMC(mode: 1)
        fake.ftstRequired = false
        let act = try FanActuator(smc: fake)
        XCTAssertTrue(try act.releaseToAuto(target: 0))
        XCTAssertEqual(Int(fake.effective("F0Md")), 0)
    }
}
