#!/bin/bash
# install-helper.sh —— 安装/卸载 FanPilot 特权组件（root LaunchDaemon）
#
# 用法：  sudo ~/Documents/FanPilot/Tools/install-helper.sh            # 安装并启动（拷贝到系统目录）
#         sudo ~/Documents/FanPilot/Tools/install-helper.sh reload     # 重新拷贝 + 重启（改完代码用这个）
#         sudo ~/Documents/FanPilot/Tools/install-helper.sh status     # 查看状态
#         sudo ~/Documents/FanPilot/Tools/install-helper.sh uninstall  # 卸载
#
# ⚠️ 教训：早期 --dev 让 LaunchDaemon **直接指向 ~/Documents 下的构建产物**，结果
# 守护进程起不来 —— `~/Documents` 是 TCC 保护目录，root 守护进程执行其中的二进制会被拦截。
# 因此 dev/reload 也只是"拷贝到 /usr/local/libexec 后重启"，不做任何指向用户目录的花招。
#
# ─────────────────────────────────────────────────────────────────────
# 为什么不用 SMAppService：
#   XPC + SMAppService 注册特权 daemon 要求 **Developer ID 签名（付费账号）**，
#   自签在系统设置放行环节容易卡住。本方案只需一个 sudo 安装的 LaunchDaemon，
#   完全可控、可脚本化、可测（见 Docs/FanPilot-Implementation-Plan-v2.md §6）。
# ─────────────────────────────────────────────────────────────────────
set -eu

LABEL="com.fanpilot.helper"

# ★★ 绝不能用 $HOME 推断项目位置 ★★
#   本脚本是用 sudo 跑的，sudo 下 $HOME 可能是 /var/root，
#   于是 "$HOME/Documents/FanPilot/.build/debug/fanpilot-helper" 不存在，
#   脚本报「❌ 先构建」——这正是用户看到的「安装不成功」的真凶。
#   改为**按脚本自身位置**推断，并支持 FANPILOT_SRC 覆盖。
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." 2>/dev/null && pwd || echo "$SELF_DIR")"

find_src() {
  if [ -n "${FANPILOT_SRC:-}" ] && [ -x "${FANPILOT_SRC}" ]; then echo "$FANPILOT_SRC"; return 0; fi
  # 暂存布局：脚本与二进制同目录（App 的「安装/修复」按钮会这样摆放）
  if [ -x "$SELF_DIR/fanpilot-helper" ]; then echo "$SELF_DIR/fanpilot-helper"; return 0; fi
  # 仓库布局：脚本在 Tools/ 下
  for cand in "$REPO_DIR/.build/release/fanpilot-helper" "$REPO_DIR/.build/debug/fanpilot-helper"; do
    if [ -x "$cand" ]; then echo "$cand"; return 0; fi
  done
  return 1
}

SRC="$(find_src || true)"
DIR="$REPO_DIR"
DST="/usr/local/libexec/fanpilot-helper"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SOCK="/var/run/fanpilot.sock"
LOGDIR="/var/log/fanpilot"

need_root() { [ "$(id -u)" = 0 ] || { echo "请用 sudo 运行：sudo $0 ${1:-}"; exit 1; }; }

case "${1:-install}" in
  status)
    echo "── 安装状态 ──"
    [ -x "$DST" ] && echo "  二进制: $DST ✅" || echo "  二进制: 未安装 ❌"
    [ -f "$PLIST" ] && echo "  plist : $PLIST ✅" || echo "  plist : 未安装 ❌"
    [ -S "$SOCK" ] && echo "  socket: $SOCK ✅" || echo "  socket: 不存在（helper 未运行？）"
    if [ -f /tmp/fanpilot-helper.heartbeat ]; then
      local_age=$(( $(date +%s) - $(stat -f %m /tmp/fanpilot-helper.heartbeat) ))
      echo "  心跳  : ${local_age}s 前（<5s 视为存活）"
    else
      echo "  心跳  : 无"
    fi
    echo "── launchd ──"
    launchctl print "system/$LABEL" 2>&1 | grep -E "state|pid|last exit" | head -5 || echo "  （未注册）"
    echo "── 日志尾部 ──"
    tail -5 "$LOGDIR/helper.err.log" 2>/dev/null || echo "  （无日志）"
    ;;

  diagnose)
    echo "── 安装前自检（不需要 root）──"
    echo "  whoami            : $(id -un) (uid $(id -u))"
    echo "  \$HOME             : $HOME"
    echo "  sudo 下 \$HOME 可能变成 /var/root —— 所以本脚本改用脚本位置推断（已修）"
    echo "  脚本目录 SELF_DIR  : $SELF_DIR"
    echo "  仓库目录 REPO_DIR  : $REPO_DIR"
    if [ -n "$SRC" ]; then echo "  源二进制 SRC       : $SRC ✅"; else echo "  源二进制 SRC       : 未找到 ❌（先 swift build）"; fi
    echo "  目标 DST           : $DST"
    echo "  plist              : $PLIST"
    echo "── 当前状态 ──"
    [ -x "$DST" ] && echo "  已安装的二进制     : ✅" || echo "  已安装的二进制     : ❌ 未安装"
    [ -f "$PLIST" ] && echo "  plist              : ✅" || echo "  plist              : ❌ 未安装"
    [ -S "$SOCK" ] && echo "  socket             : ✅" || echo "  socket             : ❌ 不存在（helper 未运行）"
    echo "── 直接装（若上面都正常）──"
    echo "  sudo \"$SELF_DIR/install-helper.sh\" install"
    ;;

  uninstall)
    need_root "uninstall"
    echo "▸ 停止并注销…"
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$DST" "$SOCK"
    echo "✅ 已卸载（日志保留在 ${LOGDIR}）"
    echo "   提示：卸载前 helper 会先交还系统控制；若未生效请手动跑一次 fanpilot auto"
    ;;

  install|reload)
    need_root
    if [ -z "$SRC" ] || [ ! -x "$SRC" ]; then
      echo "❌ 找不到 fanpilot-helper 可执行文件。"
      echo "   脚本目录 : $SELF_DIR"
      echo "   仓库目录 : $REPO_DIR"
      echo "   请先构建： cd \"$REPO_DIR\" && swift build"
      echo "   或指定路径： sudo FANPILOT_SRC=/path/to/fanpilot-helper $0 install"
      exit 1
    fi
    echo "▸ 源二进制：$SRC"
    # ⚠️ 绝不把 LaunchDaemon 指向 ~/Documents 下的构建产物：
    #    那是 TCC 保护目录，root 守护进程执行其中的二进制会被系统拦截（已踩过这个坑）。
    #    reload 与 install 等价（拷贝 + 重启），改完代码跑一次即可。
    echo "▸ 安装二进制 → $DST"
    mkdir -p /usr/local/libexec "$LOGDIR"
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    for _ in $(seq 1 10); do
      pgrep -f "$DST" >/dev/null 2>&1 || break
      sleep 1
    done
    # ★ 关键：等 launchd 彻底注销这个 job。否则紧接着 bootstrap 会报
    #   「Bootstrap failed: 37: Operation already in progress」——即用户看到的「安装不成功」。
    for _ in $(seq 1 15); do
      launchctl print "system/$LABEL" >/dev/null 2>&1 || break
      sleep 1
    done
    sleep 2
    rm -f "$SOCK" 2>/dev/null || true
    cp -f "$SRC" "$DST"
    chmod 755 "$DST"
    chown root:wheel "$DST"

    echo "▸ 写入 LaunchDaemon plist"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DST</string>
  </array>
  <key>RunAtLoad</key><true/>
  <!-- 崩溃自动拉起：配合 helper 的"启动即交还系统"（红线 #8）才是安全的 -->
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOGDIR/helper.out.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/helper.err.log</string>
</dict>
</plist>
PLISTEOF
    chown root:wheel "$PLIST"
    chmod 644 "$PLIST"

    echo "▸ 注册并启动"
    launchctl enable "system/$LABEL" 2>/dev/null || true

    # 带重试的 bootstrap：错误 37（清理未完成）靠等待+重试解决
    ok=0
    for attempt in 1 2 3 4 5 6 7 8; do
      if out=$(launchctl bootstrap system "$PLIST" 2>&1); then
        ok=1; echo "  ✅ bootstrap 成功（第 ${attempt} 次尝试）"; break
      fi
      echo "  ⚠️ 第 ${attempt} 次 bootstrap 失败：${out}"
      # 失败就再等一轮注销 + 清 socket，再试
      for _ in $(seq 1 5); do
        launchctl print "system/$LABEL" >/dev/null 2>&1 || break
        sleep 1
      done
      sleep 2
    done
    if [ "$ok" = 0 ]; then
      echo "  尝试回退：launchctl load -w"
      if out2=$(launchctl load -w "$PLIST" 2>&1); then ok=1; echo "  ✅ load -w 成功"
      else echo "  ⚠️ load -w 也失败：${out2}"; fi
    fi
    if [ "$ok" = 0 ]; then
      echo "  最后尝试：kickstart（若 job 其实已注册，只是没跑）"
      if launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1; then ok=1; echo "  ✅ kickstart 成功"; fi
    fi

    sleep 3
    # 直接验证：进程是否起来 + socket 是否出现（比信任 bootstrap 返回值可靠）
    if pgrep -f "$DST" >/dev/null 2>&1; then
      echo "  ✅ helper 进程已运行（PID $(pgrep -f "$DST" | head -1)）"
    else
      echo "  ❌ helper 进程未运行"
      echo "  最近日志："
      tail -5 "$LOGDIR/helper.err.log" 2>/dev/null | sed 's/^/    /'
      echo "  诊断信息（请把这段发给开发者）："
      echo "    launchctl print 状态码：$(launchctl print "system/$LABEL" >/dev/null 2>&1 && echo 已注册 || echo 未注册)"
      echo "    plist 是否可读：$([ -r "$PLIST" ] && echo 是 || echo 否)"
      echo "    plist 语法：$(plutil -lint "$PLIST" 2>&1 | head -1)"
      echo "    二进制是否可执行：$([ -x "$DST" ] && echo 是 || echo 否)"
      echo "    系统日志（最近 20 行，搜 ${LABEL}）："
      log show --last 3m --predicate "process == \"launchd\" OR eventMessage CONTAINS \"$LABEL\"" 2>/dev/null | grep -i "$LABEL" | tail -8 | sed 's/^/      /'
      echo "  手动重试命令："
      echo "    sudo launchctl bootstrap system $PLIST"
      echo "    sudo launchctl kickstart -k system/$LABEL"
      echo "  或直接前台跑，看它自己报什么错："
      echo "    sudo $DST"
    fi
    exec "$0" status
    ;;
esac
