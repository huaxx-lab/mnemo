#!/usr/bin/env bash
# 把 build/Mnemo.app 打成可以直接发给别人的 .dmg。
#
# 仍然是 ad-hoc 签名（没有 Developer ID，也没有公证），所以别人第一次打开会被
# Gatekeeper 拦下：得去「系统设置 → 隐私与安全性」点「仍要打开」，或者自己去掉
# 隔离属性。（macOS 15 之后 Apple 移除了「右键 → 打开」那条绕过路径，旧说法已
# 经不管用。）DMG 里附一份说明，省得每次口头交代。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Mnemo.app"
if [[ ! -d "$APP" ]]; then
  echo "找不到 $APP，先跑 ./scripts/build-app.sh" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_ID="$(/usr/libexec/PlistBuddy -c 'Print :MnemoBuildID' "$APP/Contents/Info.plist")"
STAGE="$(mktemp -d /tmp/mnemo-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

echo "▸ 准备磁盘映像内容"
ditto --noextattr --noqtn "$APP" "$STAGE/Mnemo.app"
# FinderInfo / fileprovider 这类扩展属性会让 codesign 直接拒签。
xattr -cr "$STAGE/Mnemo.app" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$STAGE/Mnemo.app" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$STAGE/Mnemo.app/Contents/Resources/Mnemo_MnemoApp.bundle" 2>/dev/null || true

echo "▸ ad-hoc 重新签名并校验"
codesign --force --deep --sign - "$STAGE/Mnemo.app"
codesign --verify --deep --strict "$STAGE/Mnemo.app"

ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<TXT
Mnemo ${VERSION}（构建 ${BUILD_ID}）

1. 安装
   把左边的 Mnemo 拖到右边的「Applications」。

2. 第一次打开
   这个包是自签名的、没有经过 Apple 公证，所以第一次会被系统拦下。
   注意：旧教程里的「右键 → 打开」在 macOS 15 之后已经失效，Apple 移除了
   那条绕过路径，点了也没用。现在的步骤是：

   a. 先双击一次，让它被拒。这一步不能省——系统要先记下一次拦截，
      下一步那个按钮才会出现。
   b. 打开「系统设置 → 隐私与安全性」，一直拉到最底下。
   c. 会看到一行「已阻止使用“Mnemo”…」，点右边的「仍要打开」。

   之后就能正常双击了。也可以在「终端」里执行一次，直接去掉隔离标记：
   xattr -dr com.apple.quarantine /Applications/Mnemo.app

3. 首次启动会出现配置引导
   - 辅助功能权限：必需。⌘G 要靠它读取你在别的应用里选中的文字。
   - 完全磁盘访问：可选。只有从微信这类应用的聊天里直接拖文件才需要。
   - 模型：填一次 API Key、选一个对话模型；再填一个 Embedding 模型，
     检索才能听懂自然语言的说法。凭据保存在 ~/.mnemo/credentials.json，
     文件权限为 0600。

4. 怎么用
   - 拖文件 / 图片 / 链接到刘海：直接收进来。
   - 选中一段文字按 ⌘G：要东西就把真文件或原文交到剪贴板；
     问内容讲了什么，就基于你自己的资料给出完整中文回答，并一并复制。
   - ⌃⌘P 收纳当前剪贴板，⌃⌘Space 打开或收起面板。

5. 系统要求
   macOS 26 或更新版本。有刘海的 Mac 体验最好；没有刘海会退化成顶部条。
TXT

DMG="build/Mnemo-$VERSION.dmg"
rm -f "$DMG"
echo "▸ 生成 $DMG"
hdiutil create -volname "Mnemo $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "✅ $DMG"
du -h "$DMG" | sed 's/^/   /'
