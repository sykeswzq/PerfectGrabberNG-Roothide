#!/bin/bash
# PerfectGrabberNG V2 —— roothide 构建（dylib + 面板 bundle + setuid helper，对齐 Choicy 范式）
#   1) 纯 xcrun clang 直编（不用 Theos）
#   2) 包内路径用【根相对】 ./Library/... （roothide 解包后落到 jbroot/Library/...）
#   3) ldid -M -S 重签（ad-hoc），dylib 旁放 0 字节 .roothidepatch 注入标记
#   4) control 范式（借 Choicy 活样板）：Pre-Depends rootless-compat + Depends
#      mobilesubstrate / com.opa334.altlist / preferenceloader，带 postinst/postrm 重启 runningboardd。
set -euo pipefail
cd "$(dirname "$0")"

PKG=com.sykes.perfectgrabberng
NAME="下拉时间电量 NG"
VER=2.0.12
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
mkdir -p "$STAGE/usr/bin"

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
# 放宽到 666：万一 setuid helper 在某些环境不可用，mobile 直接改写也还有一线机会
# （内容由插件自己生成，且写前会按白名单重算，被第三方篡改的最坏后果也只是改注入范围）
chmod 666 "$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.plist"
# roothide 注入标记：dylib 旁放 0 字节 .roothidepatch（与锤子/Choicy/ExactTime 完全一致）
touch "$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib.roothidepatch"

echo "[1.5/4] 编译 setuid root 帮助程序 pgngfilter"
# 为什么必须有它：filter plist 位于 <jbroot>/Library/MobileSubstrate/DynamicLibraries/，
# 属 root:wheel、权限 0644；设置面板跑在 Preferences 里，身份是 mobile，既改不了文件也进不去目录。
# 所以「在设置里勾选 App → 立刻改写 filter」这一步必须由 root 完成。
# helper 由 dpkg 以 root 安装并带上 setuid 位，面板 posix_spawn 它即以 root 落盘。
xcrun --sdk iphoneos clang \
  -O2 -Wall \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o "$STAGE/usr/bin/pgngfilter" pgngfilter.c
ldid -M -S "$STAGE/usr/bin/pgngfilter"
chmod 4755 "$STAGE/usr/bin/pgngfilter"    # setuid root：面板靠它获得写 filter 的权限
echo "  helper: $(ls -l "$STAGE/usr/bin/pgngfilter" | awk '{print $1,$NF}')"

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

echo "[3/4] 校验 install name + ldid 重签 + 校验 Mach-O 头 + 校验 filter + 校验 helper"
DL="$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib"
# 校验 LC_ID_DYLIB 已是 roothide 规范（编译期用 -install_name 直接指定）
IDS="$(otool -D "$DL" | grep -v 'architecture' | grep -v '^$' | sort -u)"
echo "  install name: $IDS"
echo "$IDS" | grep -q "@loader_path/.jbroot" \
  || { echo "ERROR: LC_ID_DYLIB 不是 roothide 规范: $IDS"; exit 1; }

ldid -M -S "$DL"
ldid -M -S "$STAGE/Library/PreferenceBundles/PerfectGrabberNG.bundle/PerfectGrabberNG"
for f in "$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib" \
         "$STAGE/Library/PreferenceBundles/PerfectGrabberNG.bundle/PerfectGrabberNG" \
         "$STAGE/usr/bin/pgngfilter"; do
  m="$(xxd -p -l4 "$f" | tr -d '\n')"
  [ "$m" = "cafebabe" ] || { echo "ERROR: $f Mach-O 头异常 magic=$m"; exit 1; }
done
# ★ 第一层保险：filter 必须是 Bundles 白名单（精准注入），不能是 Classes 全局注入
/usr/libexec/PlistBuddy -c "Print :Filter:Bundles:0" \
  "$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.plist" | grep -q "com.sykes.pgng.disabled" \
  || { echo "ERROR: filter 不是 Bundles 白名单（会退化为全局注入）"; exit 1; }
# helper 必须带 setuid 位（4755）
[ -x "$STAGE/usr/bin/pgngfilter" ] || { echo "ERROR: helper 不可执行"; exit 1; }

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
Description: 游戏中从屏幕顶部下拉一次，顶部浮出当前时间与电量。默认不注入任何 App（全关），在设置里勾选 App 后重启该 App 生效（选哪个注哪个）。

EOF
# postinst：安装后重启 runningboardd 使新 filter 生效（对齐 Choicy/锤子助手范式）
cp postinst pkg/DEBIAN/postinst
cp postrm pkg/DEBIAN/postrm
chmod 755 pkg/DEBIAN/postinst pkg/DEBIAN/postrm
echo "  postinst/postrm: 已添加（对齐 Choicy 范式）"

# 组装：面板 + dylib + helper 都放进 pkg/（根相对 ./...），打 xz deb
cp -a "$STAGE/." pkg/
dpkg-deb -b -Zxz pkg "$OUT"
echo "  -> $(wc -c < "$OUT") bytes"
echo "BUILD_OK $OUT"
