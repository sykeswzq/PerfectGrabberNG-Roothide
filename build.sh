#!/bin/bash
# 下拉时间电量 NG —— roothide 专用构建脚本
# 范式来自 HealthBoost（已在你设备上验证过的 roothide 构建方式）：
#   1) 纯 xcrun clang 直编（不用 Theos）
#   2) 包内路径用【根相对】 ./Library/...  （roothide 解包后落到 /var/roothide/Library/...）
#      绝不能用 ./var/jb/ 或 ./var/roothide/ 前缀
#   3) ldid -M -S 重签（ad-hoc），禁止手搓签名
set -euo pipefail

VER="1.0.${GITHUB_RUN_NUMBER:-1}"
PKG="com.sykes.perfectgrabberng"
OUT="${PKG}_${VER}_iphoneos-arm64e.deb"
echo "版本号: $VER"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)

rm -rf staging
mkdir -p staging/DEBIAN
mkdir -p staging/Library/MobileSubstrate/DynamicLibraries
mkdir -p staging/Library/PreferenceBundles/PerfectGrabberNG.bundle
mkdir -p staging/Library/PreferenceLoader/Preferences

echo "[1/5] 编译 tweak dylib（arm64 + arm64e）"
xcrun --sdk iphoneos clang \
  -dynamiclib -fobjc-arc \
  -framework Foundation -framework UIKit -framework CoreGraphics \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o staging/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib \
  PGTweak.m
chmod 755 staging/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib
cp PerfectGrabberNG.plist staging/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.plist
chmod 644 staging/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.plist
echo "  dylib: $(wc -c < staging/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib) bytes"

echo "[2/5] 编译设置面板 bundle（PS 私有类运行时解析）"
xcrun --sdk iphoneos clang \
  -bundle -fobjc-arc -undefined dynamic_lookup \
  -framework Foundation -framework UIKit -framework CoreGraphics \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o staging/Library/PreferenceBundles/PerfectGrabberNG.bundle/PerfectGrabberNG \
  PGRootListController.m PGAppListController.m
chmod 755 staging/Library/PreferenceBundles/PerfectGrabberNG.bundle/PerfectGrabberNG
cp BundleInfo.plist staging/Library/PreferenceBundles/PerfectGrabberNG.bundle/Info.plist
chmod 644 staging/Library/PreferenceBundles/PerfectGrabberNG.bundle/Info.plist
# 声明式界面（对齐 Choicy：由 Preferences 框架原生解析 Root.plist，不在代码里构造 specifier）
cp Root.plist staging/Library/PreferenceBundles/PerfectGrabberNG.bundle/Root.plist
chmod 644 staging/Library/PreferenceBundles/PerfectGrabberNG.bundle/Root.plist
cp PrefLoader.plist staging/Library/PreferenceLoader/Preferences/PerfectGrabberNG.plist
chmod 644 staging/Library/PreferenceLoader/Preferences/PerfectGrabberNG.plist
echo "  bundle: $(wc -c < staging/Library/PreferenceBundles/PerfectGrabberNG.bundle/PerfectGrabberNG) bytes"

echo "[3/5] ldid 重签名"
command -v ldid >/dev/null 2>&1 || { echo "ERROR: ldid 未安装"; exit 1; }
ldid -M -S staging/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib
ldid -M -S staging/Library/PreferenceBundles/PerfectGrabberNG.bundle/PerfectGrabberNG
# Mach-O 头必须是 fat (cafebabe)
for f in staging/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib \
         staging/Library/PreferenceBundles/PerfectGrabberNG.bundle/PerfectGrabberNG; do
  magic=$(xxd -p -l4 "$f" | tr -d '\n')
  if [ "$magic" != "cafebabe" ]; then echo "ERROR: $f Mach-O 头异常 magic=$magic"; exit 1; fi
done
echo "  签名 + Mach-O 头校验通过"

echo "[4/5] 生成 control / postinst"
cat > staging/DEBIAN/control << EOF
Package: ${PKG}
Name: 下拉时间电量 NG
Version: ${VER}
Architecture: iphoneos-arm64e
Depends: firmware (>= 13.0), mobilesubstrate, preferenceloader
Maintainer: sykeswzq
Author: sykeswzq
Section: Tweaks
Priority: optional
Description: 游戏中下拉一次，顶部浮出时间与电量。默认开启，可在设置里选择要注入的 App。
EOF

cat > staging/DEBIAN/postinst << 'EOF'
#!/bin/sh
# roothide 保险：把 tweak dylib 注册进 trustcache（正常情况下 dpkg 已处理）
JBCTL=""
for c in /usr/bin/jbctl "$(command -v jbctl 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && JBCTL="$c" && break
done
JR=""
if [ -x /usr/bin/jbroot ]; then
    JR="$(/usr/bin/jbroot 2>/dev/null || true)"
    JR="${JR%/}"
fi
if [ -n "$JBCTL" ] && [ -n "$JR" ] && [ "$JR" != "/" ] && [ -d "$JR" ]; then
    for f in "$JR/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib" \
             "$JR/usr/lib/TweakInject/PerfectGrabberNG.dylib" \
             "$JR/Library/PreferenceBundles/PerfectGrabberNG.bundle/PerfectGrabberNG"; do
        if [ -f "$f" ]; then
            "$JBCTL" trustcache add "$f" >/dev/null 2>&1 || true
        fi
    done
fi
exit 0
EOF
chmod 755 staging/DEBIAN/postinst

echo "[5/5] 打包"
# xz 压缩（与 Choicy 等 roothide 官方源包一致）
dpkg-deb -b -Zxz staging "$OUT"
echo "  -> $(wc -c < "$OUT") bytes"
echo "DONE: $OUT"
