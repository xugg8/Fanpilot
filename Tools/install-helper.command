#!/bin/bash
# 双击运行：安装 FanPilot 特权组件（会要求输入一次登录密码）
# 按脚本自身位置定位（sudo/终端环境下 $HOME 不可靠；且 ~/Documents 受 TCC 保护）
cd "$(dirname "$0")/.." || exit 1
clear
cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║  FanPilot · 安装特权组件                                      ║
╠══════════════════════════════════════════════════════════════╣
║  它会做什么：                                                 ║
║   1. 把 helper 装到 /usr/local/libexec/fanpilot-helper        ║
║   2. 注册 root LaunchDaemon（开机自启、崩溃自动拉起）          ║
║   3. 启动并打印状态                                           ║
║                                                              ║
║  安全设计：                                                   ║
║   · helper 启动时**第一时间交还系统风扇控制**（红线）          ║
║   · 只听 Unix socket，并用 getpeereid() 校验对端 UID          ║
║   · 卸载：sudo ./Tools/install-helper.sh uninstall            ║
╚══════════════════════════════════════════════════════════════╝

BANNER
LOG="/tmp/fanpilot-install-last.log"
sudo ./Tools/install-helper.sh diagnose 2>&1 | tee "$LOG"
sudo ./Tools/install-helper.sh install 2>&1 | tee -a "$LOG"
echo
echo "════════════════════════════════════════════"
echo "完成。日志：$LOG"
echo "回到菜单栏的 FanPilot 面板，按钮应已激活。"
echo "════════════════════════════════════════════"
read -n 1 -s -r -p "按任意键关闭…"
