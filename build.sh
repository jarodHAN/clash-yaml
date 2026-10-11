#!/bin/bash
# 构建 clashVPN.app（macOS Intel x86_64），内嵌 mihomo 核心，ad-hoc 签名。
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SCRIPT_DIR/build/clashVPN.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

mkdir -p "$MACOS" "$RES"

# 1) 下载 mihomo 核心（darwin-amd64）如果缺失
if [ ! -f "$SCRIPT_DIR/Resources/mihomo" ]; then
  echo "Downloading mihomo core (darwin-amd64 v1.19.32)…"
  curl -L -o /tmp/mihomo-darwin-amd64.gz \
    "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.32/mihomo-darwin-amd64-v1.19.32.gz"
  gunzip -f /tmp/mihomo-darwin-amd64.gz
  mv /tmp/mihomo-darwin-amd64 "$SCRIPT_DIR/Resources/mihomo"
  chmod +x "$SCRIPT_DIR/Resources/mihomo"
fi

# 1b) 尽力下载地理数据库（geoip.metadb / geosite.dat），失败则跳过（应用将退化为仅域名分流）
mkdir -p "$SCRIPT_DIR/Resources/geo"
for f in "geoip.metadb:geoip:metadb" "geosite.dat:geosite:dat"; do
  file="${f%%:*}"; base="${f#*:}"; ext="${base#*:}"; base="${base%:*}"
  if [ ! -f "$SCRIPT_DIR/Resources/geo/$file" ]; then
    echo "Downloading $file (best-effort)…"
    curl -fsSL --max-time 40 -o "$SCRIPT_DIR/Resources/geo/$file" \
      "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/$file" \
      && echo "  -> got $file" || echo "  -> 跳过 $file（网络不可达，应用将以域名规则分流）"
  fi
done

# 2) 编译 Swift（AppKit + SwiftUI 托管，菜单栏常驻）
SWIFTC="$(xcrun -f swiftc 2>/dev/null || command -v swiftc)"
SDK="$(xcrun --show-sdk-path)"
echo "Compiling with: $SWIFTC"
echo "SDK: $SDK"
"$SWIFTC" -target x86_64-apple-macosx13.0 -sdk "$SDK" -O \
  "$SCRIPT_DIR/Sources/"*.swift \
  -o "$MACOS/clashVPN" \
  -framework SwiftUI -framework AppKit -framework Combine -framework Foundation

# 3) 组装 .app
cp "$SCRIPT_DIR/Resources/mihomo" "$RES/mihomo"
chmod +x "$RES/mihomo"
cp "$SCRIPT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
mkdir -p "$RES/geo"
cp "$SCRIPT_DIR/Resources/geo/"* "$RES/geo/" 2>/dev/null || true

# 4) 签名 + 去除 quarantine
codesign --force --sign - "$RES/mihomo" 2>/dev/null || true
codesign --force --deep --sign - "$APP" 2>/dev/null || true
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo ""
echo "Built: $APP"
echo "Run:   open \"$APP\""
