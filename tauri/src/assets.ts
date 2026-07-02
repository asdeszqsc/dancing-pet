// 스프라이트 로딩 — sync-assets 가 만든 manifest.json 기반.
// main.swift 의 loadFrames(def.name + "/walk") 등을 대체.

export type Frames = HTMLImageElement[];

export interface CharacterFrames {
  walk: Frames;
  idles: Frames[]; // idle1..3 (없으면 idle)
  dances: Frames[]; // dance1..8 (없으면 dance)
  climb: Frames;
  held: Frames;
  fall: Frames;
  spriteW: number; // 원본(스케일 전) 스프라이트 크기
  spriteH: number;
}

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error(`load fail: ${src}`));
    img.src = src;
  });
}

export async function loadCharacter(name: string): Promise<CharacterFrames> {
  const manifest: Record<string, string[]> = await fetch(`/${name}/manifest.json`).then((r) => {
    if (!r.ok) throw new Error(`manifest 없음: /${name}/manifest.json`);
    return r.json();
  });

  const loadFolder = async (folder: string): Promise<Frames> => {
    const files = manifest[folder];
    if (!files || !files.length) return [];
    return Promise.all(files.map((f) => loadImage(`/${name}/${folder}/${f}`)));
  };

  const walk = await loadFolder("walk");

  const idles: Frames[] = [];
  for (let i = 1; i <= 3; i++) {
    const f = await loadFolder(`idle${i}`);
    if (f.length) idles.push(f);
  }
  if (!idles.length) {
    const f = await loadFolder("idle");
    if (f.length) idles.push(f);
  }

  const dances: Frames[] = [];
  for (let i = 1; i <= 8; i++) {
    const f = await loadFolder(`dance${i}`);
    if (f.length) dances.push(f);
  }
  if (!dances.length) {
    const f = await loadFolder("dance");
    if (f.length) dances.push(f);
  }

  const climb = await loadFolder("climb");
  const held = await loadFolder("held");
  const fall = await loadFolder("fall");

  const first = walk[0];
  return {
    walk,
    idles,
    dances,
    climb,
    held,
    fall,
    spriteW: first?.naturalWidth ?? 80,
    spriteH: first?.naturalHeight ?? 80,
  };
}
