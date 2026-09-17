#!/bin/bash
# socket-robustness-test.sh —— 验证 helper 不会被"客户端中途断开"打死（SIGPIPE）
#
# 背景（2026-09-14 实测）：helper 给一个已经消失的连接写响应时会收到 SIGPIPE，
# 而 SIGPIPE 的**默认动作是杀死进程**。触发条件在日常使用中极常见：
#   · App 每 2 秒轮询 status，超时或退出时连接就断了；
#   · CLI 拿完结果立刻退出；
#   · 强杀 App。
# 实测旧版二进制在**第 2 次**"发完就断"就死了，launchd 记录 `Broken pipe: 13`，
# 每次重启都会短暂交还系统风扇控制。
#
# 用法：
#   Tools/socket-robustness-test.sh                    # 测 .build/debug/fanpilot-helper（当前源码）
#   Tools/socket-robustness-test.sh --installed        # 测 /usr/local/libexec/fanpilot-helper（线上版本）
#   Tools/socket-robustness-test.sh /path/to/binary    # 测指定二进制
#
# 不需要 root：helper 以当前用户跑在临时 socket 上（只读状态请求即可暴露问题）。
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
BIN="${1:-$REPO/.build/debug/fanpilot-helper}"
if [ "${1:-}" = "--installed" ]; then BIN="/usr/local/libexec/fanpilot-helper"; fi
SOCK="/tmp/fanpilot-socktest-$$.sock"
LOG="/tmp/fanpilot-socktest-$$.log"
ROUNDS="${ROUNDS:-30}"

if [ ! -x "$BIN" ]; then echo "❌ 找不到可执行文件：$BIN"; exit 1; fi

echo "▸ 被测二进制：$BIN"
echo "▸ socket    ：$SOCK"
echo "▸ 轮次      ：$ROUNDS 次「连接 → 发请求 → 立刻断开不读响应」"

cleanup() { kill "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null; rm -f "$SOCK"; }
trap cleanup EXIT

FANPILOT_SOCKET="$SOCK" "$BIN" >"$LOG" 2>&1 &
HPID=$!
sleep 4

if ! kill -0 "$HPID" 2>/dev/null; then
  echo "❌ helper 没能启动："
  sed 's/^/    /' "$LOG" | head -10
  exit 1
fi
echo "▸ helper 已启动（pid ${HPID}，以当前用户运行，无法写风扇属正常）"
echo

ROUNDS="$ROUNDS" SOCK="$SOCK" python3 - <<'PY'
import os, socket
path = os.environ["SOCK"]
rounds = int(os.environ["ROUNDS"])
refused = 0
for i in range(1, rounds + 1):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2)
        s.connect(path)
        s.sendall(b'{"cmd":"status"}\n')
        if i % 3 == 0:
            s.close()                      # ★ 发完就关，不读响应 → 逼 helper 写已关闭的连接
        else:
            try: s.recv(65536)
            except Exception: pass
            s.close()
    except Exception as e:
        refused += 1
        print(f"    第 {i:2d} 次失败：{e}")
        if refused >= 3:
            print("    （连接被拒 = helper 已死，提前结束）")
            break
print(f"\n  完成 {rounds} 轮，失败 {refused} 次")
PY

echo
if kill -0 "$HPID" 2>/dev/null; then
  echo "✅ 通过：helper 全程存活 —— 客户端中途断开不会打死它"
  echo "   （日志里若出现 'Broken pipe' 属正常，只要进程还在就没问题）"
  exit 0
else
  echo "❌ 失败：helper 被 SIGPIPE 杀死了 —— 检查是否漏了 signal(SIGPIPE, SIG_IGN)"
  echo "   与每个 accept socket 上的 SO_NOSIGPIPE。最近日志："
  sed 's/^/    /' "$LOG" | tail -5
  exit 1
fi
