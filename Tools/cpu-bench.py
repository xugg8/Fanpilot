#!/usr/bin/env python3
"""可复现的 CPU 基准：固定时长内完成**多少工作量**。

用途：A/B 实验里衡量"同样的时间，机器实际完成了多少计算"。
- 温度越低保频越少 → 单位时间完成更多 → 值越大越好
- 若接管风扇（更凉）却完成更少 → 说明接管干扰了系统的功耗/频率管理

设计要点：
- 纯 CPU、纯用户态，不碰 GPU/磁盘/网络（避免混淆变量）
- 多进程跑满所有核心（默认 = 物理核数）
- 每轮工作固定（sha256 固定长度输入 + 整数运算），迭代次数即工作量
- 输出一行 JSON，便于汇总
"""
import hashlib
import json
import multiprocessing as mp
import os
import sys
import time


def worker(seconds: float, queue) -> None:
    deadline = time.monotonic() + seconds
    h = hashlib.sha256()
    payload = b"fanpilot-bench-payload-" * 4
    count = 0
    acc = 0
    while time.monotonic() < deadline:
        # 每轮：一次哈希 + 一段整数运算（混合整数与内存访问，接近真实编译负载）
        for _ in range(200):
            h.update(payload)
            acc = (acc + h.digest()[0]) & 0xFFFFFFFF
        count += 200
    queue.put((count, acc))


def main() -> int:
    seconds = 120.0
    workers = max(1, mp.cpu_count() // 2 + 2)   # Apple Silicon: 性能核 + 部分能效核
    for i, a in enumerate(sys.argv[1:]):
        if a == "--seconds" and i + 2 <= len(sys.argv) - 1:
            seconds = float(sys.argv[i + 2])
        if a == "--workers" and i + 2 <= len(sys.argv) - 1:
            workers = int(sys.argv[i + 2])

    q: mp.Queue = mp.Queue()
    procs = [mp.Process(target=worker, args=(seconds, q)) for _ in range(workers)]
    t0 = time.monotonic()
    for p in procs:
        p.start()
    total = 0
    for _ in procs:
        c, _ = q.get()
        total += c
    for p in procs:
        p.join()
    elapsed = time.monotonic() - t0

    result = {
        "seconds": round(elapsed, 2),
        "workers": workers,
        "iterations": total,
        "per_second": round(total / elapsed, 1) if elapsed > 0 else 0,
        "loadavg_end": [round(x, 2) for x in os.getloadavg()],
    }
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
