# 배포 (Releasing)

크로스플랫폼 Tauri 앱(`tauri/`)의 빌드·릴리스·자동 업데이트 프로세스 문서.
(구 macOS Swift 앱은 `macos-swift/`, 별도 배포는 Homebrew cask.)

---

## TL;DR — 새 버전 내기

```sh
# 1) 버전 3곳을 같은 값으로 올린다
#    - tauri/src-tauri/tauri.conf.json  ("version")   ← 앱/업데이터/릴리스 기준
#    - tauri/src-tauri/Cargo.toml       ([package] version)
#    - tauri/package.json               ("version")
# 2) Cargo.lock 갱신
cd tauri/src-tauri && cargo check      # Cargo.lock 의 tauri 버전 동기화
# 3) 커밋 + main 푸시 — 끝 (태그는 CI 가 만든다)
git commit -am "Bump version to X.Y.Z"
git push origin main
# 로컬 태그 동기화가 필요하면: git fetch --tags
```

main 푸시 후 자동으로 (버전 태그 `v<version>` 이 아직 없을 때):
- macOS(universal) + Windows 러너에서 릴리스 빌드
- 태그 `v<version>` 생성 + GitHub 릴리스 **자동 발행**(초안 아님)
- 자산 첨부: `.dmg`(mac), `.msi`/`-setup.exe`(win), 각 `.sig` 서명, `latest.json`(업데이터용)
- **Homebrew tap 자동 갱신** — `brew` 잡이 `asdeszqsc/homebrew-tap` 의
  `Casks/dancing-pet.rb` 의 version/sha256 을 새 `.dmg` 기준으로 bump (secret `TAP_GITHUB_TOKEN`)

버전을 올리지 않은 main 푸시는 **빌드만** 한다 (컴파일 검증 + Rust 캐시 웜업 — 릴리스 빌드가 이 캐시를 재사용해 ~3분대).

> ⚠️ 업데이트가 감지되려면 **새 버전 > 설치된 버전**이어야 함. 버전은 `tauri.conf.json` 의 `version` 이 기준(태그 문자열이 아님).

---

## 파이프라인

- 정의: [`.github/workflows/build.yml`](.github/workflows/build.yml)
- 트리거: `main` push 단일 경로 — `version` 잡이 `tauri.conf.json` 의 버전 태그 존재 여부로
  릴리스 발행 여부를 결정. `workflow_dispatch` 는 수동 빌드(릴리스 없음).
- 캐시: 모든 런이 main ref 라 Rust 캐시가 항상 재사용된다 (콜드 ~10분 → 웜 ~3분).
  main 에 7일간 push 가 없으면 캐시 만료로 첫 빌드만 다시 콜드.
- 매트릭스:
  - `macos-latest` → `--target universal-apple-darwin` (Intel+ARM)
  - `windows-latest` → 기본 (x64)
- 빌드: [`tauri-action`](https://github.com/tauri-apps/tauri-action) 이 `projectPath: tauri` 에서
  `npm run build`(= `sync-assets && tsc && vite build`) → `cargo build --release` → 번들.
- 산출물 경로(CI): `tauri/src-tauri/target/**/release/bundle/**`

### 수동 실행
Actions 탭 → **build** → *Run workflow*. 수동 실행은 **항상 빌드만** 한다
(릴리스 발행은 main `push` 이벤트에서만).

---

## 자동 업데이트

- 앱 시작 시 `releases/latest/download/latest.json` 을 확인.
  (구현: `tauri/src/main.ts` 의 `checkForUpdate()`, OS 판별은 Rust `get_os` 커맨드)
- **Windows**: 새 버전이면 **확인창** → 다운로드·설치·재시작 (자동 설치).
- **macOS**: 자동 설치 없음 — 새 버전 감지 시 `brew upgrade --cask dancing-pet` 안내
  다이얼로그만 표시. cask 는 릴리스 시 CI 가 자동 bump (위 파이프라인 참고).
- ⚠️ **버전 라인은 1.x 로 통일** — Homebrew cask 가 Swift 앱 시절 `1.0.0` 이었어서,
  Tauri 앱도 `1.0.2` 부터 그 위로 이어간다 (0.1.x 로 내리면 brew 가 다운그레이드로 봄).
- 설정: `tauri/src-tauri/tauri.conf.json`
  - `bundle.createUpdaterArtifacts: true`
  - `plugins.updater.pubkey`, `plugins.updater.endpoints`
- 권한: `capabilities/default.json` 의 `updater:default`, `dialog:default`, `process:allow-restart`

### 업데이트 서명 키 (⚠️ 매우 중요)

업데이트 아티팩트는 minisign 키로 서명하고, 앱에는 **공개키가 내장**되어 있어 서명이 맞아야만 설치된다.

- **공개키**: `tauri.conf.json` 의 `plugins.updater.pubkey` (커밋됨, 비밀 아님)
- **개인키**: GitHub repo 시크릿 `TAURI_SIGNING_PRIVATE_KEY` (+ `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`, 현재 빈 값)
- CI 는 이 시크릿을 env 로 받아 `latest.json` 과 `.sig` 를 생성.

> **개인키 파일을 반드시 안전한 곳(비밀번호 관리자 등)에 백업할 것.**
> - GitHub 시크릿은 **다시 읽을 수 없음**.
> - 개인키를 잃으면 새 서명을 못 만들고, 공개키를 바꾸면 **구버전 앱들이 새 업데이트를 거부**한다(사실상 자동 업데이트 라인이 끊김).
> - 새 키 생성: `cd tauri && npm run tauri signer generate -- -w <경로> --password ""`
>   → `.pub` 내용을 `pubkey` 에 반영 + 개인키를 시크릿에 재등록.

---

## 최초 설정 메모 (이미 완료 — 참고용)

- 아이콘: `cd tauri && npm run tauri icon <1024px.png>` → `src-tauri/icons/` 생성.
- repo 시크릿 등록(개인 계정 gh):
  ```sh
  gh secret set TAURI_SIGNING_PRIVATE_KEY -R asdeszqsc/dancing-pet < <개인키파일>
  printf '' | gh secret set TAURI_SIGNING_PRIVATE_KEY_PASSWORD -R asdeszqsc/dancing-pet
  ```
- repo 시크릿 `TAP_GITHUB_TOKEN`: `asdeszqsc/homebrew-tap` 에 push 가능한 토큰
  (cask 자동 bump 용). 현재 asdeszqsc 의 gh OAuth 토큰을 등록 — **gh 재로그인 시
  토큰이 바뀌므로 재등록 필요**: `gh auth token -u asdeszqsc | gh secret set TAP_GITHUB_TOKEN -R asdeszqsc/dancing-pet`
- **워크플로 파일 푸시엔 토큰에 `workflow` 스코프 필요.** 이 repo 는 `asdeszqsc` HTTPS 토큰 사용:
  ```sh
  gh auth switch -u asdeszqsc
  gh auth refresh -h github.com -s workflow
  # 이후 이 repo 크리덴셜(.git/personal.credentials)에 workflow 스코프 토큰 반영
  ```

---

## 로컬에서

```sh
cd tauri
npm install
npm run tauri dev      # 개발 (핫리로드)
npm run tauri build    # 릴리스 로컬 빌드 (서명하려면 TAURI_SIGNING_* env 필요; 없으면 .sig 미생성)
```

macOS 개발 시 Dock 감지엔 **손쉬운 사용(Accessibility) 권한** 필요 — dev 빌드는 재컴파일마다 권한이 리셋될 수 있음(릴리스 빌드는 안정적).

---

## macOS 서명/공증

현재 **미서명·미공증**. Homebrew cask 가 quarantine 속성을 제거해 경고 없이 실행. 직접 `.dmg` 배포 시 Gatekeeper 경고가 날 수 있음.
