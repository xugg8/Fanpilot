#!/usr/bin/env python3
"""事故复盘：从 FanPilot 的会话 CSV 里量化"高温时到底有没有人在管"。

用法:
  python3 Tools/incident-report.py                      # 用今天的 CSV
  python3 Tools/incident-report.py <csv> [<csv> ...]
  python3 Tools/incident-report.py --all                # 全部 CSV

背景（2026-09-13 真实事故）：用户跑本地模型，温度到 104.6°C，
FanPilot 的 controlling 一直是 0 —— 因为 helper 每 60~90 秒崩一次，
每次被 launchd 拉起后都会"启动即交还系统"（安全红线），
于是用户看到的现象是：点了「最强清凉」，风扇转一分钟就停，温度继续涨。

关键判据：
  · hotspot ≥ 95°C 且 protecting=0 的时长  =  **本该被保护却没有保护的时间**
  · mode=1（手动）时长                      =  真正在接管的时间
  · helper 重启事件                          =  控制为什么中断
"""
import csv
import sys
from datetime import datetime, timedelta
from pathlib import Path

LOG_DIR = Path.home() / "Library/Application Support/FanPilot/logs"
HOT = 95.0          # "应该有人管"的温度线
CRIT = 100.0


def load(path):
    rows = []
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        for r in csv.DictReader(f):
            def num(k, cast=float):
                v = (r.get(k) or "").strip()
                try:
                    return cast(v)
                except ValueError:
                    return None
            rows.append({
                "time": r.get("time", ""),
                "epoch": num("epoch", float),
                "event": (r.get("event") or "").strip(),
                "hot": num("hotspot_c"),
                "peak": num("peak_c"),
                "f0": num("fan0_rpm"), "f1": num("fan1_rpm"),
                "t0": num("fan0_target"),
                "m0": num("m0_mode", float) if "m0_mode" in r else num("fan0_mode"),
                "ctrl": (r.get("controlling") or "").strip() == "1",
                "helper": (r.get("helper") or "").strip(),
            })
    return [r for r in rows if r["epoch"]]


def span(rows):
    """采样间隔（秒），用于把"采样数"换算成时长"""
    ep = [r["epoch"] for r in rows if r["epoch"]]
    if len(ep) < 2:
        return 6.0
    d = sorted(ep[i + 1] - ep[i] for i in range(len(ep) - 1))
    return d[len(d) // 2]


def episodes(rows, pred, dt):
    """把连续满足 pred 的采样合成"时段" """
    out, cur = [], None
    for r in rows:
        if pred(r):
            if cur is None:
                cur = {"start": r, "end": r, "n": 1, "maxh": r["hot"] or 0, "maxf": r["f0"] or 0}
            else:
                cur["end"] = r; cur["n"] += 1
                cur["maxh"] = max(cur["maxh"], r["hot"] or 0)
                cur["maxf"] = max(cur["maxf"], r["f0"] or 0)
        elif cur is not None:
            out.append(cur); cur = None
    if cur:
        out.append(cur)
    for e in out:
        e["secs"] = e["n"] * dt
    return out


def report(path, dt_override=None):
    rows = load(path)
    if not rows:
        print(f"（{path.name} 没有数据）")
        return
    dt = dt_override or span(rows)
    hot = [r for r in rows if r["hot"] is not None]
    ctrl = [r for r in rows if r["ctrl"]]
    manual = [r for r in rows if r["m0"] is not None and abs(r["m0"] - 1) < 0.5]

    print(f"\n{'='*74}")
    print(f"文件: {path.name}   采样 {len(rows)} 条  ≈{dt:.0f}s/条  "
          f"覆盖 {rows[0]['time']}–{rows[-1]['time']}")
    print(f"{'='*74}")

    if hot:
        top = max(hot, key=lambda r: r["hot"])
        print(f"最高实测温度 : {top['hot']:.1f}°C @ {top['time']}  "
              f"(风扇 {top['f0']:.0f}/{top['f1']:.0f} RPM, 接管={top['ctrl']})")
    print(f"真正接管时长 : {len(ctrl)*dt/60:.1f} 分钟（{len(ctrl)} 条采样）")
    print(f"手动模式时长 : {len(manual)*dt/60:.1f} 分钟（mode=1）")

    # ① 关键指标：高温却没有保护
    bad = episodes(rows, lambda r: (r["hot"] or 0) >= HOT and not r["ctrl"], dt)
    bad_secs = sum(e["secs"] for e in bad)
    print(f"\n★ 关键指标：温度 ≥{HOT:.0f}°C 而**无人保护**的累计时长 = "
          f"{bad_secs/60:.1f} 分钟（{len(bad)} 段）")
    for e in bad[:12]:
        print(f"    {e['start']['time']} → {e['end']['time']}  "
              f"{e['secs']/60:4.1f} 分钟  峰值 {e['maxh']:.1f}°C  "
              f"期间风扇最高 {e['maxf']:.0f} RPM")
    if len(bad) > 12:
        print(f"    …还有 {len(bad)-12} 段")

    # ② ≥100°C 且无保护
    worse = episodes(rows, lambda r: (r["hot"] or 0) >= CRIT and not r["ctrl"], dt)
    if worse:
        print(f"\n★★ 其中 ≥{CRIT:.0f}°C 且无保护：{sum(e['secs'] for e in worse)/60:.1f} 分钟"
              f"（{len(worse)} 段）")
        for e in worse[:8]:
            print(f"    {e['start']['time']} → {e['end']['time']}  "
                  f"{e['secs']/60:4.1f} 分钟  峰值 {e['maxh']:.1f}°C")

    # ③ 保护"断掉"的时刻：从接管变成不接管，且温度还高
    drops = []
    for a, b in zip(rows, rows[1:]):
        if a["ctrl"] and not b["ctrl"] and (b["hot"] or 0) >= HOT:
            drops.append((a, b))
    if drops:
        print(f"\n★ 保护中断（前一条在接管、后一条没接管，且温度仍 ≥{HOT:.0f}°C）: {len(drops)} 次")
        for a, b in drops[:10]:
            print(f"    {b['time']}  {a['hot']:.1f}°C → {b['hot']:.1f}°C  "
                  f"风扇 {a['f0']:.0f} → {b['f0'] or 0:.0f} RPM   mode {a['m0']} → {b['m0']}")
    else:
        print(f"\n  保护中断次数: 0")

    # ④ 事件行
    ev = [r for r in rows if r["event"]]
    if ev:
        print(f"\n事件（{len(ev)} 条）:")
        for r in ev[:30]:
            print(f"    {r['time']}  {r['event']}")
        if len(ev) > 30:
            print(f"    …还有 {len(ev)-30} 条（用 --all 分文件看）")

    # ⑤ 控制中断：helper 崩溃最直接的证据
    #    helper 一崩，socket 消失，App 会退化到"只读监控（未安装特权组件）"。
    #    这条事件 + 当时温度偏高 = 用户说的"风扇转一分钟就停"。
    cut = [r for r in rows if r["event"] and "只读监控" in r["event"]]
    restarts = [r for r in rows if r["event"] and "HELPER_RESTART" in r["event"]]
    if cut or restarts:
        print(f"\n★ 控制中断事件: 只读监控 {len(cut)} 次, helper 重启 {len(restarts)} 次")
        for r in cut[:10]:
            near = [x for x in rows
                    if x["epoch"] and r["epoch"] and abs(x["epoch"] - r["epoch"]) <= 90
                    and (x["hot"] or 0) > 0]
            mx = max((x["hot"] for x in near), default=None)
            print(f"    {r['time']}  掉线（当时最高温度 {mx:.1f}°C）" if mx
                  else f"    {r['time']}  掉线")
        for r in restarts[:10]:
            print(f"    {r['time']}  {r['event']}")

    # ⑥ 结论
    print("\n" + "-"*74)
    problems = []
    if bad_secs >= 60:
        problems.append(f"{bad_secs/60:.1f} 分钟「温度≥{HOT:.0f}°C 却无人保护」")
    if cut:
        problems.append(f"{len(cut)} 次控制中断（helper 掉线/崩溃）")
    if restarts:
        problems.append(f"{len(restarts)} 次 helper 重启")
    if problems:
        print("结论：发现 " + "；".join(problems) + " —— 必须修。")
        print("      典型症状：点了接管 → 风扇拉满 → 一两分钟后突然掉回低速、温度继续涨。")
    else:
        print("结论：本次记录未发现控制中断或长时间「高温无保护」。")
    print("-"*74)


def main():
    args = [a for a in sys.argv[1:]]
    if not args or args == ["--all"]:
        files = sorted(LOG_DIR.glob("*.csv"))
        if not args:
            files = files[-1:]
    else:
        files = [Path(a) for a in args]
    for f in files:
        if not f.exists():
            print(f"找不到文件: {f}")
            continue
        report(f)


if __name__ == "__main__":
    main()
