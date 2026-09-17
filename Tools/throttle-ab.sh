#!/bin/bash
# throttle-ab.sh —— 安全版 A/B：判定"接管风扇（持有 Ftst=1）是否影响 macOS 的降频/性能管理"
#
# 用法：  sudo ~/Documents/FanPilot/Tools/throttle-ab.sh
#         sudo ./throttle-ab.sh --band 76-84 --duration 120
#         sudo ./throttle-ab.sh --idle-only        # 完全不加载，零额外发热
#
# ─────────────────────────────────────────────────────────────────────
# 为什么这样设计（与"烧机版"的区别）
#
#   旧设计：让负载自由升温 → A 臂到 112°C。**已废弃**：那是拿硬件寿命换一个次要结论。
#
#   新设计：**把温度当被控变量**。用占空比把两臂都压在同一个温度带（默认 76–84°C）：
#       温度 < 下限 → 加负载；> 上限 → 停负载；中间 → 短片段加载
#   于是两臂在**相同温度**下比较，差异只能来自"谁在管风扇"，而不是"谁更凉"。
#   —— 比旧设计在科学上更干净，且全程不超过 84°C，硬上限 88°C 兜底。
#
#   另有 `--idle-only`：完全不产生额外热量，只观察 Ftst=1 在空闲时是否改变了
#   系统的热压/频率读数。零风险，随时可跑。
#
# 判据
#   ① 相同温度带内 B 的"每负载秒完成量" ≥ A  → 接管未损害性能管理
#   ② B 明显更低（< 98%）                      → 警示：接管可能影响功耗/频率策略
#   ③ B 在同样墙钟时间内累计更多负载秒          → 接管让散热更好、能干更多活
# ─────────────────────────────────────────────────────────────────────
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/.build/debug/fanpilot"
BENCH="$REPO/Tools/cpu-bench.py"
PY="$HOME/h3-env/bin/python"
SMC="$HOME/smctemp.py"

RPM=4500                 # B 臂固定转速（够凉，但不至于最吵）
DUR=120                  # 每臂墙钟时长（秒）
BAND_LO=76
BAND_HI=84
HARD_MAX=88              # 硬上限：达到即停负载
COOL_TO=62
COOL_TIMEOUT=300
IDLE_ONLY=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --rpm) RPM="$2"; shift ;;
    --duration) DUR="$2"; shift ;;
    --band) BAND_LO="${2%-*}"; BAND_HI="${2#*-}"; shift ;;
    --max-temp) HARD_MAX="$2"; shift ;;
    --idle-only) IDLE_ONLY=1 ;;
    --yes) ASSUME_YES=1 ;;
  esac
  shift
done

[ -x "$BIN" ] || { echo "先构建：cd ~/Documents/FanPilot && swift build"; exit 1; }
[ -f "$BENCH" ] || { echo "缺少基准脚本 $BENCH"; exit 1; }
if [ "$(id -u)" != "0" ]; then echo "请用 sudo 运行：sudo $0"; exit 1; fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/tmp/fanpilot-absafe-$STAMP"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  FanPilot · 降频/接管 对照实验（安全版）                          ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo "  输出目录 : $OUT"
if [ "$IDLE_ONLY" = 1 ]; then
  echo "  模式     : --idle-only（完全不加载，零额外发热）"
else
  echo "  模式     : 温度带控制 ${BAND_LO}–${BAND_HI}°C（硬上限 ${HARD_MAX}°C）"
  echo "  A 臂     : 系统自动（Apple 曲线）"
  echo "  B 臂     : 本软件接管（Ftst=1 + ${RPM} RPM）"
  echo "  每臂时长 : ${DUR}s 墙钟"
fi
echo
echo "  安全：温度带控制 + 硬上限 + 死人开关 + 收尾强制校验。"
echo "        预期峰值 ≤ ${HARD_MAX}°C（对比：Apple 曲线自己跑满载会到 112°C）。"
if [ "$ASSUME_YES" != 1 ]; then
  echo
  read -r -p "  确认开始？(输入 y 回车) " ans
  [ "$ans" = "y" ] || { echo "已取消。"; exit 0; }
fi

( sleep 900; "$BIN" auto >/dev/null 2>&1; echo "[deadman] 已无条件交还系统" ) &
DEADMAN=$!

hotspot() { "$PY" "$SMC" --json 2>/dev/null | "$PY" -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(0); raise SystemExit
s=d['sensors']; soc={k:v for k,v in s.items() if k.startswith('Tp')}
print(round(max(soc.values()),1) if soc else 0)"; }

fanrpm() { "$BIN" fans 2>/dev/null | awk '/^  F0:/{for(i=1;i<NF;i++) if ($i ~ /^[0-9]+$/ && $(i+1)=="RPM") {print $i; exit}}' | grep -E '^[0-9]+$' || echo 0; }
mode_of() { "$BIN" fans 2>/dev/null | awk -v k="$1" '$0 ~ "模式键 "k {print $4; exit}'; }
ftst_val() { "$PY" -c "
import sys; sys.path.insert(0,'$HOME')
from smctemp import SMC
try: print(int(SMC().read('Ftst')[0] or 0))
except Exception: print(-1)" 2>/dev/null || echo -1; }
is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

ensure_auto() {
  "$BIN" auto >/dev/null 2>&1
  sleep 1
  [ "$(mode_of F0Md)" = "1" ] && { echo "   ⚠️ 仍在 manual，重试…"; sleep 2; "$BIN" auto >/dev/null 2>&1; }
}

cleanup() {
  echo
  echo "── 收尾：交还系统控制 ──"
  ensure_auto
  echo "   F0Md=$(mode_of F0Md)  Ftst=$(ftst_val)  （Ftst 应为 0）"
  kill "$DEADMAN" 2>/dev/null
  echo "── 原始数据：$OUT ──"
}
trap cleanup EXIT INT TERM

wait_cool() {
  local t=0 h hi
  while [ "$t" -lt "$COOL_TIMEOUT" ]; do
    h=$(hotspot); hi=${h%%.*}
    is_int "$hi" || hi=999
    [ "$hi" -le "$COOL_TO" ] && { echo "   已冷却到 ${h}°C"; return 0; }
    sleep 10; t=$((t + 10))
    [ $((t % 30)) -eq 0 ] && echo "   冷却中… ${h}°C (${t}s)"
  done
  echo "   ⚠️ 冷却超时（$(hotspot)°C），以当前温度继续"
}

start_trace() {
  ( while :; do printf '%s,%s,%s\n' "$(date +%s)" "$(hotspot)" "$(fanrpm)"; sleep 2; done ) > "$1" &
  echo $!
}

run_arm() {
  local arm="$1" mode="$2"
  echo
  echo "════════ ${arm} 臂（${mode}）════════"
  wait_cool
  echo "   起点 $(hotspot)°C  F0Md=$(mode_of F0Md)  Ftst=$(ftst_val)  RPM=$(fanrpm)"

  local FP_PID=""
  if [ "$mode" = "fanpilot" ]; then
    "$BIN" run --profile fixed --rpm "$RPM" --always-on --duration $((DUR + 60)) --quiet \
      > "$OUT/$arm-fanpilot.log" 2>&1 &
    FP_PID=$!
    sleep 6
    echo "   接管后 F0Md=$(mode_of F0Md)  Ftst=$(ftst_val)  RPM=$(fanrpm)"
  else
    ensure_auto
  fi

  local pm="$OUT/$arm-powermetrics.txt" tr="$OUT/$arm-trace.csv"
  local SP TP
  /usr/bin/powermetrics -A -i 1000 -n $((DUR + 40)) -o "$pm" >/dev/null 2>&1 &
  SP=$!
  TP=$(start_trace "$tr")

  local total_iters=0 load_seconds=0 bursts=0 t0 now h hi burst json it
  t0=$(date +%s)
  if [ "$IDLE_ONLY" = 1 ]; then
    echo "   空闲观察 ${DUR}s（不加载）…"
    while [ $(( $(date +%s) - t0 )) -lt "$DUR" ]; do sleep 5; done
  else
    echo "   温度带控制运行 ${DUR}s（负载自动调整以保持在 ${BAND_LO}–${BAND_HI}°C）…"
    while :; do
      now=$(date +%s); [ $((now - t0)) -ge "$DUR" ] && break
      h=$(hotspot); hi=${h%%.*}; is_int "$hi" || hi=$BAND_HI
      if [ "$hi" -ge "$HARD_MAX" ]; then
        echo "   ⚠️ 达到硬上限 ${h}°C，停止负载等待冷却"; sleep 8; continue
      fi
      if [ "$hi" -gt "$BAND_HI" ]; then sleep 4; continue; fi
      burst=3
      [ "$hi" -ge $((BAND_HI - 2)) ] && burst=2
      [ "$hi" -le "$BAND_LO" ] && burst=4
      json=$("$PY" "$BENCH" --seconds "$burst" 2>/dev/null)
      it=$(printf '%s' "$json" | "$PY" -c "import json,sys; print(json.load(sys.stdin)['iterations'])" 2>/dev/null || echo 0)
      is_int "$it" || it=0
      total_iters=$((total_iters + it)); load_seconds=$((load_seconds + burst)); bursts=$((bursts + 1))
      printf "     +%3ds  %5s°C  %5s RPM  累计负载 %ss  完成 %s\n" \
        $(( $(date +%s) - t0 )) "$h" "$(fanrpm)" "$load_seconds" "$total_iters"
    done
  fi
  local wall=$(( $(date +%s) - t0 ))

  kill "$TP" 2>/dev/null; kill "$SP" 2>/dev/null; wait "$TP" 2>/dev/null; wait "$SP" 2>/dev/null
  if [ -n "$FP_PID" ]; then kill "$FP_PID" 2>/dev/null; wait "$FP_PID" 2>/dev/null; ensure_auto; fi

  "$PY" -c "
import json
print(json.dumps({'arm':'${arm}','wall_seconds':${wall},'load_seconds':${load_seconds},
                  'bursts':${bursts},'iterations':${total_iters},
                  'iterations_per_load_second': round(${total_iters}/max(1,${load_seconds}),1)}))" \
    > "$OUT/$arm-duty.json"
  echo "   完成：墙钟 ${wall}s  负载 ${load_seconds}s  完成量 ${total_iters}"
}

echo
echo "════════════════════════════════════════════════════════════════"
run_arm "A" "auto"
run_arm "B" "fanpilot"

echo
echo "════════════════════════════════════════════════════════════════"
echo "对比分析"
"$PY" "$REPO/Tools/ab-report.py" "$OUT"
echo
echo "完成。完整数据在 $OUT"
