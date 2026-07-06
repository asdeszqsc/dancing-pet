#!/usr/bin/env bash
# macOS ad-hoc 서명 + 고정 designated requirement.
# tauri.macos.conf.json 의 beforeBundleCommand 로 빌드 후·번들 전에 실행된다.
#
# 왜: Apple Developer ID 없이 빌드하면 링커의 임시 ad-hoc 서명만 남는데, 그 서명의
# identifier 는 빌드마다 바뀌는 랜덤 값(tauri-<hex>)이고, TCC(손쉬운 사용 권한 DB)는
# 권한 부여 시점의 designated requirement(ad-hoc 기본값: cdhash = 그 바이너리의 해시)를
# 저장한다 → brew upgrade 로 바이너리가 바뀔 때마다 권한이 조용히 무효화되어
# AXIsProcessTrusted() 가 false 가 되고 Dock 감지가 죽는다.
#
# 해결: identifier 를 번들 ID 로 고정하고, cdhash 가 없는 "identifier 만" 조건을
# designated requirement 로 심는다. 같은 방식으로 서명된 이후의 모든 빌드가
# 기존 TCC 권한 항목과 계속 매칭된다.
# 트레이드오프: ad-hoc 이라 같은 identifier 를 주장하는 다른 무서명 앱도 이 조건을
# 만족할 수 있다. Developer ID 서명 도입 시 이 스크립트를 제거하고
# bundle.macOS.signingIdentity 로 대체할 것 (RELEASING.md 참고).
set -euo pipefail

BUNDLE_ID="com.dancingpet.app"
DESIGNATED_REQ="designated => identifier \"${BUNDLE_ID}\""
TARGET_DIR="$(cd "$(dirname "$0")/../src-tauri/target" && pwd)"

# 빌드 산출물 후보: CI 는 universal, 로컬 기본 빌드는 target/release.
signed=0
for bin in \
  "$TARGET_DIR/universal-apple-darwin/release/tauri" \
  "$TARGET_DIR/aarch64-apple-darwin/release/tauri" \
  "$TARGET_DIR/x86_64-apple-darwin/release/tauri" \
  "$TARGET_DIR/release/tauri"; do
  [ -f "$bin" ] || continue
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    --requirements "=${DESIGNATED_REQ}" "$bin"
  codesign --verify --test-requirement="=identifier \"${BUNDLE_ID}\"" "$bin"
  echo "[macos-adhoc-sign] signed: $bin"
  signed=1
done

if [ "$signed" -eq 0 ]; then
  echo "[macos-adhoc-sign] ERROR: no built binary found under $TARGET_DIR" >&2
  exit 1
fi
