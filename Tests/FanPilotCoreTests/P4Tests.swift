import XCTest
@testable import FanPilotCore
@testable import ControlEngine

/// P4 三件套的回归测试：高温通知策略 / 会话 CSV / 开机自启 plist
final class P4Tests: XCTestCase {

    // MARK: - 高温通知策略

    /// 100°C 必须**持续**到 10 秒才提醒（瞬时尖峰不弹通知）
    func testWarnNeedsDwell() {
        var p = TempAlertPolicy.default
        let t0 = Date()
        XCTAssertNil(p.step(temp: 101, now: t0), "刚过 100°C 不该立刻响")
        XCTAssertNil(p.step(temp: 101, now: t0.addingTimeInterval(9.9)))
        let a = p.step(temp: 101, now: t0.addingTimeInterval(10.1))
        XCTAssertEqual(a?.level, .warn)
    }

    /// 温度掉下去后计时器要清零（不然"断续偏高"会累积成一次误报）
    func testDwellResetsWhenTempDrops() {
        var p = TempAlertPolicy.default
        let t0 = Date()
        _ = p.step(temp: 101, now: t0)
        _ = p.step(temp: 95, now: t0.addingTimeInterval(6))     // 掉下去
        XCTAssertNil(p.step(temp: 101, now: t0.addingTimeInterval(11)), "重新计时，不该响")
        XCTAssertNotNil(p.step(temp: 101, now: t0.addingTimeInterval(21.5)))
    }

    /// 105°C 只要 5 秒 → critical；且同一次高温只发一条（由高到低只发最高级）
    func testCriticalIsFasterAndOnlyOneAlert() {
        var p = TempAlertPolicy.default
        let t0 = Date()
        _ = p.step(temp: 106, now: t0)
        let a = p.step(temp: 106, now: t0.addingTimeInterval(5.1))
        XCTAssertEqual(a?.level, .critical)
        XCTAssertNil(p.step(temp: 106, now: t0.addingTimeInterval(20)), "已锁存，不重复刷屏")
    }

    /// 112°C 立即（不等持续时长），且优先级最高
    func testEmergencyImmediate() {
        var p = TempAlertPolicy.default
        let a = p.step(temp: 112.5, now: Date())
        XCTAssertEqual(a?.level, .emergency)
    }

    /// 恢复（掉到阈值−5 以下）之后可以再次提醒 —— 长会话里两次独立高温都该通知
    func testRecoversAndCanFireAgain() {
        var p = TempAlertPolicy.default
        var now = Date()
        _ = p.step(temp: 106, now: now)
        XCTAssertNotNil(p.step(temp: 106, now: now.addingTimeInterval(5.1)))
        now = now.addingTimeInterval(30)
        _ = p.step(temp: 90, now: now)                      // 恢复
        XCTAssertNil(p.activeLevel, "恢复后不该还显示警示")
        // 冷却期（180s）内不再重复 —— 防刷屏
        _ = p.step(temp: 106, now: now.addingTimeInterval(1))
        XCTAssertNil(p.step(temp: 106, now: now.addingTimeInterval(6.5)), "冷却期内抑制")
        // 过了冷却期，第二次独立高温应再次提醒
        now = now.addingTimeInterval(200)
        _ = p.step(temp: 90, now: now)
        _ = p.step(temp: 106, now: now.addingTimeInterval(1))
        let a = p.step(temp: 106, now: now.addingTimeInterval(6.5))
        XCTAssertEqual(a?.level, .critical, "冷却期过后应再次提醒")
    }

    /// cooldown 内不重复（防抖）：恢复后立刻又超温也不行
    func testCooldownBlocksRepeat() {
        var p = TempAlertPolicy.default
        var now = Date()
        _ = p.step(temp: 106, now: now)
        XCTAssertNotNil(p.step(temp: 106, now: now.addingTimeInterval(5.1)))
        now = now.addingTimeInterval(10)
        _ = p.step(temp: 90, now: now)
        _ = p.step(temp: 106, now: now.addingTimeInterval(1))
        XCTAssertNil(p.step(temp: 106, now: now.addingTimeInterval(6.5)), "冷却期内不重复")
    }

    /// 传感器全盲（temp=nil）要提醒一次，且只提醒一次
    func testBlindSensorsNotifyOnce() {
        var p = TempAlertPolicy.default
        let a = p.step(temp: nil, now: Date())
        XCTAssertNotNil(a)
        XCTAssertNil(p.step(temp: nil, now: Date().addingTimeInterval(60)))
    }

    // MARK: - 会话 CSV

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("fanpilot-logtest-\(UUID().uuidString)")
        return d
    }

    /// 表头与数据行**列数必须一致**（否则 pandas/Excel 读进来会错列）
    func testCSVColumnsMatchHeader() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = SessionLog(directory: dir, minInterval: 0)
        log.sample(SessionLog.Sample(
            hotspot: 71.2, peak: 80.0, fanRPM: [1500, 1600], fanTargets: [1400, 1500],
            modes: [0, 1], power: 88, gpu: 42, memUsedGB: 24, memTotalGB: 128,
            load1: 3.5, controlling: true, helper: "正常"))
        log.event("接管 profile=cool")
        log.close()

        let text = try String(contentsOf: log.fileURL(), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, "1 行表头 + 2 行数据")
        let want = SessionLog.header.split(separator: ",").count
        for l in lines {
            let n = l.split(separator: ",", omittingEmptySubsequences: false).count
            XCTAssertEqual(n, want, "列数不一致（\(n) vs \(want)）：\(l)")
        }
        XCTAssertTrue(lines[0].hasPrefix("time,epoch,event,hotspot_c"))
        XCTAssertTrue(lines[1].contains("71.2"))
        XCTAssertTrue(lines[1].contains(",1,正常,"))
        XCTAssertTrue(lines[2].contains("接管 profile=cool"))
    }

    /// 空值必须留空，**不能写 0**（0 会被当成真实读数）
    func testMissingValuesAreEmptyNotZero() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = SessionLog(directory: dir, minInterval: 0)
        log.sample(SessionLog.Sample(hotspot: nil, fanRPM: [1200]))
        log.close()
        let lines = try String(contentsOf: log.fileURL(), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let f = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(f[3], "", "hotspot 读不到就该是空字段")
        XCTAssertEqual(f[5], "1200", "第一台风扇有值")
        XCTAssertEqual(f[6], "", "第二台风扇读不到 → 空")
        XCTAssertEqual(f[11], "", "功率未知 → 空")
    }

    /// 限频：默认 5 秒内的第二次采样不写
    func testRateLimit() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = SessionLog(directory: dir, minInterval: 5)
        let t = Date()
        XCTAssertTrue(log.sample(SessionLog.Sample(hotspot: 70), now: t))
        XCTAssertFalse(log.sample(SessionLog.Sample(hotspot: 71), now: t.addingTimeInterval(2)))
        XCTAssertTrue(log.sample(SessionLog.Sample(hotspot: 72), now: t.addingTimeInterval(5.1)))
        // 事件行不受限频影响
        XCTAssertNoThrow(log.event("测试事件", now: t.addingTimeInterval(2.5)))
        log.close()
    }

    /// 关闭后一律不写
    func testDisabledWritesNothing() {
        let dir = tempDir()
        let log = SessionLog(directory: dir, minInterval: 0, enabled: false)
        XCTAssertFalse(log.sample(SessionLog.Sample(hotspot: 99)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.fileURL().path))
    }

    /// 含逗号/引号的事件文本要转义（否则一行裂成两列）
    func testEscaping() {
        XCTAssertEqual(SessionLog.escape("普通"), "普通")
        XCTAssertEqual(SessionLog.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(SessionLog.escape("说\"话\""), "\"说\"\"话\"\"\"")
    }

    /// 追加语义：同一个文件被第二次打开时**不能**重写表头
    func testHeaderWrittenOnce() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = SessionLog(directory: dir, minInterval: 0)
        a.sample(SessionLog.Sample(hotspot: 70)); a.close()
        let b = SessionLog(directory: dir, minInterval: 0)
        b.sample(SessionLog.Sample(hotspot: 72)); b.close()
        let text = try String(contentsOf: a.fileURL(), encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "time,epoch").count - 1, 1, "表头只应出现一次")
        XCTAssertEqual(text.split(separator: "\n").count, 3)
    }

    // MARK: - 开机自启

    /// plist 必须语法合法、可被 PropertyListSerialization 读回，且指向 /usr/bin/open
    func testLaunchAgentPlistIsValid() throws {
        let xml = LaunchAtLogin.plist(executablePath: "/Applications/FanPilot.app")
        let data = try XCTUnwrap(xml.data(using: .utf8))
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
        let d = try XCTUnwrap(obj as? [String: Any])
        XCTAssertEqual(d["Label"] as? String, "com.fanpilot.app")
        XCTAssertEqual(d["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(d["KeepAlive"] as? Bool, false)
        XCTAssertEqual(d["LimitLoadToSessionType"] as? String, "Aqua")
        let args = try XCTUnwrap(d["ProgramArguments"] as? [String])
        XCTAssertEqual(args.first, "/usr/bin/open", "走 LaunchServices 启动，别直接 exec bundle 内二进制")
        XCTAssertEqual(args.last, "/Applications/FanPilot.app")
    }

    /// 只接受 .app 包（否则报错而不是默默写一个坏 plist）
    func testEnableRejectsNonBundle() {
        let exe = URL(fileURLWithPath: "/tmp/fanpilot-not-a-bundle")
        XCTAssertThrowsError(try LaunchAtLogin.enable(appURL: exe, home: tempDir()))
    }

    /// enable → 状态可读 → disable 完整往返（全部落在临时 HOME 里，不碰真实 LaunchAgents）
    func testEnableDisableRoundTrip() throws {
        let home = tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertFalse(LaunchAtLogin.isEnabled(in: home))
        try LaunchAtLogin.enable(appURL: URL(fileURLWithPath: "/tmp/FanPilot.app"), home: home)
        XCTAssertTrue(LaunchAtLogin.isEnabled(in: home))
        XCTAssertEqual(LaunchAtLogin.registeredAppPath(home: home), "/tmp/FanPilot.app")
        XCTAssertTrue(LaunchAtLogin.statusText(home: home).contains("/tmp/FanPilot.app"))
        XCTAssertTrue(LaunchAtLogin.disable(home: home))
        XCTAssertFalse(LaunchAtLogin.isEnabled(in: home))
    }
}

// MARK: - 传感器聚合抖动（实测发现，非推测）

/// `TCM` 族只有 2 个键：TCMz≈72°C、TCMb≈58°C（相差 16°C > outlierBand 15）。
/// 旧代码在偶数样本时取**上中位数**，再用 band 把另一个键剔掉 → 族值随读成功与否在 72/58 之间跳，
/// 导致 hotspot 实测在 79.6 ↔ 63.5 之间抖动 16°C（CSV 里肉眼可见）。
final class SensorStabilityTests: XCTestCase {

    func testProperMedianForEvenCount() {
        XCTAssertEqual(SensorAggregator.properMedian([58, 72]), 65, accuracy: 0.001)
        XCTAssertEqual(SensorAggregator.properMedian([1, 2, 3, 4]), 2.5, accuracy: 0.001)
        XCTAssertEqual(SensorAggregator.properMedian([1, 2, 3]), 2, accuracy: 0.001)
    }

    /// 小族（<5 个样本）不许做离群剔除：两个键都是真实传感器，没有统计依据说谁是离群
    func testSmallFamilyKeepsAllKeys() {
        let reg = SensorRegistry.__makeForTesting(["TCMz": 72.0, "TCMb": 58.0])
        let r = SensorAggregator.aggregate(reg, family: .memory)!
        XCTAssertEqual(r.sampleCount, 2)
        XCTAssertEqual(r.usedCount, 2, "两个键都必须采用（旧代码只采用 1 个）")
        XCTAssertEqual(r.median, 65.0, accuracy: 0.001, "真中位数 65，不是上中位数 72")
        XCTAssertEqual(r.quantile, 72.0, accuracy: 0.001)
    }

    /// 大族仍然要剔除离群值（旧行为不能退化）
    func testLargeFamilyStillRejectsOutlier() {
        let reg = SensorRegistry.__makeForTesting([
            "Tp01": 83.0, "Tp02": 84.0, "Tp03": 83.5, "Tp04": 84.5, "Tp05": 40.0, "Tp06": 83.8,
        ])
        let r = SensorAggregator.aggregate(reg, family: .cpu)!
        XCTAssertEqual(r.median, 83.65, accuracy: 0.01)
        XCTAssertLessThan(r.usedCount, r.sampleCount)
        XCTAssertGreaterThan(r.quantile, 80.0)
    }

    /// 只有 1 个键能读到（多路复用偶发失败）时，族值必须仍是"那一个键"，不许变成 0 或 nil
    func testSingleKeyStillReported() {
        let reg = SensorRegistry.__makeForTesting(["TCMb": 58.0])
        let r = SensorAggregator.aggregate(reg, family: .memory)!
        XCTAssertEqual(r.quantile, 58.0, accuracy: 0.001)
        XCTAssertEqual(r.usedCount, 1)
    }

    // MARK: 峰值保持

    /// 上升沿无延迟：新峰值立刻生效
    func testHoldPassesRiseImmediately() {
        let h = HotspotHold(window: 8)
        let t = Date()
        XCTAssertEqual(h.update(60, now: t), 60)
        XCTAssertEqual(h.update(105, now: t.addingTimeInterval(1)), 105)
    }

    /// 单次坏读数（多路复用掉 16°C）不许让对外温度塌下去
    func testHoldIgnoresSingleDropout() {
        let h = HotspotHold(window: 8)
        let t = Date()
        _ = h.update(79.6, now: t)
        XCTAssertEqual(h.update(63.5, now: t.addingTimeInterval(2)), 79.6,
                       "单次坏读数不该让菜单栏温度掉 16°C")
    }

    /// 真实降温要在 window 秒后如实反映（不能一直卡在旧峰值）
    func testHoldReleasesAfterWindow() {
        let h = HotspotHold(window: 8)
        let t = Date()
        _ = h.update(105, now: t)
        XCTAssertEqual(h.update(70, now: t.addingTimeInterval(5)), 105, "窗口内保持")
        XCTAssertEqual(h.update(70, now: t.addingTimeInterval(9)), 70, "窗口过后如实回落")
    }

    /// 全盲时必须清空：否则会拿旧峰值冒充现状（安全红线）
    func testResetOnBlind() {
        let h = HotspotHold(window: 8)
        let t = Date()
        _ = h.update(100, now: t)
        h.reset()
        XCTAssertNil(h.update(nil, now: t.addingTimeInterval(1)))
    }

    /// isBlind 必须看**即时值**：峰值保持不能掩盖"传感器全盲"
    func testIsBlindUsesRawNotHeld() {
        var s = ThermalSnapshot(timestamp: Date())
        s.hotspotHeld = 100            // 保持着一个旧峰值
        s.cpuHot = nil; s.gpuHot = nil; s.memHot = nil; s.vrmHot = nil
        XCTAssertNil(s.hotspotRaw)
        XCTAssertTrue(s.isBlind, "即时值全空 = 盲，不许被峰值保持掩盖")
        XCTAssertEqual(s.hotspot, 100, "对外仍可短暂保持，但 isBlind 已判定为盲")
    }

    /// 不改变既有回放/测试语义：没有 hub 时 hotspot == 即时最大值
    func testHotspotFallsBackToRaw() {
        let s = ThermalSnapshot.make(power: 30, cpu: 88, gpu: 70, mem: 75, vrm: 60)
        XCTAssertNil(s.hotspotHeld)
        XCTAssertEqual(s.hotspot, 88)
        XCTAssertFalse(s.isBlind)
    }
}

// MARK: - 协议兼容：新增 hotspotRaw 不能破坏与旧 helper 的互通

final class ProtocolHotspotRawTests: XCTestCase {
    func testRoundTripKeepsBothValues() throws {
        var st = HelperStatus(ok: true)
        st.hotspot = 72.5
        st.hotspotRaw = 68.1
        let data = try JSONEncoder().encode(st)
        let back = try JSONDecoder().decode(HelperStatus.self, from: data)
        XCTAssertEqual(back.hotspot ?? 0, 72.5, accuracy: 0.001)
        XCTAssertEqual(back.hotspotRaw ?? 0, 68.1, accuracy: 0.001)
    }

    /// 旧 helper 的 JSON 里没有 hotspotRaw：必须解成 nil，且**不能**因此判定为"版本过旧"
    /// （它只是少一个可选字段，控制能力完全正常）
    func testOldHelperJSONDecodesWithoutOutdatedFlag() throws {
        let old = #"{"ok":true,"protocolVersion":2,"hotspot":70.5,"fanRPM":[1300,1400]}"#
        let o = try JSONDecoder().decode(HelperStatus.self, from: Data(old.utf8))
        XCTAssertEqual(o.hotspot ?? 0, 70.5, accuracy: 0.001)
        XCTAssertNil(o.hotspotRaw)
        XCTAssertFalse(o.helperIsOutdated, "少一个可选字段不该谎报版本过旧")
    }
}

// MARK: - 并发安全（真实崩溃的回归测试）

/// 2026-09-13 真机跑本地模型时 helper **每 60–90 秒崩一次**（SIGABRT / Abort trap: 6）。
/// 崩溃报告栈：`SensorRegistry.poll() ← SMCSensorHub.snapshot() ← ControlRunner.run()`
/// 原因：控制线程与 socket 线程（`HelperCore.status()`）**并发调用同一个 hub 的 snapshot()**，
/// 同时遍历并写入同一个 Dictionary → 内存损坏 → `doesNotRecognizeSelector` → abort。
///
/// 这个测试就是"多线程猛敲 snapshot"：**没加锁时它会崩掉整个测试进程**（不是断言失败，是进程死），
/// 加锁后必须稳定通过。任何让 hub/registry 失去锁的改动都会立刻在这里暴露。
final class ConcurrencyTests: XCTestCase {

    /// 造一个"多线程也安全"的假 SMC：内部加锁，模拟真机 IOKit 调用
    private final class LockedFakeSMC: SMCAccess {
        private let lock = NSRecursiveLock()
        private var values: [String: Double] = [:]
        private var types: [String: SMCDataType] = [:]

        init(keys: [String: (Double, SMCDataType)]) {
            for (k, v) in keys { values[k] = v.0; types[k] = v.1 }
        }
        func keyExists(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values[key] != nil }
        func keySize(_ key: String) -> Int { 4 }
        func keyType(_ key: String) throws -> SMCDataType {
            lock.lock(); defer { lock.unlock() }
            guard let t = types[key] else { throw SMCError.keyNotFound(key) }
            return t
        }
        func allKeys() -> [String] { lock.lock(); defer { lock.unlock() }; return Array(values.keys) }
        func read(_ key: String) throws -> Double? {
            lock.lock(); defer { lock.unlock() }
            // 轻微随机扰动：模拟真实传感器读数变化
            guard let v = values[key] else { return nil }
            return v + Double(Int.random(in: -20...20)) / 100.0
        }
        @discardableResult
        func write(_ key: String, data: [UInt8]) throws -> UInt8 {
            lock.lock(); defer { lock.unlock() }
            if let v = SMCCodec.decode(type: types[key] ?? .float, size: data.count, bytes: data) {
                values[key] = v
            }
            return 0
        }
    }

    /// 多个线程同时 snapshot()，持续约 1.5 秒；必须不崩、值必须合理
    func testConcurrentSnapshotsDoNotCrash() throws {
        var keys: [String: (Double, SMCDataType)] = [:]
        for i in 0..<40 { keys[String(format: "Tp%02d", i)] = (60 + Double(i % 20), .float) }
        for i in 0..<10 { keys[String(format: "Tg%02d", i)] = (55 + Double(i % 10), .float) }
        keys["TCMz"] = (72, .float); keys["TCMb"] = (58, .float)
        keys["PDTR"] = (40, .float)

        let smc = LockedFakeSMC(keys: keys)
        let hub = try SMCSensorHub(smc: smc, holdWindow: 8)

        let group = DispatchGroup()
        let bad = NSLock()
        var failures: [String] = []

        for t in 0..<8 {
            DispatchQueue.global().async(group: group) {
                let deadline = Date().addingTimeInterval(1.5)
                var n = 0
                while Date() < deadline {
                    let s = hub.snapshot()
                    n += 1
                    // 控制线程关心的不变量：热点必须落在合理范围，且与家族值一致
                    if let h = s.hotspot, !(0...200).contains(h) {
                        bad.lock(); failures.append("线程\(t) hotspot 异常: \(h)"); bad.unlock()
                    }
                    if s.cpuHot == nil && s.gpuHot == nil && s.memHot == nil {
                        bad.lock(); failures.append("线程\(t) 三族全空"); bad.unlock()
                    }
                }
                XCTAssertGreaterThan(n, 0)
            }
        }
        group.wait()
        XCTAssertTrue(failures.isEmpty, "并发快照出现异常：\(failures.prefix(5))")
    }

    /// registry 的 poll 与聚合并发：同样是不许崩（这是崩溃栈最内层）
    func testPollAndAggregateConcurrently() throws {
        var keys: [String: (Double, SMCDataType)] = [:]
        for i in 0..<60 { keys[String(format: "Tp%02d", i)] = (50 + Double(i % 30), .float) }
        let smc = LockedFakeSMC(keys: keys)
        let reg = try SensorRegistry(smc: smc)

        let group = DispatchGroup()
        for t in 0..<6 {
            DispatchQueue.global().async(group: group) {
                let deadline = Date().addingTimeInterval(1.2)
                while Date() < deadline {
                    if t % 2 == 0 { reg.poll() }
                    else { _ = SensorAggregator.aggregate(reg, family: .cpu) }
                }
            }
        }
        group.wait()
        let r = SensorAggregator.aggregate(reg, family: .cpu)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.sampleCount, 60)
    }
}

// MARK: - 自动守护（2026-09-13 事故的直接对策）

/// 事故：用户跑本地模型，温度到 104.6°C，helper 的 `controlling` 始终是 0 ——
/// 因为旧版本**只有手动点按钮才会启动控制环**。现在改为：守护状态落盘，
/// helper 启动（含崩溃被 launchd 拉起）时自动恢复。
final class AutoGuardTests: XCTestCase {

    private func tempStore() -> (ArmStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fanpilot-arm-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("armed.json")
        return (ArmStore(fileURL: url), dir)
    }

    func testEmptyByDefault() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(store.isArmed)
        XCTAssertNil(store.load())
    }

    func testSaveLoadRoundTrip() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(ArmedState(profile: "maxCool", alwaysOn: true, since: 12345))
        XCTAssertTrue(store.isArmed)
        let s = try XCTUnwrap(store.load())
        XCTAssertEqual(s.profile, "maxCool")
        XCTAssertTrue(s.alwaysOn)
        XCTAssertEqual(s.since, 12345, accuracy: 0.001)
    }

    /// 自定义档位要能一起落盘（守护用的是用户自己编的曲线）
    func testCustomProfilePersists() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var c = CustomProfileData()
        c.name = "我的曲线"; c.targetTemp = 85
        try store.save(ArmedState(profile: "custom", custom: c, alwaysOn: false))
        let s = try XCTUnwrap(store.load())
        XCTAssertEqual(s.custom?.name, "我的曲线")
        XCTAssertEqual(s.custom?.targetTemp ?? 0, 85, accuracy: 0.001)
    }

    func testClear() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(ArmedState(profile: "cool"))
        store.clear()
        XCTAssertFalse(store.isArmed)
        XCTAssertNil(store.load())
        store.clear()   // 幂等：不存在也不许抛
    }

    /// 文件被写坏（断电/半截写入）时不许崩，只当作"没开守护"
    func testCorruptFileDoesNotCrash() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{ not json".write(to: store.fileURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(store.isArmed, "文件在就算 armed…")
        XCTAssertNil(store.load(), "…但内容解析失败必须安全返回 nil")
    }

    /// 解码要能容忍缺字段（将来加字段时旧文件仍可读）
    func testLenientDecode() throws {
        let json = #"{"profile":"cool"}"#
        let s = try JSONDecoder().decode(ArmedState.self, from: Data(json.utf8))
        XCTAssertEqual(s.profile, "cool")
        XCTAssertNil(s.custom)
        XCTAssertFalse(s.alwaysOn)
    }

    /// 协议：新命令必须能编解码（App 与 helper 版本不一致时的兼容底线）
    func testArmDisarmCommandsEncode() throws {
        for cmd in [HelperCommand.arm, .disarm] {
            let r = HelperRequest(cmd: cmd, profile: "cool")
            let d = try JSONEncoder().encode(r)
            let back = try JSONDecoder().decode(HelperRequest.self, from: d)
            XCTAssertEqual(back.cmd, cmd)
            XCTAssertEqual(back.profile, "cool")
        }
    }

    /// status 必须带上守护状态（UI 顶部状态条靠它显示）
    func testStatusCarriesArmedFlag() throws {
        var st = HelperStatus(ok: true)
        st.armed = true
        st.armedProfile = "maxCool"
        let back = try JSONDecoder().decode(HelperStatus.self,
                                           from: try JSONEncoder().encode(st))
        XCTAssertTrue(back.armed)
        XCTAssertEqual(back.armedProfile, "maxCool")
        // 旧 helper 不发这个字段 → 解码为 false（而不是解码失败）
        let old = #"{"ok":true,"protocolVersion":2}"#
        let o = try JSONDecoder().decode(HelperStatus.self, from: Data(old.utf8))
        XCTAssertFalse(o.armed)
    }
}

// MARK: - helper 能力判断（决定 UI 提示"重装"还是"未开启"）

final class HelperFeaturesTests: XCTestCase {
    /// 新版 helper 上报能力 → App 认为支持自动守护
    func testNewHelperSupportsGuard() throws {
        var st = HelperStatus(ok: true)
        st.features = HelperFeatures.current
        let back = try JSONDecoder().decode(HelperStatus.self, from: try JSONEncoder().encode(st))
        XCTAssertTrue(HelperFeatures.supports(HelperFeatures.guardSupport, in: back.features))
        XCTAssertTrue(HelperFeatures.supports(HelperFeatures.threadSafeIO, in: back.features))
    }

    /// 旧版 helper（无 features 字段）→ 必须判定为"不支持"，
    /// 这样 UI 才会提示「重装 / 修复」，而不是让用户点了开关看到一句看不懂的报错
    /// （实测反馈："点亮自动守护开启后显示失败"）
    func testOldHelperDoesNotSupportGuard() throws {
        let old = #"{"ok":true,"protocolVersion":2,"hasFans":true,"fanRPM":[1300]}"#
        let st = try JSONDecoder().decode(HelperStatus.self, from: Data(old.utf8))
        XCTAssertEqual(st.features, [])
        XCTAssertFalse(HelperFeatures.supports(HelperFeatures.guardSupport, in: st.features))
        // 关键：不能因为少一个字段就谎报"协议版本过旧"（协议兼容原则）
        XCTAssertFalse(st.helperIsOutdated)
    }

    /// 空/缺省 features 也不能崩
    func testNilFeaturesSafe() {
        XCTAssertFalse(HelperFeatures.supports(HelperFeatures.guardSupport, in: nil))
        XCTAssertFalse(HelperFeatures.supports(HelperFeatures.guardSupport, in: []))
        XCTAssertFalse(HelperFeatures.supports("不存在的能力", in: HelperFeatures.current))
    }
}

// MARK: - 生效目标温度（"改了 85 为什么面板还显示 88" 的直接对策）

final class EffectiveTargetTests: XCTestCase {
    /// helper 回传真值时必须优先用它（自定义档位尤其重要：档位显示名可能就叫"清凉"）
    func testHelperValueWins() throws {
        var st = HelperStatus(ok: true)
        st.profile = "自定义"; st.targetTemp = 85; st.targetTempHeavy = 92
        let back = try JSONDecoder().decode(HelperStatus.self, from: try JSONEncoder().encode(st))
        XCTAssertEqual(back.targetTemp ?? 0, 85, accuracy: 0.001)
        XCTAssertEqual(back.targetTempHeavy ?? 0, 92, accuracy: 0.001)
    }

    /// 旧版 helper 不报这两个字段 → 必须解成 nil（UI 才能走本地兜底），且不能解码失败
    func testOldHelperWithoutTargetTemps() throws {
        let old = #"{"ok":true,"protocolVersion":2,"profile":"清凉"}"#
        let st = try JSONDecoder().decode(HelperStatus.self, from: Data(old.utf8))
        XCTAssertNil(st.targetTemp)
        XCTAssertNil(st.targetTempHeavy)
        XCTAssertEqual(st.profile, "清凉")
    }

    /// 曲线页的存在意义就是"能改到非预设值"，所以 85/92 必须能完整往返
    /// （用户实测：改成 85 后监控页仍显示 88 —— 根因是自定义档位没被守护采用）
    func testCustomProfileRoundTripKeepsNonPresetTargets() throws {
        var c = CustomProfileData()
        c.name = "自定义"; c.targetTemp = 85; c.targetTempHeavy = 92
        let back = try JSONDecoder().decode(CustomProfileData.self,
                                           from: try JSONEncoder().encode(c))
        XCTAssertEqual(back.targetTemp, 85, accuracy: 0.001)
        XCTAssertEqual(back.targetTempHeavy, 92, accuracy: 0.001)
        // 并且能变成控制引擎认的档位
        let p = ThermalProfile.from(custom: back)
        XCTAssertEqual(p.targetTemp, 85, accuracy: 0.001)
        XCTAssertEqual(p.targetTempHeavy ?? 0, 92, accuracy: 0.001)
    }

    /// 守护状态文件要能带上自定义档位快照（重装/崩溃/重启后自动恢复同一个档位）
    func testArmedStateCarriesCustomProfile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fanpilot-arm2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArmStore(fileURL: dir.appendingPathComponent("armed.json"))
        var c = CustomProfileData()
        c.targetTemp = 85; c.targetTempHeavy = 92
        try store.save(ArmedState(profile: "custom", custom: c, alwaysOn: false))
        let back = try XCTUnwrap(store.load())
        XCTAssertEqual(back.profile, "custom")
        XCTAssertEqual(back.custom?.targetTemp ?? 0, 85, accuracy: 0.001)
        XCTAssertEqual(back.custom?.targetTempHeavy ?? 0, 92, accuracy: 0.001)
    }
}
