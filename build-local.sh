#!/bin/zsh
# 本机架构构建；上游：https://github.com/beqaabu/MissionClose（MIT）。
#
#   ./build-local.sh            只构建，产物在 build/MissionClose.app
#   INSTALL=1 ./build-local.sh  构建并复制到 ~/Applications/MissionClose.app
#
# 只编译本机架构。SIGN_IDENTITY 可指定已配置的稳定签名身份（名称或 SHA-1）。
# SIGN_KEYCHAIN 可指定该身份所在钥匙串；本脚本不会创建证书或更改系统信任。
# 未提供 SIGN_IDENTITY 时使用 ad-hoc 签名。
# 注意：ad-hoc 签名的「辅助功能」授权绑定在这一份二进制上，重新编译后需要在
# 系统设置 → 隐私与安全性 → 辅助功能 里把 MissionClose 删掉再重新添加/开启一次。
# （只要不重新编译，授权会一直保持。）
set -euo pipefail

HERE="${0:A:h}"
SRC="${SRC:-$HERE}"
OUT="$HERE/build"
ARCH="$(uname -m)"
APP="$OUT/MissionClose.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

[[ -d "$SRC/Sources" ]] || { echo "找不到源码目录: $SRC"; exit 1; }

echo "==> 编译 ($ARCH)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/Info.plist" "$APP/Contents/"
cp "$SRC/Resources/AppIcon.icns" "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" \
  -o "$APP/Contents/MacOS/MissionClose" "$SRC"/Sources/*.swift -framework Cocoa

echo "==> 签名 ($SIGN_IDENTITY)"
sign_args=(--force --sign "$SIGN_IDENTITY")
if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
  sign_args+=(--keychain "$SIGN_KEYCHAIN")
fi
codesign "${sign_args[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
codesign -d -r- "$APP" 2>&1 | tee "$OUT/designated-requirement.txt"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "    此构建为 ad-hoc 签名；安装后可能需要删除旧辅助功能条目，再添加新 App。"
  echo "    --probe 从终端运行时的授权结果不代表后台 App；请用 App 菜单中的诊断确认。"
fi

if [[ "${INSTALL:-0}" == "1" ]]; then
  if pgrep -f '^/Users/[^/]+/Applications/MissionClose[.]app/Contents/MacOS/MissionClose([[:space:]]|$)' >/dev/null; then
    echo "请先从菜单栏退出 MissionClose，再安装，避免运行中的旧版本与新签名混用。" >&2
    exit 1
  fi
  echo "==> 安装到 ~/Applications"
  destination="$HOME/Applications/MissionClose.app"
  mkdir -p "$HOME/Applications"
  if [[ -d "$destination" ]]; then
    backup="$HERE/backups/MissionClose-$(date +%Y%m%d-%H%M%S).app"
    mkdir -p "$HERE/backups"
    ditto "$destination" "$backup"
    echo "    旧版已备份到 $backup"
  fi
  ditto "$APP" "$destination"
  codesign --verify --strict "$destination"
  echo "    已安装 ~/Applications/MissionClose.app"
fi
echo "==> 完成: $APP"
