// DancingPet — 진입점. 캐릭터 로드 → 30fps 로직 틱 + rAF 렌더. (Phase 2)
// main.swift 의 AppDelegate 상당. 창/트레이/커서폴링은 Rust(lib.rs), 여기선 배선.

import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { load } from "@tauri-apps/plugin-store";
import { check } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { ask, message } from "@tauri-apps/plugin-dialog";
import { loadCharacter } from "./assets";
import { Pet, FPS, FLOOR_Y } from "./pet";
import { render, drawDockBand } from "./render";

// 자동 업데이트 — 시작 시 새 버전 확인.
// Windows: 확인창 → 설치 → 재시작. macOS: 자동 설치 없이 Homebrew 업데이트 안내만.
async function checkForUpdate() {
  try {
    const os = await invoke<string>("get_os");
    if (os !== "windows" && os !== "macos") return;
    const update = await check();
    if (!update) return;
    if (os === "windows") {
      const yes = await ask(
        `새 버전 ${update.version} 이(가) 있어요.\n지금 설치할까요? (설치 후 자동 재시작)`,
        { title: "DancingPet 업데이트", kind: "info" }
      );
      if (!yes) return;
      await update.downloadAndInstall();
      await relaunch();
    } else {
      await message(
        `새 버전 ${update.version} 이(가) 있어요.\n\n터미널에서 업데이트해 주세요:\n  brew upgrade --cask dancing-pet\n\n(직접 설치했다면 GitHub 릴리스에서 새 .dmg 를 받아 주세요)`,
        { title: "DancingPet 업데이트", kind: "info" }
      );
    }
  } catch (e) {
    console.error("업데이트 확인 실패:", e);
  }
}

// dev 토글
const DEV = {
  showDockBand: false, // 감지된 Dock 범위 시각화 (디버그용)
  danceGap: null as [number, number] | null, // null = 실제 간격(600~900)
};

const CHARACTER = { name: "waabi", scale: 1.1, smooth: false };

async function main() {
  const canvas = document.getElementById("pet-canvas") as HTMLCanvasElement;
  const ctx = canvas.getContext("2d")!;

  const frames = await loadCharacter(CHARACTER.name);
  const pet = new Pet(frames, CHARACTER.scale, CHARACTER.smooth);
  pet.migrate = () => false; // 자동 크로스모니터 이동은 후속 (드래그/트레이로 수동 이동 제공)

  if (DEV.danceGap) {
    pet.danceGapMin = DEV.danceGap[0];
    pet.danceGapMax = DEV.danceGap[1];
  }

  function resize() {
    // dpr 은 매번 읽는다 — 드래그로 scale 이 다른 모니터로 넘어가면 바뀜
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.round(window.innerWidth * dpr);
    canvas.height = Math.round(window.innerHeight * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    pet.boundsW = window.innerWidth;
    pet.boundsH = window.innerHeight;
  }
  resize();
  window.addEventListener("resize", resize);

  // 시작 위치: 화면 하단 중앙
  pet.posX = window.innerWidth / 2;
  pet.feetY = FLOOR_Y;

  // ── 실제 오디오 출력 감지 (Rust CoreAudio 폴링) → 소리날 때만 춤 ──
  listen<boolean>("audio-active", (e) => {
    pet.notifyAudio(e.payload);
  });

  // ── 실제 Dock/작업표시줄 감지 (Rust, 매초) → climb ──
  listen<{ left: number; right: number; topY: number } | null>("dock", (e) => {
    const d = e.payload;
    if (d) pet.setDock(true, d.left, d.right, d.topY);
    else pet.setDock(false);
  });

  // ── 설정 저장: 마지막 디스플레이 복원 ──
  const store = await load("settings.json", { autoSave: true, defaults: {} });
  const savedDisplay = (await store.get<number>("displayIndex")) ?? 0;
  if (savedDisplay > 0) {
    try {
      await invoke("place_on_display", { idx: savedDisplay });
    } catch {}
  }
  listen<number>("display-changed", (e) => {
    void store.set("displayIndex", e.payload);
  });

  // ── About (트레이 메뉴) ──
  listen("menu-about", () => {
    alert("DancingPet — 메뉴바에서 춤추는 데스크톱 펫 와비(Waabi)\n\ngithub.com/asdeszqsc/dancing-pet");
  });

  // ── 클릭통과 토글: 커서가 캐릭터 위(또는 드래그 중)일 때만 상호작용 ──
  let clickThrough = true; // 시작은 통과(Rust setup 과 일치)
  async function setClickThrough(through: boolean) {
    if (through === clickThrough) return;
    clickThrough = through;
    try {
      await invoke("set_click_through", { through });
    } catch {}
  }
  let overSprite = false;
  listen<[number, number]>("cursor", (e) => {
    const [lx, ly] = e.payload;
    // 드래그 중엔 Rust 폴링 좌표로도 위치 갱신 — 창이 다른 모니터로 점프한 직후
    // pointermove 가 오기 전에도 캐릭터가 커서에 붙어있게 한다
    if (pet.isGrabbed) pet.dragTo(lx, ly);
    const over = pet.isGrabbed || pet.isOverSprite(lx, ly);
    if (over !== overSprite) {
      overSprite = over;
      void setClickThrough(!over);
    }
  });

  // ── 드래그 (클릭통과 해제 상태에서 pointer 이벤트 수신) ──
  // 잡힘 상태를 Rust 에 알리면 커서 폴링이 커서가 있는 모니터로 창을 옮겨
  // 드래그로 모니터 간 이동이 된다 (main.swift ensureScreen 포팅)
  canvas.addEventListener("pointerdown", (e) => {
    if (pet.grabAt(e.clientX, e.clientY)) {
      canvas.setPointerCapture(e.pointerId);
      void invoke("set_grabbed", { grabbed: true });
    }
  });
  canvas.addEventListener("pointermove", (e) => {
    if (pet.isGrabbed) pet.dragTo(e.clientX, e.clientY);
  });
  const endDrag = () => {
    if (!pet.isGrabbed) return;
    pet.release();
    void invoke("set_grabbed", { grabbed: false });
  };
  canvas.addEventListener("pointerup", endDrag);
  canvas.addEventListener("pointercancel", endDrag);

  // ── 30fps 로직 틱 ──
  setInterval(() => {
    pet.tick();
  }, 1000 / FPS);

  // ── 렌더 루프 (rAF) ──
  function frame() {
    ctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
    if (DEV.showDockBand && pet.dockValid) drawDockBand(ctx, pet, window.innerHeight);
    render(ctx, pet, window.innerHeight);
    requestAnimationFrame(frame);
  }
  frame();

  // 시작 시 자동 업데이트 확인 (Windows)
  void checkForUpdate();
}

main().catch((e) => {
  document.body.innerHTML = `<pre style="color:red;background:#fff;padding:8px">${e}\n${e?.stack ?? ""}</pre>`;
});
