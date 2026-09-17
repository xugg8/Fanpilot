import XCTest
@testable import FanPilotCore

/// 2026-09-15 21:27 回归：SMC 伪迹读数（idle 下单 poll 48→75+°C）被 HotspotHold
/// 放大成 8s 平台，打穿守护中位数 → 误拉满。修复 = SensorHub 源头物理合理性滤波。
final class PlausibilityFilterTests: XCTestCase {
    /// 单 poll 伪迹尖峰：48→95（0.5s）必须钳制到物理上限（48 + 8×0.5 = 52）。
    func testSinglePollGlitchIsClamped() {
        let f = PlausibilityFilter()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = f.filter(48, key: "mem", now: t0)
        let out = f.filter(95, key: "mem", now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(out!, 52, accuracy: 0.01, "伪迹尖峰必须钳到 8°C/s 物理上限")
        let back = f.filter(48, key: "mem", now: t0.addingTimeInterval(1.0))
        XCTAssertEqual(back!, 48, accuracy: 0.01, "回落不限速")
    }

    /// 真实持续升温：以 8°C/s 跟上，几秒内到达真实值 —— 滤波不牺牲真散热。
    func testRealSustainedRiseCatchesUp() {
        let f = PlausibilityFilter()
        var t = 0.0
        _ = f.filter(48, key: "gpu", now: Date(timeIntervalSince1970: t))
        var last = 48.0
        for _ in 0..<20 {                       // 10 秒真实 95°C
            t += 0.5
            last = f.filter(95, key: "gpu", now: Date(timeIntervalSince1970: t))!
        }
        XCTAssertEqual(last, 95, accuracy: 0.5, "10s 后必须跟上真实温度")
    }

    /// 族键独立：mem 的伪迹不影响 gpu 的真实读数。
    func testFamiliesAreIndependent() {
        let f = PlausibilityFilter()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = f.filter(48, key: "mem", now: t0)
        _ = f.filter(48, key: "gpu", now: t0)
        let memOut = f.filter(99, key: "mem", now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(memOut!, 52, accuracy: 0.01)
        let gpuOut = f.filter(49, key: "gpu", now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(gpuOut!, 49, accuracy: 0.01, "其它族不受 mem 伪迹影响")
    }

    /// nil（族失明）清空基线：恢复后以新读数起步，不拿旧值钳制。
    func testNilResetsBaseline() {
        let f = PlausibilityFilter()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = f.filter(48, key: "cpu", now: t0)
        _ = f.filter(nil, key: "cpu", now: t0.addingTimeInterval(0.5))
        let out = f.filter(90, key: "cpu", now: t0.addingTimeInterval(1.0))
        XCTAssertEqual(out!, 90, accuracy: 0.01, "失明恢复后新基线起步")
    }
}
