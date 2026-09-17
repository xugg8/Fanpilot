#!/bin/bash
# make-app.sh —— 把 SwiftPM 产物打包成可双击的 FanPilot.app
#
# 用法：  ~/Documents/FanPilot/Tools/make-app.sh [--release]
#
# 为什么要打包：菜单栏 App 需要 Info.plist 才能：
#   · LSUIElement=true → 不出现在 Dock / Cmd-Tab
#   · 有 bundle id      → 后续通知、登录项、签名都需要
# SwiftPM 直接产出的裸可执行文件没有这些。
set -eu

# ★ 按脚本自身位置推断仓库根（克隆到任何目录都能用），支持 FANPILOT_REPO 覆盖
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
DIR="${FANPILOT_REPO:-$(cd "$SELF_DIR/.." && pwd)}"
CONF="debug"
[ "${1:-}" = "--release" ] && CONF="release"
VERSION="${FANPILOT_VERSION:-1.0.0}"   # 发布时可用 FANPILOT_VERSION=x.y.z 覆盖

cd "$DIR"
echo "▸ 构建（${CONF}）…"
# FANPILOT_NO_SANDBOX=1 可关掉 SwiftPM 自带沙箱（某些受限环境下 sandbox-exec 会失败）
SWIFT_FLAGS=""
[ -n "${FANPILOT_NO_SANDBOX:-}" ] && SWIFT_FLAGS="--disable-sandbox"
if [ "$CONF" = "release" ]; then swift build -c release $SWIFT_FLAGS; else swift build $SWIFT_FLAGS; fi

# ★ 注意：产物名必须是 FanPilotMenu。若叫 FanPilot，在大小写不敏感的 APFS 上
#   会与 CLI 的 fanpilot 相互覆盖（已踩过这个坑）。
SRC="$DIR/.build/$CONF/FanPilotMenu"
APP="$DIR/build/FanPilot.app"
[ -x "$SRC" ] || { echo "❌ 找不到产物 $SRC"; exit 1; }

echo "▸ 组装 bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC" "$APP/Contents/MacOS/FanPilot"   # bundle 内部仍叫 FanPilot

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FanPilot</string>
  <key>CFBundleDisplayName</key><string>FanPilot</string>
  <!-- ⚠️ 不要用回 com.fanpilot.menubar：该 ID 在开发机上被 macOS
       持久化记录了"菜单栏项被隐藏"的状态（详见 Docs/COMPATIBILITY.md「菜单栏图标不显示」），
       换 ID 即可恢复。 -->
  <key>CFBundleIdentifier</key><string>com.fanpilot.app</string>
  <key>CFBundleExecutable</key><string>FanPilot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- 菜单栏 App：不占 Dock、不进 Cmd-Tab -->
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>FanPilot (local build)</string>
</dict>
</plist>
PLIST

# 本地自签：避免 Gatekeeper 拦截（不需要开发者账号）
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP" >/dev/null 2>&1 \
    && echo "▸ 已用 ad-hoc 签名" \
    || echo "▸ 签名跳过（不影响本机运行）"
fi

echo "✅ 生成：$APP"
echo "   运行：open '$APP'"
echo "   停止：osascript -e 'quit app \"FanPilot\"'   或面板里的「退出」按钮"
