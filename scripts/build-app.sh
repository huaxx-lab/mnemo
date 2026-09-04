#!/usr/bin/env bash
# 把 SwiftPM 可执行文件组装成 Mnemo.app。
#
# 自用场景不做签名公证，只做 ad-hoc 签名——足够本机运行，
# 也避免每次构建都要开发者账号。
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPER_DIR:=/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR

# 改名时不动的东西：CFBundleIdentifier、UTI（com.pinland.*）、
# ~/Library/Application Support/Pinland、UserDefaults 的 Pinland.* 键、
# .pinlandarchive 扩展名、钥匙串里凭据的名字。
#
# 它们不是文案，是**身份**：系统靠 bundle id 认这个应用的权限（辅助功能、
# 完全磁盘访问、通知），钥匙串靠名字认凭据的归属，库和设置靠路径与键名找回
# 自己。换掉任何一个，用户失去的是已经授过的权限、已经填过的 API Key、
# 已经攒下的整个库——而换来的只是几个用户永远看不到的字符串更好看。
# Apple 自己的建议也是产品改名不要动 bundle id。

CONFIG="${1:-release}"
# 版本号默认就是当前发布版；MNEMO_VERSION 可以覆盖，用来打一个"旧版"包
# 在本机验证远程更新流程，不必为此改一次源码再改回去。
VERSION="${MNEMO_VERSION:-3.1}"
SCRATCH="${MNEMO_SCRATCH:-/tmp/mnemo-build}"
# 在**同步目录之外**组装并签名，最后才拷回 build/。
#
# 仓库在 ~/Desktop 下，而桌面归 iCloud 文件提供器管：它会不断给目录写回
# com.apple.FinderInfo 等扩展属性。codesign 拒绝带这些"detritus"的 bundle，
# 于是签名会在 xattr 清理和签名之间的窗口里随机失败——本地看着像"有时能
# 打包有时不能"。把组装挪到 scratch（默认 /tmp）就没有这个写回者。
STAGE="$SCRATCH/stage/Mnemo.app"
APP="$STAGE"
FINAL_APP="build/Mnemo.app"
# 显式环境变量优先；否则沿用用户在设置页保存的图标。`defaults` 读到 rawValue，
# 读取失败才退回默认深空。
SAVED_ICON="$(defaults read com.pinland.app Pinland.selectedAppIcon 2>/dev/null || true)"
ICON_VARIANT="${MNEMO_ICON:-${SAVED_ICON:-b-staggered}}"
case "$ICON_VARIANT" in
  a-classic|b-staggered|c-dark) ;;
  *) ICON_VARIANT="b-staggered" ;;
esac
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_ID="$(git rev-parse --short HEAD 2>/dev/null || echo local)"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then BUILD_ID="${BUILD_ID}-dirty"; fi

echo "▸ 编译（${CONFIG}）"
swift build -c "$CONFIG" --scratch-path "$SCRATCH"
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)/Mnemo"

echo "▸ 组装 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mnemo"
# SwiftPM 的 Release 可执行文件仍保留本地符号表；它让主程序从约 3.7 MB 涨到
# 约 9 MB，却不参与运行。只裁本地符号，不动图标、资源或动态符号；签名在后面做。
if [[ "$CONFIG" == "release" ]]; then
  strip -x "$APP/Contents/MacOS/Mnemo"
fi

RESOURCE_BUNDLE="$(dirname "$BIN")/Mnemo_MnemoApp.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
else
  echo "  ⚠️ 未找到 SwiftPM 资源包，供应商图标将不可用"
fi

# 自定义图标（bundle 根目录的 Icon\r + FinderInfo 标志）优先级高于 AppIcon.icns。
# 旧版本写过它，残留会让 Finder 永远显示被钉死的那一张；组装时清掉。
rm -f "$APP/Icon"$'\r' 2>/dev/null || true
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true

if [[ -f "icon/build/mnemo-$ICON_VARIANT.icns" ]]; then
  cp "icon/build/mnemo-$ICON_VARIANT.icns" "$APP/Contents/Resources/AppIcon.icns"
  for variant in a-classic b-staggered c-dark; do
    if [[ -f "icon/build/mnemo-$variant.icns" ]]; then
      cp "icon/build/mnemo-$variant.icns" "$APP/Contents/Resources/mnemo-$variant.icns"
    fi
  done
else
  echo "  ⚠️ 未找到图标，先跑 icon/src/gen_icon.py 与 iconutil"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mnemo</string>
  <key>CFBundleDisplayName</key><string>Mnemo</string>
  <key>CFBundleIdentifier</key><string>com.pinland.app</string>
  <key>CFBundleExecutable</key><string>Mnemo</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>MnemoBuildID</key><string>$BUILD_ID</string>
  <key>MnemoBuildDate</key><string>$BUILD_DATE</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <!-- 只在刘海与菜单栏出现，不进 Dock、不抢焦点 -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.pinland.library-archive</string>
      <key>UTTypeDescription</key><string>Mnemo Library Archive</string>
      <key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>pinlandarchive</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Mnemo Library Archive</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key><array><string>com.pinland.library-archive</string></array>
      <key>LSTypeIsPackage</key><true/>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "▸ ad-hoc 签名"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"

echo "▸ 拷回 build/"
mkdir -p "$(dirname "$FINAL_APP")"
rm -rf "$FINAL_APP"
# --noextattr --norsrc：不要把同步目录不欢迎的扩展属性一并带过去。
# 代码签名存在 Mach-O 与 _CodeSignature 里，不依赖 xattr，因此不受影响。
ditto --noextattr --norsrc "$APP" "$FINAL_APP"

echo "✅ $FINAL_APP"
du -sh "$FINAL_APP" | sed 's/^/   /'
echo "   已签名副本：$APP"
