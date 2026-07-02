# DancingPet 🪩

메뉴바에 사는 데스크톱 펫 **와비(Waabi)**. 화면 아래를 어슬렁거리고, 가만히 있을 땐 여러 idle 동작을 하고, Dock 가장자리를 **측면 모션으로 오르내리며**, 시스템에서 소리가 나면 리듬을 타며 춤춥니다.

## 설치 (Homebrew)

```sh
brew install --cask asdeszqsc/tap/dancing-pet
```

설치 후 **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용(Accessibility)** 에서 `DancingPet`을 허용해 주세요. (Dock 위치 감지에 필요합니다.)

실행:

```sh
open -a DancingPet
```

메뉴바의 🎵 아이콘에서 캐릭터 선택 / 종료가 가능합니다.

## 기능

- 걷기 / 여러 종류의 idle(숨쉬기·푸쉬업·물마시기)
- Dock 가장자리 측면 등반(climb) 및 하강
- 드래그해서 옮기기 (놓으면 중력으로 낙하 + 착지 찌그러짐)
- 오디오 출력 감지 시 랜덤 댄스
- 멀티 모니터 이동 지원

## 소스에서 빌드

프로젝트는 두 구현으로 나뉩니다:
- **`tauri/`** — 크로스플랫폼(macOS + Windows) Tauri 앱 (현행)
- **`macos-swift/`** — 초기 macOS 전용 Swift 앱 (레거시)
- 스프라이트 원본 `assets/`, 생성기 `gen_waabi.swift` 는 루트에서 공유

### 크로스플랫폼 (Tauri)

```sh
cd tauri
npm install
npm run tauri dev      # 개발 (핫리로드)
npm run tauri build    # 릴리스 빌드
```

### macOS Swift (레거시)

```sh
swift gen_waabi.swift              # 스프라이트(assets/waabi) 생성 — 루트에서 실행
cd macos-swift && ./build_app.sh   # 컴파일 + DancingPet.app 번들 구성
open macos-swift/DancingPet.app
```

> 배포 · 릴리스 · 자동 업데이트 프로세스는 **[RELEASING.md](RELEASING.md)** 참고.

## 캐릭터 추가

1. `assets/<이름>/` 아래에 `walk`, `idle1~3`, `dance1~3`, `climb`, `held`, `fall` 스프라이트 준비
   (와비처럼 `gen_<이름>.swift` 생성기를 만들어 뽑는 것을 권장)
2. `main.swift`의 `kCharacters`에 `CharacterDef(name: "<이름>", title: "...", scale: ..., smooth: ...)` 한 줄 추가

로딩은 전부 `def.name` 기반이라 폴더 이름만 맞추면 메뉴에 자동으로 추가됩니다.

## 참고

앱은 Apple 공증(notarization)이 되어 있지 않습니다. Homebrew cask 설치 시 격리 속성을 자동 제거하므로 경고 없이 실행됩니다.
