// 렌더 — main.swift 의 draw() 캔버스 변환부 포팅.
// 내부 좌표(바닥 기준, y 위로)를 캔버스 좌표(top-left, y 아래로)로 변환한다.
//   캔버스 발 y = viewH - feetY - vy,  스프라이트는 발에서 위로 h 만큼.

import { Pet, SQUASH_TICKS } from "./pet";

export function render(ctx: CanvasRenderingContext2D, pet: Pet, viewH: number) {
  const { img, vy } = pet.currentFrame();
  if (!img) return;

  // 착지 찌그러짐: 발 기준 가로↑ 세로↓
  let sx = 1;
  let sy = 1;
  if (pet.squashTicks > 0) {
    const amt = pet.squashTicks / SQUASH_TICKS;
    sx = 1 + 0.18 * amt;
    sy = 1 - 0.22 * amt;
  }

  const w = pet.spriteW;
  const h = pet.spriteH;
  const feetCanvasY = viewH - pet.feetY - vy;

  ctx.imageSmoothingEnabled = pet.smooth;
  ctx.save();
  ctx.translate(pet.posX, feetCanvasY);
  ctx.scale(pet.direction * sx, sy);
  ctx.drawImage(img, -w / 2, -h, w, h);
  ctx.restore();
}

/// dev: fake Dock 범위를 파란 띠로 (climb 정렬 확인용) — main.swift 개발모드 시각화와 동일
export function drawDockBand(ctx: CanvasRenderingContext2D, pet: Pet, viewH: number) {
  const x = pet.dockLeft;
  const w = pet.dockRight - pet.dockLeft;
  const topCanvasY = viewH - pet.dockTopY;
  const h = pet.dockTopY;
  ctx.save();
  ctx.fillStyle = "rgba(10,132,255,0.15)";
  ctx.fillRect(x, topCanvasY, w, h);
  ctx.strokeStyle = "rgba(10,132,255,0.6)";
  ctx.lineWidth = 2;
  ctx.strokeRect(x + 1, topCanvasY + 1, w - 2, h - 2);
  ctx.restore();
}
