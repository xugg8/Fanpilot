import XCTest
@testable import FanPilotCore

/// HeartbeatWriter 单元测试（2026-09-14 优化配套）。
///
/// 背景：旧心跳实现（每秒最多 3 次原子写 = 临时文件 + rename）被系统发出
/// 磁盘写入量告警（2.1GB/11.5h）。新实现为「原地覆写 + 节流」，
/// 这里锁定它的三个关键行为：节流、内容正确、原地写不留垃圾文件。
final class HeartbeatTests: XCTestCase {
    private var dir: URL!
    private var path: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fanpilot-heartbeat-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("hb").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 节流：minInterval 内的连续 beat 只落盘一次
    func testThrottleCollapsesRapidBeats() throws {
        let hb = HeartbeatWriter(path: path, minInterval: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        hb.beat(now: t0)
        let first = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(Int(first), 1_000_000)

        // 10s 后再 beat —— 仍在 60s 节流窗口内，内容必须不变
        hb.beat(now: t0.addingTimeInterval(10))
        let second = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(second, first, "节流窗口内的 beat 不应写盘")
    }

    /// forceBeat 绕过节流（控制环接管/交还等关键时点要求必写）
    func testForceBeatBypassesThrottle() throws {
        let hb = HeartbeatWriter(path: path, minInterval: 60)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        hb.beat(now: t0)
        hb.forceBeat(now: t0.addingTimeInterval(1))
        let v = Int(try String(contentsOfFile: path, encoding: .utf8))!
        XCTAssertEqual(v, 2_000_001)
    }

    /// 原地覆写语义：同一 inode，不产生新文件（这是磁盘写入量优化的核心断言）；
    /// 旧实现 Data.write(atomically:) 每次都会换新 inode。
    func testInPlaceOverwriteKeepsInodeAndTrimsLength() throws {
        let hb = HeartbeatWriter(path: path, minInterval: 0)
        // 先写 8 位时间戳，再写 7 位 —— 保证"长 → 短"真实成立，才能验证截断
        let t0 = Date(timeIntervalSince1970: 10_000_000)
        hb.beat(now: t0)
        let inode1 = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as! NSNumber
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8).count, 8)

        hb.beat(now: Date(timeIntervalSince1970: 9_999_999))
        let short = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(short, "9999999", "短值写入后必须截断旧内容，不能残留长值的尾巴")

        let inode2 = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as! NSNumber
        XCTAssertEqual(inode1, inode2, "原地写必须保持同一 inode（不产生临时文件+rename）")

        // 目录里除了 hb 本身不得有任何残留（旧原子写会留下临时文件）
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(entries, ["hb"])
    }

    /// 文件被外部删除后要能自愈重建（App 侧清理 /tmp 不该弄死 helper 的心跳）
    func testRecreatesAfterExternalDelete() throws {
        let hb = HeartbeatWriter(path: path, minInterval: 0)
        let t0 = Date(timeIntervalSince1970: 4_000_000)
        hb.beat(now: t0)
        try FileManager.default.removeItem(atPath: path)
        hb.beat(now: t0.addingTimeInterval(1))
        let v = Int(try String(contentsOfFile: path, encoding: .utf8))!
        XCTAssertEqual(v, 4_000_001)
    }

    /// ★ 时钟回拨防御：NTP 校时/休眠唤醒让 Date() 倒退时，心跳绝不能被冻结。
    ///   （这个用例先于修复失败过 —— 实现用 `t >= minInterval` 判断，负数间隔
    ///   会让心跳永远不再写盘，App 侧误判 helper 死亡。）
    func testClockStepBackwardsStillWrites() throws {
        let hb = HeartbeatWriter(path: path, minInterval: 1.0)
        let t0 = Date(timeIntervalSince1970: 5_000_000)
        hb.beat(now: t0)
        // 正常前进 0.5s：在节流窗口内，不写
        hb.beat(now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "5000000")
        // 时钟回拨 5s（NTP 校时）：必须写，且内容跟着回拨后的时间走
        hb.beat(now: t0.addingTimeInterval(-5))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "4999995")
        // 回拨后正常前进：节流重新计时，窗口内不写、窗口外恢复写
        hb.beat(now: Date(timeIntervalSince1970: 4_999_995.5))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "4999995")
        hb.beat(now: Date(timeIntervalSince1970: 4_999_996.5))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "4999996")
    }
}
