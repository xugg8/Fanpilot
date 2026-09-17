#!/usr/bin/env python3
"""检查 shell 脚本里「$变量名 紧跟非 ASCII 字符」的隐患。

为什么要查：bash 会把紧跟其后的多字节字符当作变量名的一部分。
`echo "F0Md=$m1，完成"` 会被解析成变量 `m1\\xef\\xbc\\x8c`（未定义），
配合 `set -u` 直接中止脚本 —— 本项目已因此踩坑两次
（一次让 thermal.sh 崩溃，一次让 P1 测试的收尾函数中途退出）。

用法： python3 check-scripts.py <文件或目录> ...
"""
import re
import sys
from pathlib import Path

PAT = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*)([^\x00-\x7F])')


def check(path: Path) -> int:
    bad = 0
    for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        for m in PAT.finditer(line):
            print(f"{path}:{i}: ${m.group(1)} 后面紧跟 {m.group(2)!r} → 应写成 ${{{m.group(1)}}}")
            print(f"    {line.strip()[:100]}")
            bad += 1
    return bad


def main() -> int:
    targets = []
    for a in sys.argv[1:]:
        p = Path(a)
        targets += [q for q in (p.rglob("*") if p.is_dir() else [p])
                    if q.suffix in (".sh", ".command", ".bash") and q.is_file()]
    if not targets:
        print("没有找到脚本文件"); return 0
    total = sum(check(t) for t in targets)
    if total:
        print(f"\n❌ 发现 {total} 处隐患")
        return 1
    print(f"✅ 检查 {len(targets)} 个脚本，未发现该隐患")
    return 0


if __name__ == "__main__":
    sys.exit(main())
