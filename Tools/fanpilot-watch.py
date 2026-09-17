#!/usr/bin/env python3
# fanpilot-watch.py —— FanPilot 独立监测脚本（压测看门狗）
#
# 用途：在本地大模型等高负载压测期间，从**第三方视角**监测 FanPilot 是否正常工作。
#       不依赖 FanPilot 自己的 CSV 日志，直接走 socket 轮询 helper、交叉验证心跳文件。
#
# 监测项（压测场景最要命的几类事故）：
#   1. helper 进程死亡/重启（pid 变化 + socket 连不上）
#   2. 心跳过期（>heartbeatMaxAge 判定 helper 假活）
#   3. 接管丢失：helper 声称 controlling 但 SMC 模式不是 manual(1)（固件抢回）
#   4. 转速脱靶：实际转速连续多个周期偏离目标超过 fanDevRPM
#   5. 温度失控：hotspot 超过 hotWarn，或监控期间创新高
#   6. 状态突变：armed 开关、ftst、档位变化
#
# 用法：
#   python3 fanpilot-watch.py                 # 一直跑到 Ctrl+C
#   python3 fanpilot-watch.py --duration 600  # 跑 10 分钟自动结束
#   python3 fanpilot-watch.py --interval 2    # 轮询间隔（默认 2s）
#
# 输出：
#   控制台 + 日志文件（默认 /tmp/fanpilot-watch-<日期>.log，JSONL 事件在同目录 .events.jsonl）
#   结束时打印统计摘要（重启次数、事件数、温度峰值、脱靶次数）。

import argparse
import datetime as dt
import json
import os
import signal
import socket
import sys
import time

SOCKET_PATH = "/var/run/fanpilot.sock"
HEARTBEAT_PATH = "/tmp/fanpilot-helper.heartbeat"


def now_str():
    return dt.datetime.now().strftime("%H:%M:%S")


def rpc(req, timeout=4.0):
    """与 helper 的一次 JSON-RPC（换行分隔）。失败抛异常，由调用方归类。"""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(SOCKET_PATH)
        s.sendall((json.dumps(req) + "\n").encode())
        buf = b""
        deadline = time.time() + timeout
        while b"\n" not in buf:
            left = deadline - time.time()
            if left <= 0:
                raise TimeoutError("recv timeout")
            s.settimeout(left)
            chunk = s.recv(4096)
            if not chunk:
                raise ConnectionError("peer closed (0 bytes)")
            buf += chunk
        return json.loads(buf.split(b"\n")[0])
    finally:
        s.close()


def heartbeat_age():
    try:
        return time.time() - os.path.getmtime(HEARTBEAT_PATH)
    except OSError:
        return None


class Watcher:
    def __init__(self, interval, hot_warn, fan_dev_rpm, dev_streak, heartbeat_max_age):
        self.interval = interval
        self.hot_warn = hot_warn
        self.fan_dev_rpm = fan_dev_rpm
        self.dev_streak_need = dev_streak
        self.heartbeat_max_age = heartbeat_max_age

        self.helper_pid = None
        self.dev_streak = 0
        self.max_hot = 0.0
        self.max_hot_at = None
        self.restarts = 0
        self.event_count = 0
        self.poll_count = 0
        self.rpc_fail_streak = 0
        self.last_states = {}
        self.suppress_until = {}   # 事件类名 -> 静默期截止时间（避免刷屏）
        self.start_at = time.time()

        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.log_path = f"/tmp/fanpilot-watch-{stamp}.log"
        self.events_path = f"/tmp/fanpilot-watch-{stamp}.events.jsonl"

    def log(self, msg):
        line = f"[{now_str()}] {msg}"
        print(line, flush=True)
        with open(self.log_path, "a") as f:
            f.write(line + "\n")

    def event(self, kind, detail, level="WARN"):
        """去抖后记录一个事件：控制台/日志 + JSONL。同类事件 60s 内不重复。"""
        t = time.time()
        if t < self.suppress_until.get(kind, 0):
            return
        self.suppress_until[kind] = t + 60
        self.event_count += 1
        rec = {"t": now_str(), "kind": kind, "level": level, "detail": detail}
        self.log(f"{level} [{kind}] {detail}")
        with open(self.events_path, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    def poll_once(self):
        self.poll_count += 1
        # ---- ① helper 是否可达 ----
        try:
            st = rpc({"cmd": "status"}, timeout=max(3.0, self.interval))
            self.rpc_fail_streak = 0
        except Exception as e:
            self.rpc_fail_streak += 1
            hb = heartbeat_age()
            hb_txt = f"{hb:.0f}s前" if hb is not None else "文件不存在"
            self.event("RPC_FAIL",
                       f"status 调用失败（连续{self.rpc_fail_streak}次）：{type(e).__name__}: {e}；心跳：{hb_txt}")
            return None
        if self.rpc_fail_streak > 0:
            self.log(f"helper 恢复响应（此前连续失败 {self.rpc_fail_streak} 次）")
            self.rpc_fail_streak = 0

        # ---- ② pid 变化 = 重启 ----
        pid = st.get("helperPID")
        if self.helper_pid and pid and pid != self.helper_pid:
            self.restarts += 1
            self.event("HELPER_RESTART",
                       f"helper 进程变更 {self.helper_pid} -> {pid}（第{self.restarts}次）；"
                       f"armed={st.get('armed')} controlling={st.get('controlling')}")
        self.helper_pid = pid

        # ---- ③ 心跳新鲜度（与 socket 可达交叉验证：socket 通但心跳过期 = 假活）----
        hb = heartbeat_age()
        if hb is None:
            self.event("HEARTBEAT_MISSING", f"心跳文件不存在（pid={pid}），helper 可能异常")
        elif hb > self.heartbeat_max_age:
            self.event("HEARTBEAT_STALE",
                       f"心跳过期：{hb:.0f}s 未更新（阈值 {self.heartbeat_max_age:.0f}s），"
                       f"但 socket 仍可通 —— 疑似假活或时钟异常")

        # ---- ④ 接管一致性：声称接管，SMC 模式必须是 manual(1) ----
        # mode=0 表示尚未取得回读（helper 刚启动/重启窗口），不算被抢回
        modes = st.get("modes") or []
        controlling = st.get("controlling")
        modes_live = modes and all(m > 0.5 for m in modes)
        if controlling and modes_live and any(abs(m - 1) > 0.5 for m in modes):
            # helper 上报的 mode 回读怪癖：mode 非 manual 但目标寄存器仍是我方写入值
            # （转速跟手，写路径有效）→ 降级为 INFO 提示，不算被抢回
            if st.get("modeQuirk"):
                self.event("MODE_QUIRK", f"mode 回读怪癖：modes={modes} 但目标仍为我方写入值（控制有效）",
                           level="INFO")
            else:
                self.event("MODE_RECLAIMED",
                           f"声称接管中但模式非 manual：modes={modes}（固件可能抢回控制）")
        if not controlling and modes and all(abs(m - 1) < 0.5 for m in modes):
            self.event("ORPHAN_MANUAL",
                       f"声称未接管但模式仍是 manual：modes={modes}（无主手动态，危险）")

        # ---- ⑤ 转速脱靶：接管时实际转速连续偏离目标 ----
        actual = st.get("fanRPM") or []
        targets = st.get("fanTargets") or []
        if controlling and actual and targets and len(actual) == len(targets):
            devs = [a - g for a, g in zip(actual, targets)]
            worst = max(abs(d) for d in devs)
            if worst > self.fan_dev_rpm:
                self.dev_streak += 1
                if self.dev_streak >= self.dev_streak_need:
                    self.event("FAN_DEVIATION",
                               f"实际转速连续{self.dev_streak}次偏离目标>={self.fan_dev_rpm:.0f}RPM："
                               f"actual={actual} target={targets} dev={[round(d) for d in devs]}")
                    self.dev_streak = 0
            else:
                self.dev_streak = 0

        # ---- ⑥ 温度 ----
        hot = st.get("hotspot")
        if hot is not None:
            if hot > self.max_hot:
                self.max_hot = hot
                self.max_hot_at = now_str()
            if hot >= self.hot_warn:
                self.event("HOT_TEMP",
                           f"hotspot {hot:.1f}°C >= {self.hot_warn}°C（fanRPM={actual}）",
                           level="HOT")

        # ---- ⑦ 状态突变 ----
        for key in ("armed", "armedProfile", "ftst", "profile"):
            cur = st.get(key)
            if key in self.last_states and self.last_states[key] != cur:
                self.event("STATE_CHANGE", f"{key}: {self.last_states[key]} -> {cur}", level="INFO")
            self.last_states[key] = cur

        return st

    def summary_line(self, st):
        if st is None:
            return "helper 不可达"
        hot = st.get("hotspot")
        hot_txt = f"{hot:.1f}" if hot is not None else "n/a"
        pw = st.get("power")
        pw_txt = f"{pw:.0f}W" if pw is not None else "n/a"
        return (f"poll#{self.poll_count} pid={st.get('helperPID')} "
                f"接管={st.get('controlling')} 档位={st.get('profile')} armed={st.get('armed')} | "
                f"热点 {hot_txt}°C 功率 {pw_txt} | "
                f"actual={st.get('fanRPM')} target={st.get('fanTargets')} modes={st.get('modes')}")

    def run(self, duration):
        self.log(f"FanPilot 独立监测启动：interval={self.interval}s hot_warn={self.hot_warn}°C "
                 f"fan_dev={self.fan_dev_rpm}RPM/{self.dev_streak_need}次 heartbeat_max_age={self.heartbeat_max_age}s")
        self.log(f"日志：{self.log_path}")
        self.log(f"事件：{self.events_path}")
        deadline = time.time() + duration if duration else None
        next_summary = 0
        try:
            while True:
                t0 = time.time()
                try:
                    st = self.poll_once()
                except Exception as e:  # 监测器自身绝不能死
                    self.event("WATCHER_BUG", f"监测器内部错误：{type(e).__name__}: {e}", level="BUG")
                    st = None
                if time.time() >= next_summary:
                    self.log(self.summary_line(st))
                    next_summary = time.time() + 15
                if deadline and time.time() >= deadline:
                    break
                time.sleep(max(0.0, self.interval - (time.time() - t0)))
        except KeyboardInterrupt:
            self.log("收到 Ctrl+C，停止监测")
        self.final_report()

    def final_report(self):
        dur = time.time() - self.start_at
        self.log("―――― 监测结束・统计摘要 ――――")
        self.log(f"监测时长 {dur/60:.1f} 分钟，轮询 {self.poll_count} 次")
        self.log(f"helper 重启 {self.restarts} 次 | 事件 {self.event_count} 个")
        self.log(f"温度峰值 {self.max_hot:.1f}°C @ {self.max_hot_at}")
        self.log(f"完整日志：{self.log_path}")


def main():
    ap = argparse.ArgumentParser(description="FanPilot 独立监测（压测看门狗）")
    ap.add_argument("--interval", type=float, default=2.0, help="轮询间隔秒（默认 2）")
    ap.add_argument("--duration", type=float, default=0, help="运行秒数，0=一直运行")
    ap.add_argument("--hot-warn", type=float, default=95.0, help="hotspot 告警阈值 °C（默认 95）")
    ap.add_argument("--fan-dev-rpm", type=float, default=150.0, help="转速脱靶阈值 RPM（默认 150）")
    ap.add_argument("--dev-streak", type=int, default=3, help="连续脱靶几次才报警（默认 3）")
    ap.add_argument("--heartbeat-max-age", type=float, default=8.0, help="心跳过期阈值秒（默认 8）")
    args = ap.parse_args()

    w = Watcher(args.interval, args.hot_warn, args.fan_dev_rpm,
                args.dev_streak, args.heartbeat_max_age)
    # SIGTERM → 转成 KeyboardInterrupt 走统一的收尾报告
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt))
    w.run(args.duration or None)


if __name__ == "__main__":
    main()
