# FanPilot 兼容性说明（上传 GitHub 前必读）

> 最后更新：2026-09-11 ｜ 参考机型：MacBook Pro 16" M4 Max (`Mac16,5`) / macOS 26.6.2

---

## 1. 一句话结论

**当前只在 MacBook Pro 16" M4 Max 上完整验证过。**
代码已做跨机型自适应（运行时探测 + 转速归一化 + 无风扇降级），但**其它机型需要社区实测**。
上传 GitHub 时应明确标注：**"仅在 M4 Max MacBook Pro 上验证；其它机型请先跑 `fanpilot doctor`"**。

---

## 2. 兼容性矩阵

| 机型 | 风扇控制 | 温度监控 | 依据 |
|---|---|---|---|
| **MacBook Pro 16" M4 Max** | ✅ **已验证** | ✅ 已验证 | 本项目全部实测数据来源 |
| MacBook Pro M4 / M4 Pro | ⚠️ 大概率可用 | ✅ 应可用 | 同代 SMC；可能不需要 Ftst（未验证） |
| Mac mini M4 | ⚠️ 大概率可用 | ✅ 应可用 | 逆向调研实测：直写即可，无 Ftst（1 风扇 1000–4900 RPM） |
| MacBook Pro M1 / M1 Pro / Max | ⚠️ 大概率可用 | ✅ 应可用 | 调研实测：直写 mode=1 即可（无 Ftst） |
| MacBook Pro M2 / M3 | ❓ 未知 | ⚠️ 未知 | **逆向调研也未覆盖**，传感器键名可能不同 |
| MacBook Pro M5 | ⚠️ 大概率可用 | ⚠️ 未知 | 模式键为**小写** `F%dmd`、无 Ftst —— 代码已兼容大小写探测 |
| **MacBook Air（全系）** | ❌ **不适用** | ✅ 可用 | **无风扇**（被动散热）。程序会自动识别并只做监控 |
| iMac / Mac Studio / Mac Pro | ⚠️ 理论可用 | ⚠️ 未知 | 风扇数与范围不同，策略会自动缩放（未验证） |
| **Intel Mac** | ❌ **不支持** | ❌ 不支持 | 温度用 `fpe2` 定点、强制模式用 `FS! ` 键、语义不同 |

---

## 3. 代码里做了哪些自适应（这是能跨机型的基础）

| 机制 | 位置 | 作用 |
|---|---|---|
| **模式键大小写运行时探测** | `FanActuator.modeKey(for:)` | 先试 `F0Md` 再试 `F0md` → M1–M4（大写）与 M5（小写）都覆盖 |
| **`Ftst` 存在性探测 + 两阶段解锁** | `FanActuator.unlockManual()` | 有 Ftst 的机型（M4 Max MacBook）走解锁回退；没有的（M1/M5/mini）直写即可 |
| **转速策略按实际风扇范围缩放** | `ThermalProfile.scaled(toFanMin:fanMax:)` | 曲线/前馈/地板以本机 `F%dMn`–`F%dMx` 为基准等比缩放，**保持曲线形状** |
| **无风扇机型降级** | `FanActuator.hasFans` | `FNum` 为 0 或不存在 → 明确报"此机型无风扇"，只做监控，不尝试写入 |
| **传感器全量枚举 + 分族** | `SensorRegistry` | 不依赖固定键名，按前缀归族；缺族时该族为 `nil`，不影响其它族 |
| **离群剔除（通用防线）** | `SensorAggregator` | 与同族中位数偏离 >15°C 的样本一律丢弃 → **对任何机型都生效**，这才是防止"假读数把风扇钉在 100%"的根本机制 |
| **写入前查 `kern_return` + 回读校验** | `SMCConnection` / `FanActuator` | 与机型无关的通用正确性保证 |

---

## 4. 仍需注意的机型相关之处

1. **硬编码的"已知坏键"表只对参考机型成立**
   `SensorRegistry.knownBogusOnReferenceModel`（`Tf06/16/26/36/46` 等）是在本机实测的。
   别的机型可能有**不同的**恒定假读数键 —— 这些键不会被这张表拦住，
   但会被 `SensorAggregator` 的离群剔除挡住大部分影响。
   → **`fanpilot doctor` 的"加载脉冲响应性测试"会报出这类键，请据此提交 issue。**

2. **阈值是按本机标定的**
   通知 100°C / 告警 105°C 基于"本机 CPU 满载稳定 110–112°C、结温规格约 110°C"。
   不同机型（尤其风扇更小的 MacBook Air/13"）散热余量不同，**这些阈值应允许用户调整**。

3. **前馈依赖 `PDTR`（系统功率键）**
   若某机型没有 `PDTR`，`doctor` 会明确报告；此时前馈自动退化为纯温度反馈（PI），
   功能仍可用，只是"抢跑"能力变弱（少了 10–14 秒的提前量）。

4. **本机是双风扇**，代码按 `FNum` 遍历所有风扇并统一下发同一目标转速。
   风扇数不同的机型（mini 1 个、Mac Pro 多个）会自动适配；但"每台风扇独立曲线"尚未实现。

---

## 5. 分发注意事项（GitHub 发布）

| 项 | 说明 |
|---|---|
| **签名** | 目前 ad-hoc 签名。别人下载后 macOS 会提示"无法验证开发者" → 需**右键→打开**，或 `xattr -d com.apple.quarantine FanPilot.app`。**这必须在 README 里写清楚** |
| **特权组件** | 无需开发者账号：`sudo Tools/install-helper.sh` 安装 root LaunchDaemon（不用 SMAppService，避免 Developer ID 要求） |
| **卸载** | `sudo Tools/install-helper.sh uninstall`；卸载前 helper 会交还系统控制 |
| **安全说明** | helper 以 root 运行、只听 Unix socket、用 `getpeereid()` 校验对端 UID。**要在 README 里公开这些细节**——用户会想知道 |
| **免责声明** | 必须写明：**风扇控制是未公开接口**，可能因 macOS 更新失效；作者不对硬件损坏负责；不保证所有机型可用 |
| **来源致谢** | Ftst 解锁机制、模式语义、reclaim 行为的**逆向知识**来自 [`agoodkind/macos-smc-fan`](https://github.com/agoodkind/macos-smc-fan)（MIT）与其整理文档。本项目是独立实现，但**应当致谢** |
| **许可证** | 建议 MIT（与本项目引用的调研资料一致，且对个人工具最友好） |

---

## 6. 新机型接入清单（给贡献者）

```bash
# ① 采集环境信息（无需 root，不会改动风扇）
~/Documents/FanPilot/.build/debug/fanpilot doctor > /tmp/fanpilot-doctor.txt

# ② 先看策略模拟（不接触硬件）
~/Documents/FanPilot/.build/debug/fanpilot plan

# ③ 只读验收（不改变转速，仅验证写入链路是否通）
sudo ~/Documents/FanPilot/Tools/p1-acceptance.sh --minimal

# ④ 完整验收（含阶跃响应测量，风扇会明显加速）
sudo ~/Documents/FanPilot/Tools/p1-acceptance.sh
```

把 ① 的输出贴进 issue，并在标题写明机型（如 `Mac15,3 M3 Max`），我们即可判断：
- 模式键是大写还是小写
- 是否需要 `Ftst` 解锁
- 风扇范围（决定策略缩放）
- 哪些传感器键在你的机器上是无效的
- 是否有 `PDTR`（决定前馈是否可用）

---

## 7. 结论：现在的状态适合怎么发布

**建议以 "早期预览 / Early Preview" 发布：**

- ✅ 可以发：代码结构、自适应机制、安全设计、完整文档、`doctor` 自检
- ⚠️ 必须标注：仅 M4 Max MacBook Pro 验证；其它机型需自行用 `doctor` 确认
- ❌ 不要宣称："支持所有 MacBook" —— 事实是 **MacBook Air 无风扇，Intel 不支持**
- 📣 欢迎的贡献：**机型实测报告**（`doctor` 输出 + 是否成功接管）

这样发布的好处是：你不需要先买一堆机器，就能靠社区把兼容性矩阵补全。

---

## 7. 已知问题：菜单栏图标不显示（bundle ID 状态污染）

### 现象
App 正常运行（进程在、日志每 2 秒更新、`isVisible=true`），但**菜单栏里就是没有图标**。
用几何日志看，状态栏项的位置是 `x=0, y=-26`（y 为负 = 屏幕上方之外，即被系统"隐藏"），
而不是正常的 `x≈1367`（屏幕右侧）。

### 根因（本机实测确认）
**macOS 会按 bundle ID 持久化状态栏项的隐藏状态。**
在开发过程中，该 bundle ID 曾有一段时间处于"菜单栏已满、项被移到屏幕外"的状态，
系统把这个结果记了下来，之后**每次启动都沿用"隐藏"**。

证据（同一二进制、同一路径、同一份 plist，只改 bundle ID）：

| CFBundleIdentifier | 结果 |
|---|---|
| `com.fanpilot.menubar` | ❌ 隐藏（x=0, y=-26） |
| `com.fanpilot.menubar2` | ✅ 正常（x=1367, y=1086） |
| `com.fanpilot.Menubar` | ✅ 正常（x=1367, y=1086） |

排除了以下假设（都实测过、均不是原因）：
- ❌ 菜单栏空间不足 —— 用户已腾出空间，仍然隐藏
- ❌ `LSUIElement` / `NSPrincipalClass` —— 四种 plist 组合全部正常
- ❌ 代码签名（ad-hoc）—— 带签名的测试 bundle 正常
- ❌ 激活策略 `.accessory` vs `.regular` —— 两者都正常
- ❌ 主线程阻塞 I/O —— 移到后台队列后仍然隐藏
- ❌ `killall ControlCenter` —— 无效
- ❌ 启动路径（`~/Documents` vs `/tmp`）—— 都复现
- ❌ Preferences 文件里的键 —— `com.apple.controlcenter.plist` 中没有该 bundle ID 的键

### 解决办法
1. **换一个全新的 bundle ID**（本项目已从 `com.fanpilot.menubar` 改为 `com.fanpilot.app`）——最省事；
2. 或者让用户在**系统设置 → 控制中心 → 菜单栏**里把它拖回可见区（需要先能看到它）；
3. 另外 App 内置了**独立窗口兜底**：启动后若连续 3 次判定图标不在菜单栏内，
   会自动弹出一个普通窗口（并在 Dock 显示图标），保证始终有入口。

> 这个坑值得写进 README 的 FAQ —— 用户自签构建、反复重启调试时很可能踩到。

---

## 8. 菜单栏显示规格

图标右侧显示**实时热点温度**（CPU/GPU/内存/供电四族的最大值），按温度着色：

| 温度 | 颜色 | 含义 |
|---|---|---|
| < 93°C | 🟢 绿色 | 正常 |
| 93 – 112°C | 🟠 橙色 | 偏热（本机满载常态区间） |
| > 112°C | 🔴 红色 | 接近/超过结温规格（约 110°C） |

- 阈值定义在 `AppState.TempBand`，改两行即可调整。
- 图标本身也表达状态：**线框风扇** = 系统自动；**实心风扇** = FanPilot 接管中。
- 悬停提示显示完整信息（各族温度、功率、风扇、模式、Ftst）。
- 用 `attributedTitle` 着色（`NSStatusItem` 原生支持属性字符串）。

**验证方式（不用把机器烧热）**：设环境变量伪造温度后启动：

```bash
FANPILOT_FAKE_TEMP=115 .build/debug/FanPilotMenu    # → 应显示红色 115°
```

启动日志的 `rendered=` 字段会记录**实际渲染到菜单栏的字符串与颜色名**，
便于在看不到屏幕（或无屏幕录制权限）时自检。

---

## 9. App ↔ helper 协议兼容性（重要）

**问题**：Swift 自动合成的 `Codable` 对**非可选字段**要求 JSON 中键必须存在，
否则抛 `keyNotFound` → **整个响应解码失败**。

**实际踩到**：helper 是旧二进制（没有新加的 `fanTargets` 字段）时，
新版 App 的每一次状态查询都解码失败，界面显示"特权组件无响应（连接超时）"——
**极易误判成权限问题或连接问题**，实际是协议版本不一致。

**修复**：
1. `HelperStatus` 改为**手工实现 `init(from:)`**，每个字段都用 `decodeIfPresent` + 默认值
   → 新旧版本任意组合都能解码；
2. 增加 `protocolVersion` 字段，App 检测到 helper 较旧时在面板上提示"建议重装特权组件"；
3. `HelperClient` 区分记录失败阶段（connect/write/read/decode + errno），
   排障时能直接看出是"连不上"还是"解码失败"。

**教训**：App 与 helper 是两个独立安装的二进制，**版本不一致是常态**，
协议必须向前/向后兼容，不能依赖编译期一致性。

## 10. 控制命令超时（另一个误报来源）

冷机解锁走 Ftst 路径**实测需 12 秒**，而客户端超时原本只有 3 秒
→ App 报"接管失败"，实际 9 秒后 helper 成功接管了（日志可见）。

**修复**：状态查询 3s / 控制命令 30s 分开设置；UI 在等待期间显示
"正在接管（冷机解锁最长约 12 秒）…"，并在完成后自动刷新。

---

## 11. 重装 helper 时的一个 launchd 竞态（安装脚本 bug）

**现象**：helper 明明已装好，控制按钮却是灰的、App 报"特权组件未安装（socket 不存在）"。

**根因**（系统日志实证）：
```
11:29:09  bootout initiated → signaled service: Terminated: 15
11:29:09  scheduling cleanup in 5 sec                      ← launchd 还要 5 秒清理旧任务
11:29:09  Bootstrap failed (37: Operation already in progress)  ← 脚本只等了 1 秒就 bootstrap
```
安装脚本 `bootout` 后只 `sleep 1` 便 `bootstrap`，撞上 launchd 的清理窗口 →
**表现为"第一次安装成功、之后每次重装都静默失败"**（非常容易误判为权限或签名问题）。

**修复**：
1. `bootout` 后**轮询等待旧进程真正退出**，再留 2 秒余量；
2. `bootstrap` 带 **5 次重试**（每次间隔 3 秒），失败再回退 `launchctl load -w`；
3. 安装末尾**直接验证进程是否起来**（比信任返回值可靠），失败时打印日志尾部与手动命令；
4. 移除 `--dev` 模式 —— 它曾把 LaunchDaemon 指向 `~/Documents`（TCC 保护目录），
   导致 root 守护进程无法执行；`reload` 现等价于 `install`。

---

## 12. 「安装不成功」的两个真凶（2026-09-12 实测定位并修复）

用户点面板里的「🔧 安装 / 修复特权组件」得到的是失败提示。定位到**两个独立原因**，都已修复。

### 12.1 真凶 A：安装脚本依赖 `$HOME`，而 `sudo` 下它可能是 `/var/root`

旧脚本第一行就是：

```bash
DIR="$HOME/Documents/FanPilot"
SRC="$DIR/.build/debug/fanpilot-helper"
```

`sudo` 环境下 `$HOME=/var/root` → `SRC=/var/root/Documents/FanPilot/.build/debug/fanpilot-helper`
**不存在** → 脚本打印 `❌ 先构建：cd /var/root/Documents/FanPilot && swift build` 就退出了。
用户看到的就是「安装不成功」，而实际上只是**路径推断错了**。

复现（无需 sudo，直接模拟）：

```bash
HOME=/var/root bash -c 'DIR="$HOME/Documents/FanPilot"; [ -x "$DIR/.build/debug/fanpilot-helper" ] \
  && echo 找到 || echo "❌ HOME=/var/root 时找不到二进制"'
```

**修复**：改为**按脚本自身位置**推断（`SELF_DIR=$(cd "$(dirname "$0")" && pwd)`），
并支持 `FANPILOT_SRC` 覆盖；新增 `install-helper.sh diagnose` 子命令（**不需要 root**），
一条命令打印 `$HOME / SELF_DIR / REPO_DIR / SRC / DST` 与当前安装状态。

### 12.2 真凶 B：终端读不到 `~/Documents`（TCC）

`~/Documents` 是 TCC 保护目录。App 直接让终端执行 `~/Documents/.../install-helper.command`
（此前的 `osascript … with administrator privileges` 同理）会得到：

```
/bin/bash: <仓库路径>/Tools/install-helper.sh: Operation not permitted (126)
```

**修复**：App 的安装按钮不再让终端碰 `~/Documents`，而是先把
**安装脚本 + 已构建的 helper 二进制**暂存到非保护目录：

```
~/Library/Application Support/FanPilot/installer/
├── install-helper.sh              # 脚本副本
├── fanpilot-helper                # 二进制副本（脚本优先使用同目录这一份）
└── 安装FanPilot特权组件.command    # 终端启动脚本，输出 tee 到 /tmp/fanpilot-install-last.log
```

然后 `NSWorkspace.open()` 打开那份 `.command`。终端完全不需要「文稿文件夹」权限。

自检（不需要点按钮、不需要 sudo）：

```bash
./.build/debug/FanPilotMenu --stage-installer
# ✅ 已暂存安装文件：…/Application Support/FanPilot/installer/安装FanPilot特权组件.command
```

### 12.3 真凶 C：`bootout` 后没等 launchd 注销就 `bootstrap`（竞态）

`Bootstrap failed: 37: Operation already in progress`（launchd 约 5 秒清理期）。
旧脚本只等**进程**退出，没等 **job 注销**。

**修复**：`bootout` 后轮询 `launchctl print system/com.fanpilot.helper` 直到它**报错**（=已注销），
再清 `socket`、留 2 秒余量；`bootstrap` 重试次数 5→8，每次失败后再等一轮注销；
最后回退顺序 `load -w` → `kickstart -k system/com.fanpilot.helper`；
失败时打印 `plutil -lint`、二进制可执行位、`log show` 里 launchd 的相关行。

### 12.4 修复后的实测结果（用户环境，一次成功）

```
源二进制 SRC : ~/Library/Application Support/FanPilot/installer/fanpilot-helper ✅
✅ bootstrap 成功（第 1 次尝试）
✅ helper 进程已运行（PID 36681）
socket: /var/run/fanpilot.sock ✅
```

`launchctl print system/com.fanpilot.helper` → `state = running`，
helper 日志首行即 `启动自检：已交还系统控制（Ftst 复位）`（红线 #8 有效）。

---

## 13. 「窗口显示内容有限，好多内容看不到」的原因（已修复）

不是绘制问题，是**尺寸写死**。实测数据（`--measure-panel` 自检，屏幕可视区 1728×1084）：

| 项 | 数值 |
|---|---|
| 监控页内容真实高度 | **657 pt** |
| 旧面板固定高度 | 620 pt（去掉 `TabView` 内边距 20 + 页脚 34 → 可用 **566 pt**） |
| 被藏住的内容 | **87 pt**（约 3～4 行） |
| 旧「⤢ 窗口」 | 拉大后内容区**仍是 430×620**（`PanelView` 写死 frame），所以窗口越大空白越多 |

macOS 默认**隐藏滚动条**，用户看不到"下面还有内容"，只看到内容凭空消失 —— 这就是反馈的原话。

**修复**：

1. `PanelView` 增加 `flexible` 参数：popover 用固定 **430×720**（666 pt 可用 ≥ 657 pt，**一屏放得下，无需滚动**）；
   独立窗口用 `minWidth/minHeight` + 无限上限，**真正跟随窗口缩放**；
2. 两页 `ScrollView` 加 `.scrollIndicators(.visible)` —— 万一内容再变长，用户也能看见滚动条；
3. 主窗口默认尺寸按屏幕计算（560×860，且不超出 `visibleFrame`），并**校验记忆的窗口尺寸**
   （旧的 430×620 残废值会被丢弃）；窗口 `contentMinSize = 440×440`；
4. 新增「启动开窗」开关（默认开）：启动即打开可缩放主窗口，一屏看全；
5. `⤢ 窗口` 按钮加 tooltip 说明"可自由缩放，内容一屏看全"。

自检命令：

```bash
./.build/debug/FanPilotMenu --measure-panel
# 面板可用内容高 666 pt vs 监控页实际需要 657 pt → ✅ 一屏放得下，无需滚动
```

---

## 14. 温度读数抖动 16°C：族聚合的两个真 bug（2026-09-12 实测定位并修复）

### 现象

P4 的会话 CSV 一开出来就露出马脚 —— `hotspot` 在相邻采样之间来回跳：

```
17:49:52  hotspot 63.5   fan 1338/1477
17:49:59  hotspot 81.3   fan 1337/1454
17:50:04  hotspot 63.5   fan 1343/1460
```

独立实现（`~/smctemp.py --max`，纯 ctypes 直读）也复现：`77.8 63.1 72.3 73.4 78.4 …`

### 根因：`SensorAggregator` 对"小族"做了没有依据的离群剔除

内存族 `TCM` 只有 **2 个键**，而它们本来就差 16°C：

| 键 | 实测（SensorMap） |
|---|---|
| `TCMz` | 72.0°C（σ 0.92，稳定） |
| `TCMb` | 58.2°C（σ 0.66，稳定） |

旧代码 `SensorAggregator.aggregate` 有两个缺陷叠加：

1. `let median = sorted[sorted.count / 2]` —— **偶数个样本取的是上中位数**。`[58, 72]` 的中位数算成 72
   （真中位数是 65），系统性偏高；
2. 接着用 `abs(v - median) <= outlierBand(15)` 过滤 —— 58 距 72 有 16，**刚好被整个丢掉**：
   `样本 2(采用 1)`，族值 = 72。

再叠加 SMC **多路复用**导致的偶发读失败（某一轮只剩 `TCMb`），族值就在 72 与 58 之间翻来覆去，
`hotspot = max(各族)` 于是在 **79.6 ↔ 63.5** 之间抖 16°C。危害有两个：

* 菜单栏温度/面板大数字乱跳，用户以为程序坏了；
* **P4 的高温通知失效**：通知依赖"持续时长"，单次坏读数把计时器清零 → 该报的高温不报。

### 修复

1. **小族不做离群剔除**：样本数 `< minCountForOutlierFilter(5)` 时直接用全部有效读数。
   两个键之间没有统计依据判定谁是离群 —— 这是根本。
2. **真中位数**：`properMedian()` 偶数样本取中间两个的平均值。
3. **热点峰值保持 `HotspotHold(window: 8s)`**（`SMCSensorHub` 内）：
   对外 hotspot 取"最近 8 秒内的峰值"。上升沿**零延迟**，下降沿最多滞后 8 秒（对风扇更保守）。
   `isBlind` 仍用**即时值** `hotspotRaw` 判断 —— 峰值保持绝不能掩盖"传感器全盲"（安全红线）。
4. CSV 同时记 `hotspot_c`（保持值）与 `hotspot_raw_c`（即时值），
   以后再出这类问题可以直接从数据里看出来是传感器抖动还是真实降温。

### 真机验证（`fanpilot stability 12`，免 sudo）

修复后 `mem` 族稳定在 67–75°C（不再掉到 58），**瞬时极差 12.2°C → 保持值极差 2.3°C**：

```
   #    cpu    gpu    mem    vrm | 即时  保持
    2   58.4   57.3   73.2   54.9 |   73.2   73.2
    6   59.3   57.3   75.5   55.0 |   75.5   75.5
    7   58.7   57.2   67.9   54.7 |   67.9   75.5   ← 单次掉 7.6°C 被保持吸收
```

同时确认：`mem` 确实是空闲时最热的族（67–75°C，而 cpu 只有 57–59）。
**如果按"小族样本不足就整族排除"的思路去修，会把真实热点少报 10–15°C** —— 方向反了，所以选择了上面的修法。

新增回归测试 10 个（`SensorStabilityTests` + `ProtocolHotspotRawTests`），全套 **81 个测试**通过。
诊断命令：`fanpilot stability [n]`。


---

# 15. 【严重】2026-09-13 真实事故复盘：helper 每分钟崩溃 + 默认不设防

用户跑本地大模型（oMLX）时实测：**FanPilot 全程没有干预**，温度到 **104.6°C** 都没接管；
手动点「最强清凉」后风扇拉满，但**不到一分钟就停了**；系统在 115°C 弹出高温警告。

## 15.1 证据链（全部可在本机复现）

| 证据来源 | 内容 |
|---|---|
| `launchctl print system/com.fanpilot.helper` | `successive crashes = 3`、`last terminating signal = Abort trap: 6`（SIGABRT）、进程只活了 **60–90 秒** |
| `/Library/Logs/DiagnosticReports/fanpilot-helper-2026-09-13-2307/08/09*.ips` | 3 份崩溃报告，时间 **23:07:14 / 23:08:21 / 23:09:51** |
| 崩溃栈 | `SensorRegistry.poll() ← SMCSensorHub.snapshot() ← ControlRunner.run()` |
| `/var/log/fanpilot/helper.err.log` | 每次 "✅ 已接管" 之后 60–90 秒必然出现 "启动自检：**已交还系统控制**" |
| 会话 CSV 事件行 | `23:07:15 / 23:08:21 / 23:09:51 接管=0 … 原因=只读监控（未安装特权组件）`（helper 掉了，App 退化成只读） |
| CSV 采样 | `23:05:41 hs=100.7 fan=1356 mode=0 ctrl=0`、`23:05:47 hs=104.6 fan=1364 ctrl=0` |
| P4 高温通知 | `23:08:45 ALERT emergency 114.8°C`（通知系统本身是好的） |

崩溃时间与"控制中断"时间**逐秒对应**。

## 15.2 根因一：多线程数据竞争（SIGABRT）

```
控制线程 Thread "fanpilot.control"           socket 线程（每个连接 Thread.detachNewThread）
  ControlRunner.run()                          HelperCore.status()
    └─ hub.snapshot()                            └─ hub.snapshot()     ← 同一个 hub 实例！
         └─ registry.poll()                            └─ registry.poll()
              for (k, rec) in records { records[k] = rec }   ← 同时遍历+写入同一个 Dictionary
```

Swift Dictionary 并发读写 → 内存损坏 → `doesNotRecognizeSelector` → abort。

**为什么"只有接管后才会崩"**：只有在跑控制环时，才有两个线程高频同时读 SMC；
平时 helper 只被动应答，撞车概率低（所以早上 08:57 崩过一次后能撑 14 小时）。

**后果为什么这么严重**：红线 #8 规定 helper「启动即交还系统」。
于是每次崩溃被 launchd 拉起 → **立刻交还** → 用户看到"风扇转一分钟就停"。
崩溃频率 ≈ 60–90 秒，正好等于用户描述的"不到一分钟"。

### 修复（4 处加锁 + 1 个并发回归测试）

1. `SensorRegistry`：`NSRecursiveLock` 保护 `poll()`；新增 `recordsSnapshot()`；
   `poll()` 改为在本地副本上改再整体赋值（不再"边遍历边写自身"）。
2. `SensorAggregator`：新增作用于**记录副本**的重载，聚合不再触碰共享字典。
3. `SMCSensorHub.snapshot()`：整段加锁（poll + 聚合 + 峰值保持）。
4. `SMCConnection`：所有 IOKit 调用串行化（`read()` 是 keyInfo+read 两步，交叉会配错 size/type）。
5. `FanActuator`：`refresh / unlockManual / setTarget / reassert / releaseToAuto` 全部加锁
   （控制线程写目标转速时，socket 线程在 `status()` 里读风扇状态）。
6. **回归测试 `ConcurrencyTests`**：8 个线程猛敲 `hub.snapshot()` 1.5 秒。
   实测**去掉锁后该测试立刻崩**（`Fatal error: invalid Collection: count differed in successive traversals`，
   signal 5），加锁后稳定通过 —— 也就是说这个测试真的能抓住这个 bug。

## 15.3 根因二：默认不设防 —— 不点按钮就永远不干预

`startControlLoop()` 只在 `takeover()` 里被调用。也就是说：

> **旧版本里 FanPilot 默认什么都不做。** 它只在状态栏显示温度；
> 用户必须先手动点「清凉 / 最强清凉」，控制环才开始跑。

用户 23:05:23 时功耗已经 **128W**、23:05:47 温度 **104.6°C**，而 `controlling` 一直是 0。

### 修复：新增「自动守护」（自动守护 / auto-guard）

* helper 启动时按落盘状态**自动恢复守护**（`ArmStore` → `/usr/local/var/fanpilot/armed.json`）；
  顺序上仍在"启动即交还"**之后**，红线 #8 不变。
* 守护使用档位自带的 **`.daily` 激发策略**：温度 <85°C **且** 功率 <55W 时**完全被动**（不碰风扇），
  任一门限超过 2 秒即自动接管；回落到 <35W 且 <70°C 持续 30 秒才退出。
* 因此：**关掉 App、helper 崩溃重启、重启电脑，守护都继续存在。**
* App 面板顶部新增状态条（🛡 自动守护中 / ⚠️ 未开启 + 一键开关 + 档位选择），默认**开启**。
* 「交还系统」会同时关掉守护偏好（否则下次启动又自己接管，用户会以为"说了交还怎么又动"）。
* 新增命令：`fanpilot arm [cool|maxCool]` / `fanpilot disarm`；`fanpilot fans` 会显示守护状态。
* App 检测 helper **pid 变化** → 记录 `HELPER_RESTART` 事件 + 发通知（这类故障以后不会被静默吞掉）。

## 15.4 新增的诊断工具

```bash
# 从 CSV 量化"高温时到底有没有人在管"（本次事故的结论就是它跑出来的）
python3 Tools/incident-report.py                       # 今天的日志
python3 Tools/incident-report.py --all                 # 全部

# 量化温度抖动（排查"菜单栏温度乱跳"）
fanpilot stability 12

# 安装前自检（不需要 root）
bash ~/Library/Application\ Support/FanPilot/installer/install-helper.sh diagnose
```

`incident-report.py` 本次输出：

```
★ 关键指标：温度 ≥95°C 而**无人保护**的累计时长 = 0.9 分钟（4 段）
★ 控制中断事件: 只读监控 4 次
    23:07:15  掉线（当时最高温度 105.0°C）
    23:08:21  掉线（当时最高温度 107.5°C）
    23:09:51  掉线（当时最高温度 107.5°C）
结论：发现 4 次控制中断（helper 掉线/崩溃） —— 必须修。
```

## 15.5 教训（写给未来的自己）

1. **"安全红线"本身也需要防故障**：`启动即交还` 在崩溃循环里会变成"风扇永远起不来"。
   现在加上"启动即恢复守护"，两条规则才互相兜住。
2. **默认值就是产品**：需要用户先点一下才生效的安全功能，等于没有。
3. **跨线程共享一个 SMC/传感器对象必须先加锁** —— 这次是 Swift Dictionary 直接 abort。
4. **CSV 会话日志值回票价**：没有它，这次只能靠崩溃报告猜；有了它，崩溃时间、温度、风扇、
   `controlling` 一一对齐，10 分钟定位。
5. **回归测试必须真的能复现**：去掉锁就崩、加回锁就过，这个测试才可信。

---

## 16. 用户反馈的两个"小"问题，其实都是设计漏洞（2026-09-13 晚）

> 用户原话：「面板里找不到安装修复特权组件了，点亮自动守护开启后显示失败」

### 16.1 安装/修复按钮在**最需要它的时候**消失了

旧代码只在 `helperDiagnosis != "正常"` 时显示「🔧 安装 / 修复特权组件」。
于是形成了死循环：

* helper **在线**（旧版）→ 诊断是"正常" → **按钮不显示**；
* 可用户需要的恰恰是"在线但版本过旧、要重装"。

**修复**：按钮**常显**，并按状态换文案与语气：

| 状态 | 显示 |
|---|---|
| helper 掉线 | ⚠️ 具体原因 + 「🔧 安装特权组件」 |
| helper 在线但 `features` 缺少 `guard` | ⚠️「特权组件版本过旧：不支持自动守护」+ 「🔧 重装 / 修复特权组件」 |
| 一切正常 | 「🔧 重装 / 修复特权组件」+ 灰字"组件正常，一般不需要" |

### 16.2 `armed=false` 无法区分"没开"和"版本根本没有这功能"

旧 helper 不认识 `arm` 命令 → 直接不回应 → App 显示 `read() = -1 errno=35` 这种看不懂的报错；
而 `status` 里 `armed` 缺字段会解码成 `false`，界面看起来像"用户自己没开"。

**修复**：`HelperStatus.features: [String]` 能力清单（`guard` / `hotspotRaw` / `fanTargets` / `threadSafeIO`）。
App 据此：
* 开关**置灰** + tooltip 说明"当前特权组件版本过旧，请先重装"；
* 标题直接写「自动守护不可用（组件过旧）」，不再假装"未开启"；
* 失败提示改成可操作的一句话：「请点『🔧 重装 / 修复特权组件』，在终端输入一次密码即可」。

### 16.3 顺带修掉一个**逻辑自相矛盾**：退出 App 会关掉守护

`releaseOnQuit` 默认 **true**，原实现是"退出就 `releaseToAuto()`"，而 `releaseToAuto` 会清掉守护状态 ——
也就是说"关掉 App 也会继续守护"这句话是假的，用户一关 App 守护就没了。

**修复**：`guardArmed && prefs.autoGuard` 时退出**不交还**，并往 CSV 写 `QUIT_KEEP_GUARD` 事件。
「退出时交还系统」开关加 tooltip 说明它"仅在守护关闭时生效"；真要收手用面板的「交还系统」或 `fanpilot disarm`。

### 16.4 又一个"锚点不匹配导致静默失败"的教训

`status()` 里回传 `armed` / `armedProfile` 的那次编辑，**锚点没匹配上、什么都没改**，
但脚本里只有一个总的 `assert`，所以静默通过了 —— 现象就是"开关点了又自己弹回去"。

**纪律**：多步编辑必须**逐步 assert**（本次改法：写一个 `rep(old, new, why)` 辅助函数，
每步都校验"锚点恰好出现 1 次"）。已按此重做了本次全部编辑。

---

# 17. 第三类崩溃：SIGPIPE（客户端中途断开就会打死 helper）

## 17.1 发现过程

在给「生效目标温度」做验证、用 `pkill -9` 重启 App 的瞬间，helper 又换了 pid：

```
launchctl print system/com.fanpilot.helper
  runs = 2
  last terminating signal = Broken pipe: 13     ← 这次不是 SIGABRT！
```

helper 日志里**没有**"收到信号 15"（所以不是安装脚本 bootout），而是直接出现新的"启动自检"。

## 17.2 根因

```swift
// Sources/FanPilotHelper/main.swift（旧）
let data = HelperWire.encode(resp)
data.withUnsafeBytes { _ = write(clientFD, $0.baseAddress, $0.count) }
```

socket 的**对端已经消失**时，`write()` 会让进程收到 `SIGPIPE`，而 **SIGPIPE 的默认动作就是杀死进程**。
触发条件在日常使用里极其常见：

* App 每 2 秒轮询 `status`，`statusTimeout` 3 秒到期就断开；
* **退出/强杀 App**（实测就是这条打死的）；
* CLI 拿到结果立刻退出。

helper 一死 → launchd 拉起 → **启动即交还系统**（红线 #8）→ 风扇掉回 Apple 曲线。
虽然新版有"启动即恢复守护"，但每次都会短暂中断控制。

## 17.3 修复

1. helper 启动时 `signal(SIGPIPE, SIG_IGN)`（守护进程的标配）；
2. 每个 `accept()` 出来的 socket 单独设 `SO_NOSIGPIPE`
   （**accept 不会继承该选项**，所以必须逐个设）；
3. 响应写入改成**循环写**（`write` 可能只写一部分），对端断开就安全放弃；
4. 客户端侧同样加 `SO_NOSIGPIPE`（helper 消失时不许打死 App / CLI），
   App 与 CLI 再各自 `signal(SIGPIPE, SIG_IGN)` 兜底。

## 17.4 验证：新旧二进制对照（`Tools/socket-robustness-test.sh`）

不做无把握的推断，直接上压力测试：连上去 → 发一个 `status` → **立刻断开不读响应**，反复 20 次。

| 二进制 | 结果 |
|---|---|
| 线上已装（旧） | **第 5 次就死**，之后全是 `Connection refused`：`❌ 失败：helper 被 SIGPIPE 杀死了` |
| 当前源码（新） | `完成 20 轮，失败 0 次` / `✅ 通过：helper 全程存活` |

测试工具已固化（**不需要 root**，把 helper 跑在临时 socket 上）：

```bash
Tools/socket-robustness-test.sh              # 测当前源码构建
Tools/socket-robustness-test.sh --installed  # 测线上已装版本
```

## 17.5 顺带记一笔：脚本里第 4 次踩到 `$var` 紧跟中文

```bash
echo "▸ helper 已启动（pid $HPID，以当前用户运行…"   # ✗ bash 把 $HPID， 当成变量名
echo "▸ helper 已启动（pid ${HPID}，以当前用户运行…" # ✓
```

`Tools/check-scripts.py` 抓到了它（还顺手抓到 `install-helper.sh` 里一处旧的）。
**写完 shell 脚本一律先跑这个检查器**，这次是它救的。

---

# 18. 「曲线页改了目标温度，监控页为什么不变」

用户操作：曲线页把目标温度 88 → **85**、重载目标 95 → **92**，但监控页仍显示「清凉 88°C」。

helper 日志给出了完整答案：

```
[01:05:57] ▶️ 收到接管请求：profile=custom
[01:05:58] ✅ 已接管：自定义  目标温度 85°C      ← 85°C 确实生效了
[01:06:17] 🛡 自动守护已关闭 / ✅ 已交还系统
[01:06:31] 🛡 自动守护已开启：档位=cool
[01:06:31] ✅ 已接管：清凉  目标温度 88°C        ← 33 秒后被「清凉」覆盖
```

## 18.1 概念：两套档位，互不相干

| | 在哪改 | 目标温度 | 说明 |
|---|---|---|---|
| **预设** | 监控页的档位按钮 / 守护档位选择器 | 清凉 **88** / 最强清凉 **82** | 写在代码里 |
| **自定义** | 曲线页（档位名 / 目标温度 / 曲线 / 增益） | 用户自己填（这里是 **85/92**） | 保存进 `profiles.json` |

曲线页编辑的是**自定义档位**，改它不会动到预设 —— 但旧 UI 完全没说明这一点，
而且**守护的档位选择器里根本没有「自定义」这个选项**，所以守护同步时必然用 `cool` 把自定义顶掉。

## 18.2 修复

1. **守护档位选择器新增「自定义 85°C」**（第三段），`arm` 时把自定义档位数据一起下发
   （协议本来就支持 `custom`，只是 App 没用）；
2. **点「应用到风扇」时，若守护开着 → 自动把守护档位切成「自定义」**，
   并同步偏好，杜绝"33 秒后被顶掉"；
3. **面板显示真正生效的目标温度**：`HelperStatus` 新增 `targetTemp / targetTempHeavy`，
   helper 回传**正在跑的档位**的数值；旧版 helper 不报时按档位本地兜底并标注
   「（旧版组件，按档位推算）」—— 宁可显示预设值，也不让用户对着 88 猜自己在跑 85；
4. **曲线页顶部加醒目说明**：这里是自定义档位、与预设互相独立、改完要点「应用到风扇」、
   守护开着会自动切换守护档位；
5. `armedProfile` 同步回本地偏好（否则卸载重装后冷启动会按旧偏好退回 `cool`）；
6. CLI 新增 `fanpilot arm custom`（直接采用 `profiles.json` 里的自定义档位）。

## 18.3 关于 85 / 92 两个数字的含义

* **目标温度 85°C**：功率 <110W 时的瞄准点（风扇据此提前加力）；
* **重载目标 92°C**：功率 ≥110W 时改用 92°C —— 因为实测满载时**即使风扇 5777 RPM 全速**，
  稳态也在 96–112°C，死磕 85 只会换来"永久满转速且毫无收益"，所以高功耗下主动放宽。

两者都是**上限/瞄准点**，不是"恒温设定"：温度低于它们时控制器只会**减少**冷却
（实测 <60°C 时 98% 采样风扇完全停转），风扇物理上无法加热。
