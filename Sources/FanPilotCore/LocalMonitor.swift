import Foundation

/// 本地只读监控：**不需要 root、不需要 helper**。
///
/// 为什么需要它：读 SMC 本身免特权，只有**写**风扇才需要 root。
/// 所以即使特权组件没安装，App 也应该能正常显示温度/转速/模式 ——
/// 否则"没装 helper 就什么都看不到"，体验和可诊断性都很差。
public final class LocalMonitor {
    private let smc: SMCConnection
    private let hub: SMCSensorHub
    private let actuator: FanActuator

    public init() throws {
        let c = try SMCConnection()
        self.smc = c
        self.hub = try SMCSensorHub(smc: c)
        self.actuator = try FanActuator(smc: c)      // 仅用于读取；本类从不写入
    }

    public func status(controlling: Bool = false, profile: String = "auto",
                       reason: String? = nil) -> HelperStatus {
        var st = HelperStatus(ok: true)
        let snap = hub.snapshot()
        st.hotspot = snap.hotspot
        st.cpuHot = snap.cpuHot; st.gpuHot = snap.gpuHot
        st.memHot = snap.memHot; st.vrmHot = snap.vrmHot
        st.power = snap.power
        try? actuator.refresh()
        let fans = actuator.fansSnapshot()
        st.fanRPM = fans.map(\.actualRPM)
        st.fanTargets = fans.map(\.targetRPM)
        st.targetRPM = fans.first?.targetRPM
        st.fanMin = fans.first?.minRPM
        st.fanMax = fans.first?.maxRPM
        st.modes = fans.map(\.mode)
        st.ftst = (try? smc.read("Ftst")) ?? nil
        st.hasFans = actuator.hasFans
        st.controlling = controlling
        st.profile = profile
        st.reason = reason ?? "只读监控（未安装特权组件）"
        return st
    }
}
