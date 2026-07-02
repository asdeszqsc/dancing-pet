# 배포 (Releasing)

크로스플랫폼 Tauri 앱(`tauri/`)의 빌드·릴리스·자동 업데이트 프로세스 문서.
(구 macOS Swift 앱은 `macos-swift/`, 별도 배포는 Homebrew cask.)

---

## TL;DR — 새 버전 내기

```sh
# 1) 버전 3곳을 같은 값으로 올린다
#    - tauri/src-tauri/tauri.conf.json  ("version")   ← 앱/업데이터 기준
#    - tauri/src-tauri/Cargo.toml       ([package] version)
#    - tauri/package.json               ("version")
# 2) Cargo.lock 갱신
cd tauri/src-tauri && cargo check      # Cargo.lock 의 tauri 버전 동기화
# 3) 커밋
git commit -am "Bump version to X.Y.Z"
# 4) 태그 푸시 → GitHub Actions 가 자동 빌드 + 릴리스 발행
git tag vX.Y.Z
git push origin <branch> --tags
```

푸시 후 자동으로:
- macOS(universal) + Windows 러너에서 릴리스 빌드
- GitHub 릴리스 **자동 발행**(초안 아님) — 태그 이름으로
- 자산 첨부: `.dmg`(mac), `.msi`/`-setup.exe`(win), 각 `.sig` 서명, `latest.json`(업데이터용)

> ⚠️ 업데이트가 감지되려면 **새 버전 > 설치된 버전**이어야 함. 버전은 `tauri.conf.json` 의 `version` 이 기준(태그 문자열이 아님).

---

## 파이프라인

- 정의: [`.github/workflows/build.yml`](.github/workflows/build.yml)
- 트리거: `v*` 태그 push (릴리스 발행) / `main` push (빌드만 — 컴파일 검증 + Rust 캐시 웜업) / `workflow_dispatch`(수동, 빌드만)
- 캐시: GitHub Actions 캐시는 "자기 ref + 기본 브랜치" 것만 복원 가능 → 태그 릴리스 빌드는 **main 의 캐시**를 재사용한다. main 에 한동안 push 가 없어 캐시가 만료(7일)되면 첫 빌드는 다시 콜드(~10분).
- 매트릭스:
  - `macos-latest` → `--target universal-apple-darwin` (Intel+ARM)
  - `windows-latest` → 기본 (x64)
- 빌드: [`tauri-action`](https://github.com/tauri-apps/tauri-action) 이 `projectPath: tauri` 에서
  `npm run build`(= `sync-assets && tsc && vite build`) → `cargo build --release` → 번들.
- 산출물 경로(CI): `tauri/src-tauri/target/**/release/bundle/**`

### 수동 실행
Actions 탭 → **build** → *Run workflow*. 단 **릴리스 발행은 태그 푸시일 때만**(`tagName` 조건).

---

## 자동 업데이트 (Windows 전용)

- 앱 시작 시 `releases/latest/download/latest.json` 을 확인 → 새 버전이면 **확인창** → 다운로드·설치·재시작.
  (구현: `tauri/src/main.ts` 의 `checkForUpdate()`, OS 판별은 Rust `get_os` 커맨드)
- **macOS 는 제외** — Homebrew cask(`brew upgrade`)로 업데이트.
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
