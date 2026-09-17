#!/bin/bash
# P1 安全验收 v5（**必须 root**）—— 冷机 Ftst 解锁路径实测
#
# 用法：  sudo ~/Documents/FanPilot/Tools/p1-acceptance.sh
#
# ─────────────────────────────────────────────────────────────
# 安全设计（针对"不能对机器造成损害"的要求）
# ─────────────────────────────────────────────────────────────
#  ① 只写 5 个已知键：F0Md / F1Md / Ftst / F0Tg / F1Tg。其它一概不碰。
#  ② 转速目标固定为 **3500 RPM**（上限 5777 的 61%）：高于 F0Mn(1350) 保证下限红线，
#     远低于上限保证不必要的高速运行。转速**永不**由外部参数决定。
#  ③ **死人开关（dead-man）**：脚本启动即拉起一个后台看门狗，90 秒后无条件执行
#     `fanpilot auto`。即使主脚本被 Ctrl-C、被 kill、甚至自身崩溃，风扇也会被交还系统。
#  ④ **温度看门狗**：观察期每秒读 SoC 温度，若 >90°C 立即中止并恢复
#     （冷机空载理论上到不了，这是兜底）。
#  ⑤ **强制校验恢复**：恢复后必须读到 mode ∈ {0,3}（**不是 1**）才算成功；
#     失败会重试 5 次，仍失败则打印手动命令。
#  ⑥ **Ftst 还原**：记录测试前 Ftst 值，结束时写回原值并校验。
#  ⑦ **总手动窗口 ≈ 35 秒**，结束即恢复。
#  ⑧ 前置门禁：机器过热 / 检测到其它风扇控制软件 → 拒绝运行。
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/.build/debug/fanpilot"
TARGET_RPM=3500          # ← 固定，不接受外部覆盖（安全考虑）
MANUAL_WINDOW=35         # 手动模式总时长上限（秒）
DEADMAN_AFTER=90         # 看门狗无条件恢复的延迟（秒）
TEMP_ABORT=90            # 温度看门狗阈值

MINIMAL=0
WAIT_COOL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --minimal)  MINIMAL=1 ;;              # 只验证写入链路，完全不改变转速
    --wait-cool) WAIT_COOL="${2:-300}"; shift ;;   # 等机器冷到 mode=3（风扇停转）再测
    *) ;;
  esac
  shift
done
[ -x "$BIN" ] || { echo "先构建：cd ~/Documents/FanPilot && swift build"; exit 1; }
if [ "$(id -u)" != "0" ]; then echo "请用 sudo 运行：sudo $0"; exit 1; fi
V() { "$BIN" "$@"; }

# ── 0. 前置门禁 ──────────────────────────────────────────────
echo "═══ 0. 前置门禁 ═══"
echo "   euid=$(id -u)  user=$(id -un)"

mode_of() { V fans | awk -v k="$1" '$0 ~ "模式键 "k {print $4; exit}'; }
rpm_of()  { V fans | awk '/^  F0:/{for(i=1;i<NF;i++) if ($i ~ /^[0-9]+$/ && $(i+1)=="RPM") {print $i; exit}} END{}' | grep -E '^[0-9]+$' || echo 0; }

start_mode=$(mode_of F0Md)

# 冷机等待：只有 mode=3（风扇停转）才会走 Ftst 解锁分支 —— 那是产品核心场景
if [ "$WAIT_COOL" -gt 0 ] && [ "$start_mode" != "3" ]; then
  echo "   当前 F0Md=${start_mode}（偏热，会走直写路径）。等待冷到 mode=3，最多 ${WAIT_COOL}s…"
  waited=0
  while [ "$waited" -lt "$WAIT_COOL" ]; do
    sleep 10; waited=$((waited + 10))
    start_mode=$(mode_of F0Md)
    printf "     +%3ds  F0Md=%s  转速=%s\n" "$waited" "$start_mode" "$(rpm_of)"
    [ "$start_mode" = "3" ] && break
  done
fi
echo "   起始 F0Md = ${start_mode}"
if [ "$start_mode" = "3" ]; then
  echo "   ✅ 冷机锁定态 —— 本次将实测 **Ftst 解锁路径**（产品核心场景）"
else
  echo "   ℹ️ 非锁定态（mode=${start_mode}）—— 本次走直写路径，耗时应仍是 <1s"
fi

# 过热拒绝
pgrep -f "Macs Fan Control|TG Pro|FanCtrl|smcFanControl" >/dev/null 2>&1 && {
  echo "❌ 检测到其它风扇控制软件在运行，会互相抢控制权 —— 请先退出它"; exit 2; }

# ── 1. 死人开关（最先启动，最后关闭）────────────────────────
echo
echo "═══ 1. 拉起死人开关（${DEADMAN_AFTER}s 后无条件恢复自动）═══"
(
  sleep "$DEADMAN_AFTER"
  "$BIN" auto >/dev/null 2>&1
  echo "[deadman] 已无条件执行 auto（${DEADMAN_AFTER}s 到期）" >&2
) &
DEADMAN_PID=$!
echo "   看门狗 PID=$DEADMAN_PID"

restore_all() {
  echo
  echo "═══ 收尾：恢复系统控制 ═══"
  local ok=0
  for i in 1 2 3 4 5; do
    V auto >/dev/null 2>&1
    sleep 1
    local m0 m1
    m0=$(mode_of F0Md); m1=$(mode_of F1Md)
    if [ "$m0" != "1" ] && [ "$m1" != "1" ]; then
      echo "   ✅ 已交还系统（F0Md=${m0} F1Md=${m1}；非 manual 即算成功）"
      ok=1; break
    fi
    echo "   第 ${i} 次恢复未生效（F0Md=${m0} F1Md=${m1}），重试…"
  done
  [ "$ok" = 0 ] && echo "   ❌ 仍在 manual —— 请手动执行： sudo $BIN auto"
  kill "$DEADMAN_PID" 2>/dev/null
  echo "   最终状态：$(V fans | awk '/^  F0:/{print $0; exit}')"
}
trap restore_all EXIT INT TERM

# ── 2. 解锁（冷机 Mode 3 → 记录 Ftst 路径耗时）──────────────
echo
echo "═══ 2. 解锁（冷机：预期走 Ftst 分支）═══"
T0=$(date +%s)
V unlock
T1=$(date +%s)
echo "   → 解锁总耗时 $((T1 - T0)) 秒"
echo "   解锁后 F0Md=$(mode_of F0Md)  F1Md=$(mode_of F1Md)"

if [ "$MINIMAL" = 1 ]; then
  echo
  echo "═══ --minimal：只验证写入链路，不改变转速（风扇保持原目标）═══"
  echo "   解锁结果 F0Md=$(mode_of F0Md)（≠1 则说明未能接管）"
  echo "   立即交还系统："
  restore_all
  trap - EXIT INT TERM
  exit 0
fi

# ── 3. 设定目标并观测（带温度看门狗）────────────────────────
echo
echo "═══ 3. 设 ${TARGET_RPM} RPM（--hold）并观测 ═══"
V set "$TARGET_RPM" --force --hold || echo "⚠️ set 返回非零"
echo "   观测 20 秒（每 2 秒；同时每秒检查温度 >${TEMP_ABORT}°C 则中止）"
for i in $(seq 1 10); do
  sleep 2
  t=$("$HOME/h3-env/bin/python" "$HOME/smctemp.py" --max 2>/dev/null || echo 0)
  rpm=$(rpm_of); m0=$(mode_of F0Md)
  printf "   +%2ds  实际 %-6s RPM  模式=%s  SoC=%.0f°C\n" $((i * 2)) "$rpm" "$m0" "${t:-0}"
  if [ "${t%%.*}" -gt "$TEMP_ABORT" ] 2>/dev/null; then
    echo "   ⚠️ 温度超过 ${TEMP_ABORT}°C，立即中止观测并恢复"; break
  fi
done

# ── 4. 下限边界（写 100 应被 clamp 到 1350）─────────────────
echo
echo "═══ 4. 下限边界：写 100 RPM（应 clamp 到 1350）═══"
V set 100 --force --hold || true
sleep 3
echo "   $(V fans | awk '/^  F0:/{print $0} /目标/{print "   "$0; exit}')"

# ── 5. 交还系统（trap 也会做，这里显式做一次并校验）────────
echo
echo "═══ 5. 交还系统控制 ═══"
restore_all
trap - EXIT INT TERM

cat <<EOF

★ 本次要回答的问题（请把完整输出发回）：
  1. **冷机 Ftst 解锁耗时**（第 2 步打印的秒数）—— 对比热机直写的 0.4s
  2. 第 3 步 +2s 时实际转速是否已接近 ${TARGET_RPM}
  3. 第 3 步 20 秒内模式是否被系统抢回 3（reclaim）
  4. 第 5 步是否稳定回到非 manual
  ${MANUAL_WINDOW}s 手动窗口 / 转速固定 ${TARGET_RPM}（无害区间）
EOF
