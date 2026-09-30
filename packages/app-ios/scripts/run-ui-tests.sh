#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 跑 XCUITest：传模拟器 UDID 就在模拟器上跑（脚本自带 mock AI 端点，不碰真机和真实 API Key）；
# 传真机 UDID 就在真机上跑（iPhone 必须解锁并保持连接）：
#   bash packages/app-ios/scripts/run-ui-tests.sh [设备UDID]
#
# 不传 UDID 时用默认的「我的刀盾」。首次跑要用 -allowProvisioningUpdates
# 给 ShudengUITests 生成描述文件，前提是 Xcode 已登录开发者账号。
# 只跑某一条用例：ONLY_TESTING=ShudengUITests/ShudengUITests/test07ChatStreamsAnswerAndSavesThread
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEVICE_ID="${1:-00008120-00043D1C1A13C01E}"
MOCK_PID=""

cleanup() {
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# 模拟器：App 里的端点指向本机 mock（模拟器与 Mac 共享网络栈）。
DESTINATION="platform=iOS,id=$DEVICE_ID"
if xcrun simctl list devices -j | grep -q "\"$DEVICE_ID\""; then
  DESTINATION="platform=iOS Simulator,id=$DEVICE_ID"
  pkill -f "mock-llm-server.mjs 8799" 2>/dev/null || true
  sleep 1
  node "$REPO_ROOT/packages/app-ios/scripts/mock-llm-server.mjs" 8799 &
  MOCK_PID=$!
  sleep 1
  curl -sSf http://127.0.0.1:8799/ >/dev/null || {
    echo "mock AI 端点没起来（端口 8799 被占用？）" >&2
    exit 1
  }
fi

xcodebuild test \
  -project "$REPO_ROOT/packages/app-ios/Shudeng.xcodeproj" \
  -scheme Shudeng \
  -destination "$DESTINATION" \
  -derivedDataPath /private/tmp/shudeng-ui-test-dd \
  -allowProvisioningUpdates \
  -only-testing:"${ONLY_TESTING:-ShudengUITests}" \
  OTHER_SWIFT_FLAGS="-disable-sandbox"
