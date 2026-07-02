// 캐릭터 상태머신 — main.swift 의 CharacterView.tick()/pickBehavior()/draw() 포팅.
// 내부 좌표는 Swift/Cocoa 와 동일하게 "바닥 기준(bottom-left, y 위로 증가)"을 유지한다.
// (캔버스 top-left 변환은 render.ts 가 담당 → Swift 상수/부호를 그대로 옮길 수 있음)

import type { CharacterFrames, Frames } from "./assets";

// ── 튜닝 상수 (main.swift 와 1:1) ──
export const FPS = 30;
export const WALK_SPEED = 0.7;
export const CLIMB_SPEED = 1.5;
export const GRAVITY = 1.4;
export const SQUASH_TICKS = 10;
export const FLOOR_Y = 6;
export const DOCK_FEET_INSET = 8;
export const WALK_FRAME_EVERY = 6;
export const IDLE_FRAME_EVERY = 6;
export const DANCE_FRAME_EVERY = 4;
export const DANCE_MIN_TICKS = 90;
export const DANCE_MAX_TICKS = 150;
export const DANCE_GAP_MIN = 600;
export const DANCE_GAP_MAX = 900;
export const IDLE_WEIGHTS = [7, 1.5, 1.5];

type Behavior = "idle" | "walkLeft" | "walkRight";
type Climb = "none" | "up" | "down";

// Swift Int.random(in: a...b) 는 양끝 포함
const randInt = (a: number, b: number) => a + Math.floor(Math.random() * (b - a + 1));
const clamp = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), hi);
function choice<T>(arr: T[]): T {
  return arr[Math.floor(Math.random() * arr.length)];
}

export class Pet {
  private f: CharacterFrames;
  readonly smooth: boolean;
  readonly spriteW: number;
  readonly spriteH: number;

  // 애니메이션 인덱스
  private currentDance = 0;
  private currentIdle = 0;
  private idleTick = 0;
  private moveTick = 0;
  private danceTick = 0;
  private tickCount = 0;
  private phase = 0;

  // 행동
  private behavior: Behavior = "idle";
  private behaviorTicks = 0;
  private dancingTicksLeft = 0;
  private danceCooldown = 90;
  private audioActive = false;

  // 댄스 간격 (dev 에서 관찰용으로 덮어쓸 수 있음)
  danceGapMin = DANCE_GAP_MIN;
  danceGapMax = DANCE_GAP_MAX;

  // 위치 (바닥 기준)
  posX = 200;
  direction: 1 | -1 = 1;
  feetY = FLOOR_Y;
  private climbing: Climb = "none";

  // 드래그/낙하
  private grabbed = false;
  private falling = false;
  private vY = 0;
  private grabDX = 0;
  private grabDY = 0;
  squashTicks = 0;

  // Dock
  dockValid = false;
  dockLeft = 0;
  dockRight = 0;
  dockTopY = 0;

  // 뷰 크기 (매 프레임 갱신)
  boundsW = 800;
  boundsH = 320;

  /// 화면 끝에서 옆 모니터로 이동 요청 (Phase 2)
  migrate?: (goingRight: boolean) => boolean;

  constructor(frames: CharacterFrames, scale: number, smooth: boolean) {
    this.f = frames;
    this.smooth = smooth;
    this.spriteW = frames.spriteW * scale;
    this.spriteH = frames.spriteH * scale;
  }

  get isGrabbed() {
    return this.grabbed;
  }
  get isDancing() {
    return this.dancingTicksLeft > 0;
  }

  // ── Dock / 오디오 ──
  setDock(valid: boolean, left = 0, right = 0, topY = 0) {
    if (valid) {
      this.dockLeft = left;
      this.dockRight = right;
      this.dockTopY = topY;
      this.dockValid = true;
    } else {
      this.dockValid = false;
      if (this.climbing === "none" && this.feetY > FLOOR_Y + 1) this.climbing = "down";
    }
  }

  notifyAudio(active: boolean) {
    if (active && !this.audioActive) this.danceCooldown = 0;
    this.audioActive = active;
  }

  /// 그 x 위치의 지면 높이 — Dock 가로범위 안이면 Dock 윗면, 밖이면 바닥
  private groundY(x: number): number {
    return this.dockValid && x >= this.dockLeft && x <= this.dockRight ? this.dockTopY : FLOOR_Y;
  }

  // ── 드래그 (canvas 좌표 cx,cy 입력; boundsH 로 바닥기준 변환) ──
  private hitBox() {
    return { x: this.posX - this.spriteW / 2, y: this.feetY, w: this.spriteW, h: this.spriteH };
  }

  grabAt(cx: number, cy: number): boolean {
    const fy = this.boundsH - cy;
    const b = this.hitBox();
    if (cx >= b.x && cx <= b.x + b.w && fy >= b.y && fy <= b.y + b.h) {
      this.grabbed = true;
      this.falling = false;
      this.vY = 0;
      this.climbing = "none";
      this.grabDX = this.posX - cx;
      this.grabDY = this.feetY - fy;
      return true;
    }
    return false;
  }

  dragTo(cx: number, cy: number) {
    if (!this.grabbed) return;
    const fy = this.boundsH - cy;
    this.posX = clamp(cx + this.grabDX, this.spriteW / 2, this.boundsW - this.spriteW / 2);
    this.feetY = clamp(fy + this.grabDY, FLOOR_Y, this.boundsH - this.spriteH);
  }

  release() {
    if (!this.grabbed) return;
    this.grabbed = false;
    const landY = this.groundY(this.posX);
    if (this.feetY > landY + 1) {
      this.falling = true;
      this.vY = 0;
    } else {
      this.feetY = landY;
      this.behavior = "idle";
      this.behaviorTicks = 0;
      this.squashTicks = SQUASH_TICKS;
    }
  }

  /// 커서가 캐릭터 위에 있는지 (클릭통과 토글용, Phase 2) — canvas 좌표
  isOverSprite(cx: number, cy: number): boolean {
    const fy = this.boundsH - cy;
    const b = this.hitBox();
    return cx >= b.x && cx <= b.x + b.w && fy >= b.y && fy <= b.y + b.h;
  }

  // ── 매 틱 (30fps) ──
  tick() {
    this.tickCount++;
    this.phase += 0.25;

    if (this.grabbed) return; // 잡혀있으면 위치는 dragTo 가 갱신

    if (this.falling) {
      this.vY -= GRAVITY;
      this.feetY += this.vY;
      const landY = this.groundY(this.posX);
      if (this.feetY <= landY) {
        this.feetY = landY;
        this.falling = false;
        this.vY = 0;
        this.behavior = "idle";
        this.behaviorTicks = 0;
        this.squashTicks = SQUASH_TICKS;
      }
      return;
    }

    if (this.squashTicks > 0) this.squashTicks--;

    const half = this.spriteW / 2;
    const minX = half + 8;
    const maxX = this.boundsW - half - 8;

    if (this.climbing !== "none") {
      const target = this.groundY(this.posX);
      const dy = target - this.feetY;
      if (Math.abs(dy) <= CLIMB_SPEED) {
        this.feetY = target;
        this.climbing = "none";
      } else {
        this.feetY += dy > 0 ? CLIMB_SPEED : -CLIMB_SPEED;
        this.moveTick++;
      }
    } else if (this.dancingTicksLeft > 0) {
      this.dancingTicksLeft--;
      this.danceTick++;
      if (this.dancingTicksLeft === 0) this.danceCooldown = randInt(this.danceGapMin, this.danceGapMax);
    } else {
      if (this.audioActive && this.danceCooldown > 0) this.danceCooldown--;
      const onGround = Math.abs(this.feetY - this.groundY(this.posX)) < 1.0;
      if (this.audioActive && this.danceCooldown <= 0 && this.f.dances.length && onGround) {
        this.currentDance = randInt(0, this.f.dances.length - 1);
        this.dancingTicksLeft = randInt(DANCE_MIN_TICKS, DANCE_MAX_TICKS);
        this.danceTick = 0;
      } else {
        this.behaviorTicks--;
        if (this.behaviorTicks <= 0) this.pickBehavior(minX, maxX);
        switch (this.behavior) {
          case "idle":
            this.idleTick++;
            break;
          case "walkLeft":
            this.direction = -1;
            this.posX -= WALK_SPEED;
            this.moveTick++;
            break;
          case "walkRight":
            this.direction = 1;
            this.posX += WALK_SPEED;
            this.moveTick++;
            break;
        }

        // 화면 끝: 옆 모니터로 이동 시도, 없으면 방향 전환
        if (this.posX > maxX) {
          if (this.behavior === "walkRight" && this.migrate?.(true)) {
            this.posX = this.spriteW / 2 + 8;
          } else {
            this.posX = maxX;
            this.pickBehavior(minX, maxX);
          }
        } else if (this.posX < minX) {
          if (this.behavior === "walkLeft" && this.migrate?.(false)) {
            this.posX = this.boundsW - this.spriteW / 2 - 8;
          } else {
            this.posX = minX;
            this.pickBehavior(minX, maxX);
          }
        }

        // 지면 높이가 어긋나면 오르내리기, 아니면 지면에 맞춤
        const g = this.groundY(this.posX);
        if (Math.abs(this.feetY - g) > 1) {
          this.climbing = this.feetY < g ? "up" : "down";
          if (this.dockValid) this.direction = this.posX < (this.dockLeft + this.dockRight) / 2 ? 1 : -1;
        } else {
          this.feetY = g;
        }
      }
    }
  }

  private weightedIdleIndex(): number {
    const n = this.f.idles.length;
    if (n <= 0) return 0;
    const weights = Array.from({ length: n }, (_, i) => (i < IDLE_WEIGHTS.length ? IDLE_WEIGHTS[i] : 1.0));
    const total = weights.reduce((a, b) => a + b, 0);
    let r = Math.random() * total;
    for (let i = 0; i < n; i++) {
      if (r < weights[i]) return i;
      r -= weights[i];
    }
    return n - 1;
  }

  private pickBehavior(minX: number, maxX: number) {
    const nearLeft = this.posX <= minX + 12;
    const nearRight = this.posX >= maxX - 12;
    const choices: Behavior[] = ["idle", "idle", "idle"];
    if (!nearLeft) choices.push("walkLeft", "walkLeft");
    if (!nearRight) choices.push("walkRight", "walkRight");
    this.behavior = choice(choices) ?? "idle";
    if (this.behavior === "idle") {
      if (this.f.idles.length) this.currentIdle = this.weightedIdleIndex();
      this.idleTick = 0;
      const reps = [3, 3, 2];
      const idleCount = this.f.idles[this.currentIdle]?.length ?? 10;
      const cyc = Math.max(1, idleCount * IDLE_FRAME_EVERY);
      this.behaviorTicks = cyc * (this.currentIdle < reps.length ? reps[this.currentIdle] : 2);
    } else {
      this.behaviorTicks = randInt(70, 160);
    }
  }

  // ── 현재 프레임 선택 (draw() 의 이미지 선택부 포팅) ──
  private frameOf(frames: Frames, counter: number, every: number): HTMLImageElement | null {
    if (!frames.length) return null;
    return frames[Math.floor(counter / Math.max(every, 1)) % frames.length];
  }

  currentFrame(): { img: HTMLImageElement | null; vy: number } {
    const f = this.f;
    let img: HTMLImageElement | null = null;
    let vy = 0;

    if (this.grabbed) {
      img = this.frameOf(f.held.length ? f.held : f.idles[0] ?? [], this.tickCount, 8);
      if (!img) img = this.frameOf(f.walk, 0, 1);
    } else if (this.falling) {
      img = this.frameOf(f.fall.length ? f.fall : f.walk, this.tickCount, 4);
    } else if (this.isDancing && this.climbing === "none") {
      const frames = this.currentDance >= 0 && this.currentDance < f.dances.length ? f.dances[this.currentDance] : [];
      img = this.frameOf(frames, this.danceTick, DANCE_FRAME_EVERY);
      vy = Math.abs(Math.sin(this.phase * 1.4)) * 3;
    } else if (this.climbing !== "none") {
      if (f.climb.length) {
        const prog = clamp((this.feetY - FLOOR_Y) / Math.max(1, this.dockTopY - FLOOR_Y), 0, 1);
        const idx = Math.round(prog * (f.climb.length - 1));
        img = f.climb[clamp(idx, 0, f.climb.length - 1)];
      } else {
        img = this.frameOf(f.walk, this.moveTick, WALK_FRAME_EVERY);
      }
    } else if (this.behavior === "idle") {
      const frames = f.idles[this.currentIdle] ?? [];
      if (frames.length) {
        img = this.frameOf(frames, this.idleTick, IDLE_FRAME_EVERY);
      } else {
        img = this.frameOf(f.walk, 0, 1);
        vy = Math.sin(this.phase * 0.8) * 1.5;
      }
    } else {
      img = this.frameOf(f.walk, this.moveTick, WALK_FRAME_EVERY);
    }

    return { img, vy };
  }
}
