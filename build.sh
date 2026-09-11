#!/bin/bash
# PerfectGrabberNG V2 —— roothide 构建（dylib + 面板 bundle；filter=Classes=[UIApplication]，由 RootHide 白名单版决定注入哪些 App）
#   1) 纯 xcrun clang 直编（不用 Theos）
#   2) 包内路径用【根相对】 ./Library/... （roothide 解包后落到 jbroot/Library/...）
#   3) ldid -M -S 重签（ad-hoc），dylib 旁放 0 字节 .roothidepatch 注入标记
#   4) control 范式（借 Choicy 活样板）：Pre-Depends rootless-compat + Depends
#      mobilesubstrate / com.opa334.altlist / preferenceloader，带 postinst/postrm 重启 runningboardd。
#   V2.0.19 起：不再编译 setuid helper、不再运行时写 filter。
#   注入范围完全由 RootHide 白名单版(roothideinject)决定（filter=Classes=[UIApplication] 注入所有 GUI App）。
set -euo pipefail
cd "$(dirname "$0")"

PKG=com.sykes.perfectgrabberng
NAME="下拉时间电量 NG"
VER=2.0.19
ARCH="iphoneos-arm64e"
OUT="com.sykes.perfectgrabberng_${VER}_${ARCH}.deb"
# roothide 规范的 install name（对齐 Choicy 活样板）。
# 必须在【编译期】用 -install_name 指定：clang 默认会把 -o 的输出路径当成 LC_ID_DYLIB
# （之前就是 build/Library/... 这种相对路径），而 roothide 安装期的路径改写器
# 只认 / 开头的绝对路径或 @loader_path 形式，相对路径会被漏掉 → 留下坏 install name。
# 这里不用 install_name_tool 事后改：新名字比旧的长，install_name_tool 可能因空间不足失败。
NEWID="@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib"
rm -f "$OUT"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "iPhoneOS SDK: $SDK"
command -v ldid >/dev/null 2>&1 || { echo "ERROR: ldid 未安装"; exit 1; }

STAGE=build
rm -rf "$STAGE" pkg
mkdir -p "$STAGE/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$STAGE/Library/PreferenceBundles/PerfectGrabberNG.bundle"
mkdir -p "$STAGE/Library/PreferenceLoader/Preferences"

echo "[1/4] 编译 tweak dylib（arm64 + arm64e，iPhoneOS SDK，ad-hoc 签名）"
# ★ 第二层保险（对齐 Choicy 活样板）：不【强链接】UIKit/Foundation/CoreGraphics，
#   改用 -undefined dynamic_lookup 让 ObjC/UIKit 符号在运行时从宿主进程解析。
#   好处：dylib 被加载时不会二次拉起 UIKit 等重量级框架，注入任何进程的加载期开销最小。
xcrun --sdk iphoneos clang \
  -dynamiclib -fobjc-arc \
  -undefined dynamic_lookup \
  -install_name "$NEWID" \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o "$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib" \
  PGTweak.m
chmod 755 "$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib"
cp PerfectGrabberNG.plist "$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.plist"
# filter 已改为静态 Classes=[UIApplication]，安装后是 root 拥有的只读文件，无需运行时改写 → 644
chmod 644 "$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.plist"
# roothide 注入标记：dylib 旁放 0 字节 .roothidepatch（与锤子/Choicy/ExactTime 完全一致）
touch "$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib.roothidepatch"

echo "[2/4] 编译设置面板 bundle（PS 私有类运行时解析，-undefined dynamic_lookup）"
xcrun --sdk iphoneos clang \
  -bundle -fobjc-arc -undefined dynamic_lookup \
  -framework Foundation -framework UIKit -framework CoreGraphics \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o "$STAGE/Library/PreferenceBundles/PerfectGrabberNG.bundle/PerfectGrabberNG" \
  PGRootListController.m PGAppListController.m
chmod 755 "$STAGE/Library/PreferenceBundles/PerfectGrabberNG.bundle/PerfectGrabberNG"
cp BundleInfo.plist "$STAGE/Library/PreferenceBundles/PerfectGrabberNG.bundle/Info.plist"
chmod 644 "$STAGE/Library/PreferenceBundles/PerfectGrabberNG.bundle/Info.plist"
cp Root.plist "$STAGE/Library/PreferenceBundles/PerfectGrabberNG.bundle/Root.plist"
chmod 644 "$STAGE/Library/PreferenceBundles/PerfectGrabberNG.bundle/Root.plist"
cp PrefLoader.plist "$STAGE/Library/PreferenceLoader/Preferences/PerfectGrabberNG.plist"
chmod 644 "$STAGE/Library/PreferenceLoader/Preferences/PerfectGrabberNG.plist"

echo "[3/4] 校验 install name + ldid 重签 + 校验 Mach-O 头 + 校验 filter"
DL="$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib"
# 校验 LC_ID_DYLIB 已是 roothide 规范（编译期用 -install_name 直接指定）
IDS="$(otool -D "$DL" | grep -v 'architecture' | grep -v '^$' | sort -u)"
echo "  install name: $IDS"
echo "$IDS" | grep -q "@loader_path/.jbroot" \
  || { echo "ERROR: LC_ID_DYLIB 不是 roothide 规范: $IDS"; exit 1; }

ldid -M -S "$DL"
ldid -M -S "$STAGE/Library/PreferenceBundles/PerfectGrabberNG.bundle/PerfectGrabberNG"
for f in "$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib" \
         "$STAGE/Library/PreferenceBundles/PerfectGrabberNG.bundle/PerfectGrabberNG"; do
  m="$(xxd -p -l4 "$f" | tr -d '\n')"
  [ "$m" = "cafebabe" ] || { echo "ERROR: $f Mach-O 头异常 magic=$m"; exit 1; }
done
# ★ filter 必须是 Classes=[UIApplication]：注入所有 GUI App，
#   真正"是否注入"由 RootHide 白名单版(roothideinject)的 App 白名单决定（闸①）。
#   不再依赖运行时改 filter / setuid helper（iOS 上必失败 → 占位符永久生效 → 零注入）。
/usr/libexec/PlistBuddy -c "Print :Filter:Classes:0" \
  "$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.plist" | grep -q "UIApplication" \
  || { echo "ERROR: filter 不是 Classes=[UIApplication]（无法注入所有 GUI App）"; exit 1; }

echo "[4/4] 生成 control + postinst/postrm（对齐 Choicy 范式：rootless-compat + altlist + preferenceloader）"
mkdir -p pkg/DEBIAN
cat > pkg/DEBIAN/control <<EOF
Package: $PKG
Name: $NAME
Version: $VER
Architecture: $ARCH
Depends: mobilesubstrate, com.opa334.altlist (>= 1.0.4), preferenceloader, firmware (>= 13.0)
Pre-Depends: rootless-compat (>= 0.9)
Maintainer: sykeswzq
Author: sykeswzq
Section: Tweaks
Priority: optional
Description: 游戏中从屏幕顶部下拉一次，顶部浮出当前时间与电量。插件会注入到 RootHide 白名单版已加白的所有应用；设置里"注入 App 列表"可进一步限定只显示某些 App（留空=白名单内全部显示）。改完需彻底退出并重新打开该 App 生效。

EOF
# postinst：安装后重启 runningboardd 使新 filter 生效（对齐 Choicy/锤子助手范式）
cp postinst pkg/DEBIAN/postinst
cp postrm pkg/DEBIAN/postrm
chmod 755 pkg/DEBIAN/postinst pkg/DEBIAN/postrm
echo "  postinst/postrm: 已添加（对齐 Choicy 范式）"

# 组装：面板 + dylib 都放进 pkg/（根相对 ./...），打 xz deb
cp -a "$STAGE/." pkg/
dpkg-deb -b -Zxz pkg "$OUT"
echo "  -> $(wc -c < "$OUT") bytes"
echo "BUILD_OK $OUT"
