# FanPilot

macOS 菜单栏风扇控制与温度监控工具，为 Apple Silicon（M 系列芯片）MacBook 设计。

FanPilot 的核心思路与常见的"手动拉风扇转速"工具不同：它是一个**常驻的自动守护**——
机器凉爽时完全不干预（风扇可以彻底停转），温度/功率超过门限时自动接管、按自定义
PID + 曲线策略控温，回落后自动交还系统。整个过程不需要人盯着。

## 特性

- 🛡 **自动守护**：被动待命，`≥80°C 或 ≥55W` 自动接管、`<50°C 且 <35W` 持续 30s 自动交还；关掉 App、helper 崩溃重启、重启电脑都会自动恢复守护
- 📉 **自定义曲线 + PID**：温度 → 转速曲线锚点可编辑，PI 控制器 + 功率前馈抢跑（负载先动、不等温度追上来）
- 📊 **实时监控**：热点/CPU/GPU/内存/VRM 温度、系统功率、风扇转速与目标、15 分钟温度实时曲线
- 🔇 **待机零噪音**：凉时彻底放手，风扇交还固件管理（实测整夜待机风扇 0 转超过 7.5 小时）
- 🧹 **传感器去伪迹**：PlausibilityFilter 限速 + 慢平台期检测 + 中值滤波三层防护，SMC 伪尖峰不会误触发风扇
- 🔧 **特权组件一条命令安装**：root LaunchDaemon 常驻守护，Unix socket 本机通信
- 🖥 **菜单栏常驻**：迷你模式只显示实时曲线，展开为完整面板

## 与同类工具对比

| | FanPilot | Macs Fan Control | TG Pro |
|---|---|---|---|
| 价格 | 免费开源 (MIT) | 免费/捐助 | $25 |
| 待机风扇 0 转 | ✅ 自动交还固件（实测整夜静音） | ❌ 需手动设最低转速 | ❌ 同左 |
| 负载自动接管 | ✅ 温度/功率双门限，无需人工 | ❌ 固定值全时段生效 | ✅ 但策略不可编辑 |
| 转速曲线+PID 编辑 | ✅ 图形化可编辑 | ❌ 仅固定转速 | 部分 |
| 菜单栏实时温度曲线 | ✅ 15 分钟迷你曲线 | ❌ 仅数字 | ❌ |
| 开源可审计 | ✅ | ❌ | ❌ |

## 截图

<p align="center">
  <img src="docs/screenshots/menu-monitor.png" width="330" alt="监控页：温度/功率/风扇与内存 Top5">
  <img src="docs/screenshots/curve-editor.png" width="285" alt="曲线页：PID 与自定义曲线编辑">
</p>

## 系统要求

- macOS 13+（Apple Silicon）
- 已安装 Swift 工具链（仅构建时需要；Xcode 或 Command Line Tools 均可）
- 目前在 M4 Max MacBook Pro（Mac16,5）上开发验证；其他机型可能需要适配传感器键与解锁流程（见 `Docs/COMPATIBILITY.md`）

## 适用机型

**完整验证：仅 MacBook Pro 16" M4 Max（`Mac16,5`）**——本项目的全部实测数据来源。
代码做了跨机型自适应（模式键大小写探测、Ftst 存在性探测、转速策略按实际风扇范围缩放、无风扇自动降级），
但其它机型属于"应该能用、未经验证"，请先跑 `fanpilot doctor` 自检并把报告贴进 issue。

| 机型 | 风扇控制 | 温度监控 |
|---|---|---|
| **MacBook Pro 16" M4 Max** | ✅ **已验证** | ✅ 已验证 |
| MacBook Pro M4 / M4 Pro / M1–M3（Pro/Max） | ⚠️ 大概率可用（需实测） | ✅ 应可用 |
| Mac mini M4 / Mac Studio / iMac | ⚠️ 理论可用（风扇数与范围不同，策略自动缩放） | ⚠️ 未知 |
| MacBook Pro M5 | ⚠️ 大概率可用（模式键为小写，代码已兼容） | ⚠️ 未知 |
| **MacBook Air（全系）** | ❌ **不适用（无风扇）**，自动降级为纯监控 | ✅ 可用 |
| **Intel Mac** | ❌ **不支持** | ❌ 不支持 |

完整矩阵与"新机型接入清单"见 [Docs/COMPATIBILITY.md](Docs/COMPATIBILITY.md)。

## 下载安装（Release 包）

1. 从 Releases 下载 `FanPilot-x.y.z-macOS-arm64.zip`，解压得到 `FanPilot.app`；
2. **首次打开**：因为签名是 ad-hoc（无 Apple 开发者账号），macOS 会提示"无法验证开发者"——
   **右键 → 打开**，或执行 `xattr -d com.apple.quarantine FanPilot.app` 后再开；
3. 按面板提示安装特权组件（需输入一次密码，安装 root LaunchDaemon）；
4. 校验完整性：Release 页附 `SHA256SUMS.txt`，下载后可执行 `shasum -a 256 FanPilot-*.zip` 比对。

## 免责声明

> **请务必阅读后再使用。**
>
> 1. FanPilot 通过 SMC 的**未公开接口**控制风扇，该机制可能随 macOS 更新失效或行为改变；
> 2. 风扇控制不当可能导致机器过热。虽然软件内置了多层安全保护（红线转速、失明保护、启动即交还、安全强制拉满），但**作者不对任何硬件损坏、数据丢失或后果承担责任**；
> 3. 软件按"现状"提供（MIT 许可证），**不附带任何明示或默示的担保**；
> 4. 自行修改曲线/参数前请理解每一项的含义（曲线页有「恢复默认」按钮可一键复位出厂标定）；
> 5. 仅在验证过的机型上长期使用；其他机型请先以**只读监控模式**观察，确认传感器读数合理后再开启自动守护。

## 构建与安装（从源码）

```bash
git clone <本仓库> FanPilot && cd FanPilot
swift build                # 跑测试： swift test
Tools/make-app.sh          # 打包成 build/FanPilot.app（--release 用发布配置）
open build/FanPilot.app
```

首次使用需安装特权组件（面板里点「🔧 重装 / 修复特权组件」，或手动）：

```bash
sudo Tools/install-helper.sh          # 安装并启动守护
sudo Tools/install-helper.sh status   # 查看状态
sudo Tools/install-helper.sh uninstall# 卸载
```

## CLI

除 GUI 外还提供 `fanpilot` 命令行（构建产物在 `.build/debug/` 或 `.build/release/`）：

```bash
fanpilot fans          # 风扇/温度/守护状态
fanpilot doctor        # 机型自检报告（贴进 issue 用）
fanpilot arm           # 开启自动守护（跑「曲线」页保存的自定义档）
fanpilot disarm        # 关闭守护并交还系统
```

## 架构

```
FanPilot.app（菜单栏 App，非特权）
    │  Unix socket /var/run/fanpilot.sock
    ▼
fanpilot-helper（root LaunchDaemon，KeepAlive 崩溃自动拉起）
    │  SMC 读写（Ftst 闸门解锁 → 风扇模式/目标写入）
    ▼
AppleCLPC / 固件风扇管理

Sources/
  FanPilotCore/    SMC 访问、传感器注册表与去伪迹（PlausibilityFilter/SlowPlateauGate）、helper 协议
  ControlEngine/   PID + 曲线 + 前馈控制、守护策略（激发/交还）、helper 核心逻辑
  SafetyGuard/     安全守护（温度红线强制拉满、失明保护）
  FanPilotApp/     菜单栏 App（SwiftUI）
  fanpilot-cli/    命令行工具
```

## 安全红线

- 任何目标转速**不得低于风扇硬件下限**（F0Mn，本机为 1350 RPM）
- helper 启动即交还系统控制——守护是"需要时接管"，不是"永远手动"
- 写入失败/传感器失明立即交还，绝不和固件抢风扇

## 文档

- `Docs/COMPATIBILITY.md` —— 各机型兼容性与常见坑（菜单栏图标不显示、TCC 拦截等）
- `Docs/M4Max-SensorMap.md` —— M4 Max 的 SMC 传感器键清单与实测
- `Docs/Control-Strategy-v1.md` —— 控制策略设计

## License

MIT（见 [LICENSE](LICENSE)）
