import Foundation
import FanPilotCore
import ControlEngine

// ─────────────────────────────────────────────────────────────────────
// FanPilotHelper —— 以 root 运行的常驻服务（由 launchd 拉起）
//
//   · Unix domain socket（默认 /var/run/fanpilot.sock）
//   · 换行分隔 JSON 请求/响应
//   · **调用方校验**：用 getpeereid() 只接受 root 或本机登录用户（同 UID）
//   · 启动即交还给系统（红线 #8）；退出/信号/异常同样交还
//   · 心跳写文件，供外部看门狗判断存活
// ─────────────────────────────────────────────────────────────────────

let socketPath = HelperWire.socketPath
let heartbeatPath = ProcessInfo.processInfo.environment["FANPILOT_HEARTBEAT"] ?? "/tmp/fanpilot-helper.heartbeat"

func logLine(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(ts)] \(s)\n".data(using: .utf8)!)
}

// ★★ 必须忽略 SIGPIPE ★★
//   socket 对端消失（App 被强杀、CLI 退出、客户端超时主动断开）时，write() 会收到 SIGPIPE，
//   而它的**默认动作是杀死进程** —— 实测：杀掉 App 的瞬间 helper 就死于 "Broken pipe: 13"，
//   launchd 再把它拉起来（期间风扇短暂交还系统）。
//   守护进程绝不能因为"客户端走了"而死。这里忽略信号 + 每个连接 socket 再设 SO_NOSIGPIPE 双保险。
signal(SIGPIPE, SIG_IGN)

if geteuid() != 0 {
    logLine("⚠️ 未以 root 运行：可以启动，但**无法写入风扇**（读写将返回 kIOReturnNotPrivileged）")
}

let core: HelperCore
do {
    core = try HelperCore(heartbeatPath: heartbeatPath, log: logLine)
} catch {
    logLine("❌ 初始化失败：\(error)")
    exit(2)
}

// ★ 恢复「自动守护」。
//   必须在 Init 里的"启动即交还"（红线 #8）**之后**：
//   先回到安全状态，再按落盘的档位恢复守护 —— 顺序反了就等于启动瞬间偷偷接管。
//   崩溃被 launchd 拉起时也走这里，所以守护不会"一崩就撒手不管"。
core.restoreAutoGuardIfNeeded()

// 心跳线程
// 审核优化：旧实现每秒一次原子写（临时文件+rename），一天脏化 2.1GB 被系统告警。
// 改为 HeartbeatWriter 原地覆写 + 2s 间隔（App 侧新鲜度阈值 5s，仍有 >2.5x 余量）。
let heartbeatWriter = HeartbeatWriter(path: heartbeatPath, minInterval: 1.0)
Thread.detachNewThread {
    while true {
        heartbeatWriter.beat()
        Thread.sleep(forTimeInterval: 2.0)
    }
}

// 信号处理：优雅退出（交还系统）
func installSignalHandler(_ sig: Int32) {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    src.setEventHandler {
        logLine("收到信号 \(sig)，正在交还系统并退出…")
        core.shutdown()
        unlink(socketPath)
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}
var signalSources: [DispatchSourceSignal] = []
installSignalHandler(SIGTERM)
installSignalHandler(SIGINT)

// ── 建 socket ────────────────────────────────────────────────────────
unlink(socketPath)
let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard serverFD >= 0 else { logLine("❌ socket() 失败 errno=\(errno)"); exit(3) }

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

let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        bind(serverFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bindResult == 0 else {
    logLine("❌ bind 失败 errno=\(errno)（路径 \(socketPath)，可能已有实例在运行）")
    exit(4)
}
// socket 权限：0666 让普通用户 App 能连（本机单用户）；如需更严可改 0660 + 专用组
chmod(socketPath, 0o666)
guard listen(serverFD, 16) == 0 else { logLine("❌ listen 失败 errno=\(errno)"); exit(5) }

logLine("✅ helper 已就绪：socket=\(socketPath) pid=\(getpid())")

// ── 连接处理 ─────────────────────────────────────────────────────────
/// 当前控制台登录用户的 UID（/dev/console 属主）；取不到时回退 501。
@Sendable func consoleUID() -> uid_t {
    var st = stat()
    return stat("/dev/console", &st) == 0 ? st.st_uid : 501
}

func handle(_ clientFD: Int32) {
    defer { close(clientFD) }

    // ★ 调用方校验：只接受 root 或当前控制台登录用户（/dev/console 属主，动态获取，
    //   不硬编码 UID——各机器首用户 UID 不一定相同）
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    if getpeereid(clientFD, &peerUID, &peerGID) == 0 {
        let allowed = (peerUID == 0) || (peerUID == consoleUID())
        if !allowed {
            let st = HelperStatus(ok: false, message: "对端 UID \(peerUID) 未授权")
            _ = HelperWire.encode(st).withUnsafeBytes { write(clientFD, $0.baseAddress, $0.count) }
            logLine("⛔️ 拒绝来自 UID \(peerUID) 的连接")
            return
        }
    }

    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(clientFD, &chunk, chunk.count)
        if n <= 0 { return }
        buffer.append(contentsOf: chunk[0..<n])

        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<nl]
            buffer.removeSubrange(...nl)
            guard let req = HelperWire.decode(HelperRequest.self, from: Data(line)) else { continue }

            let resp: HelperStatus
            switch req.cmd {
            case .ping:
                resp = HelperStatus(ok: true, message: "pong")
            case .status:
                resp = core.status()
            case .takeover, .setRPM:
                let kind = ThermalProfileKind(rawValue: req.profile ?? "cool") ?? .cool
                logLine("▶️ 收到接管请求：profile=\(kind.rawValue) rpm=\(req.rpm.map { String($0) } ?? "-") alwaysOn=\(req.alwaysOn ?? false)")
                resp = core.takeover(profile: kind, rpm: req.rpm,
                                     alwaysOn: req.alwaysOn ?? false,
                                     handbackTemp: req.handbackTemp,
                                     custom: req.custom)
            case .auto:
                logLine("▶️ 收到交还请求（并关闭自动守护）")
                resp = core.releaseToAuto()
            case .arm:
                let kind = ThermalProfileKind(rawValue: req.profile ?? "cool") ?? .cool
                logLine("▶️ 收到自动守护请求：profile=\(kind.rawValue) alwaysOn=\(req.alwaysOn ?? false)")
                resp = core.arm(profile: kind, custom: req.custom,
                                alwaysOn: req.alwaysOn ?? false)
            case .disarm:
                logLine("▶️ 收到关闭自动守护请求")
                resp = core.disarm()
            }
            let data = HelperWire.encode(resp)
            // 循环写：write 可能只写一部分；对端已断开就安全放弃（绝不能因此崩）
            data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return }
                var off = 0
                while off < buf.count {
                    let n = write(clientFD, base + off, buf.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
        }
    }
}

while true {
    var clientAddr = sockaddr_un()
    var len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            accept(serverFD, sa, &len)
        }
    }
    guard clientFD >= 0 else {
        if errno == EINTR { continue }
        logLine("⚠️ accept 失败 errno=\(errno)")
        Thread.sleep(forTimeInterval: 0.5)
        continue
    }
    // 每个 accept 出来的 socket 单独设 SO_NOSIGPIPE（accept 不会继承该选项）
    var one: Int32 = 1
    setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    Thread.detachNewThread { handle(clientFD) }
}
