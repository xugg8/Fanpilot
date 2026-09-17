#!/usr/bin/env python3
"""A/B 对照分析：解析 throttle-ab.sh 的产物，给出结论。

用法： python3 ab-report.py <输出目录>
"""
import json
import os
import re
import statistics
import sys

# powermetrics 各版本字段名有差异 —— 全部容忍缺失，取到哪个用哪个
PATTERNS = {
    "p_freq": re.compile(r"P-Cluster HW active frequency:\s*([\d.]+)\s*MHz", re.I),
    "e_freq": re.compile(r"E-Cluster HW active frequency:\s*([\d.]+)\s*MHz", re.I),
    "s_freq": re.compile(r"S-Cluster HW active frequency:\s*([\d.]+)\s*MHz", re.I),
    "cpu_thermal": re.compile(r"CPU Thermal level:\s*(\d+)", re.I),
    "gpu_thermal": re.compile(r"GPU Thermal level:\s*(\d+)", re.I),
    "combined_mw": re.compile(r"Combined Power \(CPU \+ GPU \+ ANE\):\s*([\d.]+)\s*mW", re.I),
    "cpu_mw": re.compile(r"CPU Power:\s*([\d.]+)\s*mW", re.I),
    "gpu_mw": re.compile(r"GPU Power:\s*([\d.]+)\s*mW", re.I),
    "pressure": re.compile(r"pressure[^\n:]*:\s*(\w+)", re.I),
}


def parse_powermetrics(path):
    """返回 {metric: [values]}，只保留数值型指标（pressure 单独计数）"""
    out = {k: [] for k in PATTERNS if k != "pressure"}
    pressure = []
    if not os.path.exists(path):
        return out, pressure
    with open(path, errors="replace") as f:
        for line in f:
            for name, pat in PATTERNS.items():
                m = pat.search(line)
                if not m:
                    continue
                if name == "pressure":
                    pressure.append(m.group(1))
                else:
                    try:
                        out[name].append(float(m.group(1)))
                    except ValueError:
                        pass
    return out, pressure


def parse_trace(path):
    """自身采样: epoch,hotspot,rpm"""
    ts, hot, rpm = [], [], []
    if not os.path.exists(path):
        return ts, hot, rpm
    with open(path, errors="replace") as f:
        for line in f:
            parts = line.strip().split(",")
            if len(parts) != 3:
                continue
            try:
                ts.append(float(parts[0])); hot.append(float(parts[1])); rpm.append(float(parts[2]))
            except ValueError:
                continue
    return ts, hot, rpm


def bench(path):
    """优先读安全版的 duty 结果（迭代量 + 负载秒），回退到固定时长版"""
    duty = path.replace("-bench.json", "-duty.json")
    try:
        with open(duty) as f:
            d = json.load(f)
        return (d.get("iterations"), d.get("iterations_per_load_second"),
                d.get("wall_seconds"), d.get("load_seconds"))
    except Exception:
        pass
    try:
        with open(path) as f:
            d = json.load(f)
        return d.get("iterations"), d.get("per_second"), d.get("seconds"), d.get("seconds")
    except Exception:
        return None, None, None, None


def stat(vals, q=0.5):
    if not vals:
        return None
    vs = sorted(vals)
    return vs[min(len(vs) - 1, int(q * (len(vs) - 1)))]


def summarize_arm(outdir, arm):
    ts, hot, rpm = parse_trace(os.path.join(outdir, f"{arm}-trace.csv"))
    pm, pressure = parse_powermetrics(os.path.join(outdir, f"{arm}-powermetrics.txt"))
    it, per_s, secs, load_s = bench(os.path.join(outdir, f"{arm}-bench.json"))

    # 稳态段 = 后 50%（排除升温过程）
    n = len(hot)
    tail = slice(n // 2, n) if n else slice(0, 0)
    d = {
        "arm": arm,
        "iterations": it,
        "per_second": per_s,
        "seconds": secs,
        "load_seconds": load_s,
        "temp_peak": max(hot) if hot else None,
        "temp_steady_mean": round(statistics.mean(hot[tail]), 1) if n else None,
        "rpm_mean": round(statistics.mean(rpm[tail]), 0) if n else None,
        "rpm_max": max(rpm) if rpm else None,
        "p_freq_mean": round(statistics.mean(pm["p_freq"]), 0) if pm["p_freq"] else None,
        "p_freq_max": max(pm["p_freq"]) if pm["p_freq"] else None,
        "e_freq_mean": round(statistics.mean(pm["e_freq"]), 0) if pm["e_freq"] else None,
        "cpu_thermal_max": max(pm["cpu_thermal"]) if pm["cpu_thermal"] else None,
        "gpu_thermal_max": max(pm["gpu_thermal"]) if pm["gpu_thermal"] else None,
        "combined_power_mean": round(statistics.mean(pm["combined_mw"]) / 1000, 1) if pm["combined_mw"] else None,
        "cpu_power_mean": round(statistics.mean(pm["cpu_mw"]) / 1000, 1) if pm["cpu_mw"] else None,
        "pressure_counts": {p: pressure.count(p) for p in set(pressure)} if pressure else {},
    }
    return d


def wpad(text, width):
    """按显示宽度补空格（CJK 字符占 2 列）"""
    w = sum(2 if ord(c) > 0x2000 else 1 for c in text)
    return text + " " * max(0, width - w)


def fmt(v, unit="", digits=0):
    if v is None:
        return "  n/a"
    if isinstance(v, float):
        return f"{v:.{digits}f}{unit}"
    return f"{v}{unit}"


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    A = summarize_arm(outdir, "A")
    B = summarize_arm(outdir, "B")

    print()
    print("┌──────────────────────────┬──────────────┬──────────────┐")
    print("│ 指标                     │ A 系统自动   │ B 本软件接管 │")
    print("├──────────────────────────┼──────────────┼──────────────┤")
    rows = [
        ("累计负载（秒）", fmt(A.get("load_seconds")), fmt(B.get("load_seconds"))),
        ("完成工作量（次）", fmt(A["iterations"]), fmt(B["iterations"])),
        ("每负载秒完成量", fmt(A["per_second"]), fmt(B["per_second"])),
        ("峰值热点（°C）", fmt(A["temp_peak"], digits=1), fmt(B["temp_peak"], digits=1)),
        ("稳态均值（°C）", fmt(A["temp_steady_mean"], digits=1), fmt(B["temp_steady_mean"], digits=1)),
        ("风扇均值（RPM）", fmt(A["rpm_mean"]), fmt(B["rpm_mean"])),
        ("风扇峰值（RPM）", fmt(A["rpm_max"]), fmt(B["rpm_max"])),
        ("P 核频率均值（MHz）", fmt(A["p_freq_mean"]), fmt(B["p_freq_mean"])),
        ("P 核频率峰值（MHz）", fmt(A["p_freq_max"]), fmt(B["p_freq_max"])),
        ("E 核频率均值（MHz）", fmt(A["e_freq_mean"]), fmt(B["e_freq_mean"])),
        ("CPU Thermal level 峰值", fmt(A["cpu_thermal_max"]), fmt(B["cpu_thermal_max"])),
        ("CPU 功耗均值（W）", fmt(A["cpu_power_mean"], digits=1), fmt(B["cpu_power_mean"], digits=1)),
        ("总功耗均值（W）", fmt(A["combined_power_mean"], digits=1), fmt(B["combined_power_mean"], digits=1)),
    ]
    def rpad(t, w):
        return " " * max(0, w - sum(2 if ord(c) > 0x2000 else 1 for c in t)) + t
    for name, a, b in rows:
        print(f"│ {wpad(name, 24)} │ {rpad(a, 12)} │ {rpad(b, 12)} │")
    print("└──────────────────────────┴──────────────┴──────────────┘")

    if A["pressure_counts"] or B["pressure_counts"]:
        print(f"  热压等级计数  A: {A['pressure_counts']}   B: {B['pressure_counts']}")

    # ── 结论 ──
    print()
    print("结论：")
    if not A["per_second"] or not B["per_second"]:
        print("  ⚠️ 数据不足（缺少基准结果），请检查 A/B-bench.json")
        return 1

    work_ratio = B["per_second"] / A["per_second"]
    temp_drop = None
    if A["temp_steady_mean"] is not None and B["temp_steady_mean"] is not None:
        temp_drop = A["temp_steady_mean"] - B["temp_steady_mean"]

    print(f"  · B/A 每负载秒完成量之比 = {work_ratio:.3f}（1.0 = 同等温度下性能相同）")
    if A.get("load_seconds") and B.get("load_seconds") and A["load_seconds"] > 0:
        gain = (B["load_seconds"] - A["load_seconds"]) / A["load_seconds"] * 100
        print(f"  · 同样墙钟时间内累计负载：A {A['load_seconds']}s vs B {B['load_seconds']}s（{gain:+.0f}%）")
    if temp_drop is not None:
        print(f"  · B 比 A 稳态低 {temp_drop:+.1f}°C")

    # 温度带设计：两臂温度本来就相同，判据只看"同等温度下的完成量"
    if work_ratio >= 0.995:
        print("  ✅ **接管未损害性能管理**：同等温度带内完成量相同或更高")
        print("     → Ftst=1 的顾虑在这类 CPU 负载下不成立，无需 handback 保守开关")
    elif work_ratio >= 0.98:
        print("  ➖ 差异在 ±2% 噪声范围内，可认为性能相当（如需更确定可加长时长）")
    else:
        print(f"  ⚠️ **同等温度下完成量低 {(1-work_ratio)*100:.1f}%** —— 值得警惕：")
        print("     说明接管期间系统给的频率/功耗更低。可能原因：")
        print("     ① Ftst 抑制了 thermalmonitord 的目标断言，影响了功耗策略")
        print("     ② 测量噪声或负载片段长度差异（可先复测一次确认）")
        print("     若确认，建议启用 --handback-temp（高温交还系统）或缩短接管时长")
    if A.get("load_seconds") and B.get("load_seconds"):
        gain = (B["load_seconds"] - A["load_seconds"]) / max(1, A["load_seconds"]) * 100
        if gain > 5:
            print(f"  ✅ 附带收益：同样墙钟时间内 B 能多跑 {gain:.0f}% 的负载时间（散热更好→更少等待）")

    if A["cpu_thermal_max"] is not None and B["cpu_thermal_max"] is not None:
        print(f"  · CPU Thermal level：A={A['cpu_thermal_max']} B={B['cpu_thermal_max']}"
              "（非零说明系统确实进入了热管理；两边都非零 = 接管未阻断系统热管理）")
    print()
    print(f"  原始数据：{outdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
