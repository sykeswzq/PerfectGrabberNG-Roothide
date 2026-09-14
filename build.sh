#!/bin/bash
# PerfectGrabberNG V2 —— roothide 构建（dylib + 面板 bundle；filter=Bundles 精准白名单，由设置面板运行时写入勾选的 App）
#   1) 纯 xcrun clang 直编（不用 Theos）
#   2) 包内路径用【根相对】 ./Library/... （roothide 解包后落到 jbroot/Library/...）
#   3) ldid -M -S 重签（ad-hoc），dylib 旁放 0 字节 .roothidepatch 注入标记
#   4) control 范式（借 Choicy 活样板）：Pre-Depends rootless-compat + Depends
#      mobilesubstrate / com.opa334.altlist / preferenceloader，带 postinst/postrm 重启 runningboardd。
#   V2.0.20 起：filter=静态 Bundles 占位符
# V2.0.32：极简稳定版重构
#   - Constructor 纯 C，零 ObjC —— 永不崩溃
#   - 移除所有 filter 写入逻辑（避免 helper/symlink 复杂操作）
#   - UI 构建采用多节点触发 + 重试机制
#   - Filter 简化为 ["*"] 通配符，依赖 Roohide 白名单控制注入
set -euo pipefail
cd "$(dirname "$0")"

PKG=com.sykes.perfectgrabberng
NAME="下拉时间电量 NG"
VER=2.0.32
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
# V2.0.20：filter 初始是 Bundles 占位符（零注入、不崩）。
# 关键：chmod 666 让 mobile（设置面板）可直接改写（postinst 还会再 chown mobile 双保险）。
# 这样无需 setuid helper：用户勾选 App → 设置面板(mobile) 直写 filter → roothide 按 Bundles 注入。
chmod 666 "$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.plist"
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
FILTER="$STAGE/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.plist"
# 校验 LC_ID_DYLIB 已是 roothide 规范（编译期用 -install_name 直接指定）
IDS="$(otool -D "$DL" | grep -v 'architecture' | grep -v '^$' | sort -u)"
echo "  install name: $IDS"
echo "$IDS" | grep -q "@loader_path/.jbroot" \
  || { echo "ERROR: LC_ID_DYLIB 不是 roothide 规范: $IDS"; exit 1; }

ldid -M -S "$DL"
ldid -M -S "$STAGE/Library/PreferenceBundles/PerfectGrabberNG.bundle/PerfectGrabberNG"
# 用 python 替代 xxd（GitHub Actions 可能没有 xxd；优先 python3，回退 python）
for f in "$DL" \
         "$STAGE/Library/PreferenceBundles/PerfectGrabberNG.bundle/PerfectGrabberNG"; do
  PY=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo "")
  [ -n "$PY" ] || { echo "ERROR: python/python3 未找到"; exit 1; }
  m="$($PY -c "import sys;d=open(sys.argv[1],'rb').read(4);print(d.hex())" "$f")"
  [ "$m" = "cafebabe" ] || { echo "ERROR: $f Mach-O 头异常 magic=$m"; exit 1; }
done
# ★ filter 必须是 Bundles 白名单（不是 Classes 全局注入）。
#   V2.0.32：使用占位符 "com.sykes.pgng.disabled"，由 Roohide 白名单控制注入范围。
/usr/libexec/PlistBuddy -c "Print :Filter:Bundles:0" "$FILTER" >/dev/null 2>&1 \
  || { echo "ERROR: filter 不是 Bundles 白名单"; exit 1; }
B0="$(/usr/libexec/PlistBuddy -c "Print :Filter:Bundles:0" "$FILTER" 2>/dev/null)"
echo "  filter Bundles[0]=$B0 （占位符，依赖 Roohide 白名单）"

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
Description: 游戏中从屏幕顶部下拉一次，顶部浮出当前时间与电量。默认不注入任何 App（filter 为占位符，零注入、不进安全模式）。在设置里勾选要显示时间电量的 App 后，勾选立即写入注入配置，彻底退出并重开该 App 生效。还需在 RootHide 白名单版(roothideinject)把该 App 加白。App 列表由 AltList 提供，需已安装 com.opa334.altlist。

EOF
# postinst：① 重启 runningboardd 使新 filter 生效（对齐 Choicy/锤子助手范式）；
#          ② 把 filter.plist 改成 mobile 可写（roothide 下 postinst 运行时根=jbroot，相对路径即真实位置），
#             让设置面板(mobile) 能直接写回勾选的 App，无需 setuid helper。
cp postinst pkg/DEBIAN/postinst
cp postrm pkg/DEBIAN/postrm
chmod 755 pkg/DEBIAN/postinst pkg/DEBIAN/postrm
echo "  postinst/postrm: 已添加（对齐 Choicy 范式）"

# 组装：面板 + dylib 都放进 pkg/（根相对 ./...），打 xz deb
cp -a "$STAGE/." pkg/
dpkg-deb -b -Zxz pkg "$OUT"
echo "  -> $(wc -c < "$OUT") bytes"
echo "BUILD_OK $OUT"
