#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 打包一个可以直接装到 iPhone 的已签名 IPA：
#   1) 无签名 Release 构建（bundle id 用描述文件里的那个）
#   2) 从本机开发描述文件里抽出 entitlements
#   3) codesign 签 App + 塞 embedded.mobileprovision
#   4) 打成 Payload/….app 结构的 IPA
#
# 用法：packages/app-ios/scripts/make-signed-ipa.sh [输出目录]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT_DIR="${1:-$REPO_ROOT/packages/app-ios/build}"
BUNDLE_ID="${SHUDENG_BUNDLE_ID:-com.wangxinxin.readany.personal}"
DERIVED="$(mktemp -d /private/tmp/shudeng-ipa-dd.XXXXXX)"

find_profile() {
  python3 - "$BUNDLE_ID" <<'PY'
import plistlib, re, sys, pathlib
bundle_id = sys.argv[1]
roots = [
    pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles",
    pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
]
best = None
for root in roots:
    if not root.is_dir():
        continue
    for file in sorted(root.glob("*.mobileprovision")):
        match = re.search(rb"<\?xml.*?</plist>", file.read_bytes(), re.S)
        if not match:
            continue
        profile = plistlib.loads(match.group(0))
        app_id = profile.get("Entitlements", {}).get("application-identifier", "")
        if app_id.split(".", 1)[-1] != bundle_id:
            continue
        if profile.get("ExpirationDate") and best and profile["ExpirationDate"] <= best[1]:
            continue
        best = (file, profile.get("ExpirationDate"))
if best:
    print(best[0])
else:
    sys.exit(f"找不到匹配 {bundle_id} 的开发描述文件；先在 Xcode 里用这台 iPhone 跑一次。")
PY
}

PROFILE="$(find_profile)"
IDENTITY="$(security find-identity -v -p codesigning | sed -n '1s/.*"\(.*\)"/\1/p')"
test -n "$IDENTITY" || { echo "钥匙串里没有 Apple Development 证书" >&2; exit 1; }

echo "描述文件: $PROFILE"
echo "签名证书: $IDENTITY"

# 构建失败必须在这里停住：以前 `| grep ... || true` 会把错误吞掉，
# 结果把上一次的（或残缺的）产物继续签名打成 IPA，装到手机上才发现没生效。
BUILD_LOG="$(mktemp /private/tmp/shudeng-build.XXXXXX)"
if ! xcodebuild -project "$REPO_ROOT/packages/app-ios/Shudeng.xcodeproj" -scheme Shudeng \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  OTHER_SWIFT_FLAGS="-disable-sandbox" build >"$BUILD_LOG" 2>&1; then
  grep -E "error:" "$BUILD_LOG" | sort -u | head -40 >&2 || true
  echo "构建失败，完整日志: $BUILD_LOG" >&2
  exit 1
fi
grep -E "error:" "$BUILD_LOG" | sort -u || true

APP="$DERIVED/Build/Products/Release-iphoneos/Shudeng.app"
test -d "$APP" || { echo "构建产物不存在: $APP" >&2; exit 1; }
test -x "$APP/Shudeng" || { echo "构建产物里没有可执行文件（构建没真正成功）: $APP" >&2; exit 1; }

ENTITLEMENTS="$(mktemp /private/tmp/shudeng-entitlements.XXXXXX)"
python3 - "$PROFILE" "$ENTITLEMENTS" <<'PY'
import plistlib, re, sys, pathlib
raw = pathlib.Path(sys.argv[1]).read_bytes()
profile = plistlib.loads(re.search(rb"<\?xml.*?</plist>", raw, re.S).group(0))
entitlements = dict(profile["Entitlements"])
entitlements.setdefault("get-task-allow", True)
pathlib.Path(sys.argv[2]).write_bytes(plistlib.dumps(entitlements))
PY

cp "$PROFILE" "$APP/embedded.mobileprovision"
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" \
  --generate-entitlement-der "$APP"
codesign --verify --strict "$APP"

mkdir -p "$OUT_DIR"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Info.plist")"
IPA="$OUT_DIR/shudeng-$VERSION.ipa"
STAGE="$(mktemp -d /private/tmp/shudeng-ipa-stage.XXXXXX)"
mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/Shudeng.app"
(cd "$STAGE" && ditto -c -k --sequesterRsrc --keepParent Payload "$IPA")

echo "IPA: $IPA ($(du -h "$IPA" | cut -f1))"
echo "App: $APP"
