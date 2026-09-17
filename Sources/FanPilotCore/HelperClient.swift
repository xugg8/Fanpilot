import Foundation

/// App 侧（非特权）与 helper 通信的客户端。
///
/// 设计要点：**helper 不在时不能让 App 失效** —— 所有调用失败都返回 nil/false，
/// UI 退化为"仅监控"模式并给出安装提示，而不是崩溃或卡住。
public final class HelperClient {
    private let socketPath: String
    /// 状态查询超时（要短：UI 每 2 秒轮询一次，不能让界面等）
    private let statusTimeout: TimeInterval
    /// 控制命令超时（要长：**冷机解锁走 Ftst 路径实测需 12 秒**，
    /// 早期用 3 秒超时导致"接管其实成功了、UI 却报失败"）
    private let controlTimeout: TimeInterval

    public init(socketPath: String = HelperWire.socketPath,
                statusTimeout: TimeInterval = 3.0,
                controlTimeout: TimeInterval = 30.0) {
        self.socketPath = socketPath
        self.statusTimeout = statusTimeout
        self.controlTimeout = controlTimeout
    }

    public var isHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    /// 心跳文件是否新鲜（helper 是否真的在工作）
    public var isHelperAlive: Bool {
        let p = "/tmp/fanpilot-helper.heartbeat"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              let date = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(date) < 5
    }

    /// 最近一次失败原因（errno / 阶段），用于排障
    public private(set) static var lastFailure: String = "-"

    /// 失败原因（UI 用，等价于 `Self.lastFailure`，但读起来更像属性）
    public var lastFailureText: String { Self.lastFailure }

    private func send(_ req: HelperRequest, timeout: TimeInterval? = nil) -> HelperStatus? {
        let timeout = timeout ?? (req.cmd == .status || req.cmd == .ping ? statusTimeout : controlTimeout)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        // 对端（helper）若已消失，write() 会给本进程发 SIGPIPE（默认杀进程）。
        // App 与 CLI 都可能因此"莫名其妙退出"，所以这里也要关掉。
        if fd >= 0 {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        guard fd >= 0 else { HelperClient.lastFailure = "socket() errno=\(errno)"; return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            let n = min(dst.count - 1, pathBytes.count)
            pathBytes.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<n]))
            }
            dst[dst.count - 1] = 0
        }

        // 连接超时（避免 helper 卡住时 UI 冻结）
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            HelperClient.lastFailure = "connect() errno=\(errno) path=\(socketPath)"
            return nil
        }

        let payload = HelperWire.encode(req)
        let wrote = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard wrote > 0 else {
            HelperClient.lastFailure = "write() = \(wrote) errno=\(errno)"
            return nil
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                HelperClient.lastFailure = "read() = \(n) errno=\(errno)（已收 \(buffer.count) 字节）"
                break
            }
            buffer.append(contentsOf: chunk[0..<n])
            if let nl = buffer.firstIndex(of: 0x0A) {
                let payload = Data(buffer[..<nl])
                if let st = HelperWire.decode(HelperStatus.self, from: payload) { return st }
                HelperClient.lastFailure = "解码失败（协议不兼容？收到 \(payload.count) 字节）"
                return nil
            }
        }
        return nil
    }

    // MARK: - 对外 API（全部容错）

    public func status() -> HelperStatus? { send(HelperRequest(cmd: .status), timeout: statusTimeout) }

    @discardableResult
    public func takeover(profile: String = "cool", rpm: Double? = nil, alwaysOn: Bool = false) -> HelperStatus? {
        send(HelperRequest(cmd: .takeover, rpm: rpm, profile: profile, alwaysOn: alwaysOn))
    }

    /// 下发用户自定义档位
    @discardableResult
    public func takeover(custom: CustomProfileData) -> HelperStatus? {
        send(HelperRequest(cmd: .takeover, profile: "custom", custom: custom))
    }

    @discardableResult
    public func releaseToAuto() -> HelperStatus? { send(HelperRequest(cmd: .auto)) }

    /// ★ 自动守护：让 helper 带着档位跑控制环（凉时被动，达到激发温度或功率门槛后自动接管）。
    /// 与 `takeover` 的区别是**状态会落盘**：关掉 App、helper 崩溃重启、重启电脑都会自动恢复。
    @discardableResult
    public func arm(profile: String = "cool", alwaysOn: Bool = false,
                    custom: CustomProfileData? = nil) -> HelperStatus? {
        send(HelperRequest(cmd: .arm, profile: profile, alwaysOn: alwaysOn, custom: custom))
    }

    @discardableResult
    public func disarm() -> HelperStatus? { send(HelperRequest(cmd: .disarm)) }

    /// 结果可读的错误信息（UI 直接用）
    public func diagnose() -> String {
        defer { if let f = Self.lastFailure as String?, f != "-" { } }
        if !isHelperInstalled { return "特权组件未安装（socket 不存在）" }
        if !isHelperAlive { return "特权组件未响应（心跳过期）" }
        if status() == nil { return "特权组件无响应（\(HelperClient.lastFailure)）" }
        return "正常"
    }
}
