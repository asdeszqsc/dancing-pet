// 루트 assets/waabi 를 tauri/public/waabi 로 복사하고 manifest.json 을 생성한다.
// 스프라이트 원본은 repo 루트 assets/ 한 곳에만 두고(gen_waabi.swift 출력 위치),
// dev/build 시점에 프론트가 접근 가능한 public/ 으로 복제한다.
// 심링크 대신 실복사 → Windows 체크아웃/CI 에서도 안전.
// manifest: 프론트는 디렉터리 목록을 못 읽으니, 캐릭터별 폴더→프레임파일 목록을 JSON 으로 남긴다.
import { cpSync, existsSync, mkdirSync, rmSync, readdirSync, writeFileSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url)); // tauri/scripts
const repoRoot = join(here, "..", ".."); // repo 루트
const srcRoot = join(repoRoot, "assets"); // 캐릭터들이 들어있는 루트
const src = join(srcRoot, "waabi");
const destDir = join(here, "..", "public"); // tauri/public
const dest = join(destDir, "waabi");

if (!existsSync(src)) {
  console.error(`[sync-assets] 원본 없음: ${src}`);
  process.exit(1);
}
mkdirSync(destDir, { recursive: true });
rmSync(dest, { recursive: true, force: true });
cpSync(src, dest, { recursive: true });

// manifest: { "walk": ["walk_00.png", ...], "idle1": [...], ... }
const manifest = {};
for (const entry of readdirSync(dest)) {
  const sub = join(dest, entry);
  if (!statSync(sub).isDirectory()) continue;
  const pngs = readdirSync(sub)
    .filter((f) => f.toLowerCase().endsWith(".png"))
    .sort();
  if (pngs.length) manifest[entry] = pngs;
}
writeFileSync(join(dest, "manifest.json"), JSON.stringify(manifest, null, 0));

console.log(`[sync-assets] ${src} → ${dest} (${Object.keys(manifest).length} folders)`);
