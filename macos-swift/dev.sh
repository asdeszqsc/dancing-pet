#!/bin/bash
# dev.sh — 핫리로드 개발 실행기
#   main.swift / gen_waabi.swift 를 저장하면 자동으로:
#     - gen_waabi.swift 변경 → 스프라이트 재생성 후 재실행 (컴파일 생략, 빠름)
#     - main.swift 변경     → 재컴파일 후 재실행
#   DP_DEV=1 로 실행되므로 손쉬운 사용 권한 없이 가짜 Dock(파란 띠)에서 climb 확인 가능.
#   종료: Ctrl-C
set -uo pipefail
cd "$(dirname "$0")"

BIN=".dev-dancing-pet"
APP_PID=""

mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }

cleanup() { [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null; echo; echo "dev 종료"; exit 0; }
trap cleanup INT TERM

relaunch() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null
  DP_DEV=1 ./"$BIN" &
  APP_PID=$!
  echo "✅ 실행 중 (pid $APP_PID) — 저장하면 자동 리로드 · 종료 Ctrl-C"
}

compile() {
  echo "▶︎ 컴파일…"
  if swiftc main.swift -o "$BIN.new" -framework Cocoa -framework CoreAudio; then
    mv -f "$BIN.new" "$BIN"; return 0
  fi
  echo "❌ 컴파일 실패 — 실행 중인 앱은 그대로 둠. 고치고 다시 저장하세요."
  rm -f "$BIN.new"; return 1
}

# gen_waabi.swift는 repo 루트에 있고 cwd/assets/waabi 로 출력 → 루트에서 실행
regen() { echo "▶︎ 스프라이트 재생성 (gen_waabi.swift)…"; ( cd .. && swift gen_waabi.swift >/dev/null ); }

# 최초 1회: 스프라이트 생성 + 컴파일 + 실행
regen
compile && relaunch
last_main=$(mtime main.swift)
last_gen=$(mtime gen_waabi.swift)

echo "👀 변경 감시 시작 (main.swift · gen_waabi.swift)"
while true; do
  sleep 1
  m=$(mtime main.swift); g=$(mtime gen_waabi.swift)
  if [[ "$g" != "$last_gen" ]]; then
    echo "🔄 gen_waabi.swift 변경"; last_gen="$g"
    regen; relaunch
  elif [[ "$m" != "$last_main" ]]; then
    echo "🔄 main.swift 변경"; last_main="$m"
    compile && relaunch
  fi
done
