import Cocoa

// 도트(픽셀 아트) 와비 스프라이트 생성기 (퀄리티 업: 외곽선 + 음영/하이라이트 + 고해상도 + 프레임↑)
// 저해상도 도형을 안티앨리어싱 OFF로 그려 픽셀 느낌, 실루엣 8방향 더블드로우로 외곽선.

let DESIGN_W: CGFloat = 48      // 원래 디자인 좌표계
let DESIGN_H: CGFloat = 72
let FIG_W: CGFloat = 64         // 피규어가 차지하는 폭(px) — 캔버스 크기와 무관하게 고정
let W = 96, H = 112             // 실제 캔버스(사방 여백 포함 → 팔 든 동작/푸쉬업이 안 잘림)
let S = FIG_W / DESIGN_W       // 디자인→피규어 스케일 (고정)
let GX: CGFloat = (CGFloat(W) - FIG_W) / 2   // 피규어를 가로 가운데로
let GY: CGFloat = 0            // 발은 캔버스 바닥에 (위/옆으로만 여백)
let pi = CGFloat.pi

func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}
let SKIN    = col(0.49, 0.84, 0.56)   // 기본 연두
let SKIN_D  = col(0.30, 0.58, 0.38)   // 진한 그림자(다리 등)
let SKIN_SH = col(0.42, 0.74, 0.50)   // 부드러운 그림자(얼굴/몸)
let SKIN_L  = col(0.66, 0.93, 0.70)   // 하이라이트
let EYE     = col(0.07, 0.10, 0.08)
let WHITE   = NSColor.white.cgColor
let OUTLINE = col(0.10, 0.16, 0.11)   // 외곽선(짙은 녹)
let HAT     = col(0.09, 0.09, 0.12)   // 검은 페도라
let HATBAND = col(0.34, 0.32, 0.40)   // 모자 밴드
let HAIR    = col(0.97, 0.82, 0.22)   // 나루토 노란 머리
let HAIR_SH = col(0.85, 0.66, 0.12)   // 머리 그림자
let BAND_BL = col(0.13, 0.20, 0.40)   // 헤드밴드(남색)
let PLATE   = col(0.76, 0.79, 0.84)   // 헤드밴드 금속판

// 관절에서 뻗는 단일 막대 (더듬이 등). tint 지정 시 그 색 = 외곽선 패스용
func limb(_ ctx: CGContext, _ jx: CGFloat, _ jy: CGFloat, _ angle: CGFloat,
          _ len: CGFloat, _ w: CGFloat, _ c: CGColor, tip: CGColor? = nil, tint: CGColor? = nil) {
    ctx.saveGState()
    ctx.translateBy(x: jx, y: jy)
    ctx.rotate(by: angle)
    ctx.setFillColor(tint ?? c)
    ctx.fill(CGRect(x: -w / 2, y: -len, width: w, height: len))
    if let tip = tip {
        ctx.setFillColor(tint ?? tip)
        ctx.fill(CGRect(x: -w / 2 - 1, y: -len, width: w + 2, height: 3))
    }
    ctx.restoreGState()
}

// 2관절 사지: 상박/대퇴(l1) + 관절(무릎/팔꿈치) + 전완/정강이(l2).
//   root = 상박/대퇴 각도, bend = 전완/정강이가 상박/대퇴에 대해 꺾이는 각도(0=곧음).
//   각도 규약: 0=아래, +면 +x쪽으로 스윙 (단일 limb과 동일).
func limb2(_ ctx: CGContext, _ jx: CGFloat, _ jy: CGFloat,
           _ root: CGFloat, _ bend: CGFloat,
           _ l1: CGFloat, _ l2: CGFloat, _ w1: CGFloat, _ w2: CGFloat,
           _ c: CGColor, joint: CGColor, tip: CGColor? = nil, tint: CGColor? = nil) {
    ctx.saveGState()
    ctx.translateBy(x: jx, y: jy)
    ctx.rotate(by: root)
    // 상박/대퇴
    ctx.setFillColor(tint ?? c)
    ctx.fill(CGRect(x: -w1 / 2, y: -l1, width: w1, height: l1))
    // 관절로 이동 후 꺾기
    ctx.translateBy(x: 0, y: -l1)
    ctx.rotate(by: bend)
    // 관절 동그라미(무릎/팔꿈치)
    ctx.setFillColor(tint ?? joint)
    ctx.fillEllipse(in: CGRect(x: -w1 / 2, y: -w1 / 2, width: w1, height: w1))
    // 전완/정강이
    ctx.setFillColor(tint ?? c)
    ctx.fill(CGRect(x: -w2 / 2, y: -l2, width: w2, height: l2))
    if let tip = tip {
        ctx.setFillColor(tint ?? tip)
        ctx.fill(CGRect(x: -w2 / 2 - 1, y: -l2, width: w2 + 2, height: 3))
    }
    ctx.restoreGState()
}

// 2관절 IK: (jx,jy)에서 시작해 끝(손/발)이 (tx,ty)에 닿도록 root/bend 계산.
//   dir = +1/-1 로 관절이 꺾이는 방향(앞/뒤, 무릎/팔꿈치) 선택.
func ik2(_ jx: CGFloat, _ jy: CGFloat, _ tx: CGFloat, _ ty: CGFloat,
         _ l1: CGFloat, _ l2: CGFloat, _ dir: CGFloat) -> (root: CGFloat, bend: CGFloat) {
    let dx = tx - jx, dy = ty - jy
    var d = (dx * dx + dy * dy).squareRoot()
    d = min(max(d, abs(l1 - l2) + 0.001), l1 + l2 - 0.001)   // 도달 가능 범위로 클램프
    // 어깨/엉덩이 각: 관절→목표 방향과 상박/대퇴 사이 각(코사인 법칙)
    let a1 = acos(min(1, max(-1, (l1 * l1 + d * d - l2 * l2) / (2 * l1 * d))))
    let a2 = acos(min(1, max(-1, (l1 * l1 + l2 * l2 - d * d) / (2 * l1 * l2))))
    // 목표 방향을 limb 각도 규약(0=아래,(sinθ,-cosθ))으로: θ = atan2(dx, -dy)
    let toTarget = atan2(dx, -dy)
    let root = toTarget + dir * a1
    let bend = -dir * (pi - a2)          // 전완/정강이가 상박/대퇴 기준 꺾이는 각
    return (root, bend)
}

// 캐릭터 본체 (tint != nil 이면 전부 그 색 = 실루엣). 좌표는 48×72 디자인 기준.
// 사지는 2관절: arm*/leg* = 어깨/엉덩이 각, *B = 팔꿈치/무릎 꺾임(0=곧음).
func figure(_ ctx: CGContext, tint: CGColor?,
            legL: CGFloat, legR: CGFloat, armL: CGFloat, armR: CGFloat,
            ant: CGFloat, bob: CGFloat, tilt: CGFloat,
            legLB: CGFloat = 0, legRB: CGFloat = 0, armLB: CGFloat = 0, armRB: CGFloat = 0,
            headBob: CGFloat = 0, eyeOpen: Bool = true, profile: Bool = false,
            hat: Bool = false, hair: Bool = false, hatTilt: CGFloat = 0) {
    func C(_ c: CGColor) -> CGColor { tint ?? c }
    ctx.setShouldAntialias(false)
    ctx.saveGState()
    ctx.translateBy(x: 24, y: 2 + bob)
    ctx.rotate(by: tilt)

    // 다리 (대퇴 12 + 무릎 + 정강이 10)
    limb2(ctx, -3, 24, legL, legLB, 12, 10, 4.4, 3.4, SKIN_D, joint: SKIN_D, tip: EYE, tint: tint)
    limb2(ctx,  3, 24, legR, legRB, 12, 10, 4.4, 3.4, SKIN_D, joint: SKIN_D, tip: EYE, tint: tint)
    // 팔 (상박 11 + 팔꿈치 + 전완 9)
    limb2(ctx, -5, 39, armL, armLB, 11, 9, 3.4, 2.6, SKIN, joint: SKIN, tip: SKIN_D, tint: tint)
    limb2(ctx,  5, 39, armR, armRB, 11, 9, 3.4, 2.6, SKIN, joint: SKIN, tip: SKIN_D, tint: tint)

    // 몸통 + 음영/하이라이트
    ctx.setFillColor(C(SKIN));    ctx.fill(CGRect(x: -5, y: 24, width: 10, height: 17))
    ctx.setFillColor(C(SKIN_SH)); ctx.fill(CGRect(x: 3,  y: 24, width: 2,  height: 17))   // 우측 슬림 그림자
    ctx.setFillColor(C(SKIN_L));  ctx.fill(CGRect(x: -5, y: 24, width: 2,  height: 17))   // 좌측 하이라이트

    // ---- 머리 그룹 ----
    ctx.saveGState()
    ctx.translateBy(x: 0, y: headBob)
    ctx.setFillColor(C(SKIN))
    ctx.fillEllipse(in: CGRect(x: -9, y: 40, width: 18, height: 16))
    ctx.setFillColor(C(SKIN_SH))
    ctx.fillEllipse(in: CGRect(x: 5.5, y: 43, width: 3, height: 9))    // 머리 우측 슬림 그림자
    ctx.setFillColor(C(SKIN_L))
    ctx.fillEllipse(in: CGRect(x: -8, y: 50, width: 4, height: 4))     // 머리 좌상단 광(작게)

    if profile {
        // 옆모습: 앞쪽(+y, 더듬이 방향)을 향한 눈 하나 + 앞쪽 입
        if eyeOpen {
            ctx.setFillColor(C(EYE))
            ctx.fillEllipse(in: CGRect(x: -1, y: 45, width: 7, height: 8))
            ctx.setFillColor(C(WHITE))
            ctx.fill(CGRect(x: 2, y: 50, width: 2, height: 2))
        } else {
            ctx.setFillColor(C(EYE))
            ctx.fill(CGRect(x: -1, y: 48, width: 7, height: 2))
        }
        // 입(앞쪽 가장자리)
        ctx.setFillColor(C(EYE))
        ctx.fill(CGRect(x: 6, y: 44, width: 3, height: 1))
    } else if eyeOpen {
        ctx.setFillColor(C(EYE))
        ctx.fillEllipse(in: CGRect(x: -7, y: 44, width: 6, height: 8))
        ctx.fillEllipse(in: CGRect(x: 1,  y: 44, width: 6, height: 8))
        ctx.setFillColor(C(WHITE))
        ctx.fill(CGRect(x: -5, y: 49, width: 2, height: 2))
        ctx.fill(CGRect(x: 3,  y: 49, width: 2, height: 2))
        // 입
        ctx.setFillColor(C(EYE))
        ctx.fill(CGRect(x: -2, y: 42, width: 4, height: 1))
    } else {
        ctx.setFillColor(C(EYE))
        ctx.fill(CGRect(x: -7, y: 47, width: 6, height: 2))
        ctx.fill(CGRect(x: 1,  y: 47, width: 6, height: 2))
        ctx.setFillColor(C(EYE))
        ctx.fill(CGRect(x: -2, y: 42, width: 4, height: 1))
    }

    if hat {
        // 검은 페도라 (챙 + 크라운 + 밴드). hatTilt<0 → 앞으로 기울여 눈을 가림
        ctx.saveGState()
        ctx.translateBy(x: -4, y: 56); ctx.rotate(by: hatTilt); ctx.translateBy(x: 4, y: -56)
        ctx.setFillColor(C(HAT))
        ctx.fillEllipse(in: CGRect(x: -13, y: 51, width: 26, height: 5))   // 챙
        ctx.fill(CGRect(x: -6, y: 54, width: 12, height: 9))               // 크라운
        ctx.fillEllipse(in: CGRect(x: -6, y: 60, width: 12, height: 5))    // 크라운 위
        ctx.setFillColor(C(HATBAND))
        ctx.fill(CGRect(x: -6, y: 54, width: 12, height: 2))               // 밴드
        ctx.restoreGState()
    } else if hair {
        // 나루토풍 노란 스파이크 머리 + 헤드밴드
        func spike(_ bx: CGFloat, _ by: CGFloat, _ hw: CGFloat, _ tx: CGFloat, _ ty: CGFloat) {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: bx - hw, y: by))
            ctx.addLine(to: CGPoint(x: tx, y: ty))
            ctx.addLine(to: CGPoint(x: bx + hw, y: by))
            ctx.closePath(); ctx.fillPath()
        }
        ctx.setFillColor(C(HAIR))
        ctx.fillEllipse(in: CGRect(x: -9, y: 52, width: 18, height: 9))    // 두피 덮기
        spike(-7, 55, 3.0, -13, 64)                                        // 위·옆 스파이크들
        spike(-3, 56, 3.2,  -5, 70)
        spike( 1, 56, 3.2,   3, 71)
        spike( 5, 55, 3.0,  12, 65)
        spike(-9, 53, 2.6, -16, 58)
        spike( 9, 53, 2.6,  16, 57)
        spike(-7, 52, 2.4,  -9, 45)                                        // 옆 앞머리
        spike( 7, 52, 2.4,   9, 46)
        ctx.setFillColor(C(BAND_BL))                                       // 헤드밴드
        ctx.fill(CGRect(x: -9, y: 51, width: 18, height: 3))
        ctx.setFillColor(C(PLATE))                                         // 금속판
        ctx.fill(CGRect(x: -3, y: 51, width: 6, height: 3))
    } else {
        // 더듬이
        limb(ctx, -3, 54, pi + ant, 6, 2, SKIN_D, tint: tint)
        limb(ctx,  3, 54, pi - ant, 6, 2, SKIN_D, tint: tint)
        func dot(_ jx: CGFloat, _ angle: CGFloat) {
            ctx.saveGState()
            ctx.translateBy(x: jx, y: 54); ctx.rotate(by: angle)
            ctx.setFillColor(C(SKIN))
            ctx.fillEllipse(in: CGRect(x: -2, y: -9, width: 4, height: 4))
            ctx.restoreGState()
        }
        dot(-3, pi + ant)
        dot( 3, pi - ant)
    }

    ctx.restoreGState()   // 머리 그룹
    ctx.restoreGState()
}

// 외곽선(실루엣 8방향) + 본체. 호출부는 이 함수를 그대로 사용.
// ox/oy = 캔버스 픽셀 오프셋, scl = 전체 크기 배율 (푸쉬업처럼 눕혀 배치할 때 사용)
func drawWaabi(_ ctx: CGContext, legL: CGFloat, legR: CGFloat,
               armL: CGFloat, armR: CGFloat, ant: CGFloat,
               bob: CGFloat, tilt: CGFloat,
               legLB: CGFloat = 0, legRB: CGFloat = 0, armLB: CGFloat = 0, armRB: CGFloat = 0,
               headBob: CGFloat = 0, eyeOpen: Bool = true, profile: Bool = false,
               hat: Bool = false, hair: Bool = false, hatTilt: CGFloat = 0,
               ox: CGFloat = 0, oy: CGFloat = 0, scl: CGFloat = 1) {
    ctx.setShouldAntialias(false)
    let off: CGFloat = 1.2
    let dirs: [(CGFloat, CGFloat)] = [(-off,0),(off,0),(0,-off),(0,off),
                                      (-off,-off),(off,off),(-off,off),(off,-off)]
    func pass(_ tint: CGColor?) {
        ctx.saveGState()
        ctx.translateBy(x: GX + ox, y: GY + oy)
        ctx.scaleBy(x: S * scl, y: S * scl)
        figure(ctx, tint: tint, legL: legL, legR: legR, armL: armL, armR: armR,
               ant: ant, bob: bob, tilt: tilt,
               legLB: legLB, legRB: legRB, armLB: armLB, armRB: armRB,
               headBob: headBob, eyeOpen: eyeOpen, profile: profile, hat: hat, hair: hair, hatTilt: hatTilt)
        ctx.restoreGState()
    }
    for (dx, dy) in dirs {
        ctx.saveGState()
        ctx.translateBy(x: dx, y: dy)
        pass(OUTLINE)
        ctx.restoreGState()
    }
    pass(nil)
}

func makeFrame(_ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let nsctx = NSGraphicsContext(bitmapImageRep: rep)!
    nsctx.shouldAntialias = false
    NSGraphicsContext.current = nsctx
    draw(nsctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let base = fm.currentDirectoryPath
func mkdir(_ p: String) { try? fm.createDirectory(atPath: p, withIntermediateDirectories: true) }
let A = base + "/assets/waabi"

// 걷기 8프레임 (어슬렁: 발을 살짝만 들어 무릎 적게 굽히고, 좌우로 느긋하게 흔들며 팔도 가볍게)
let walkN = 8
mkdir(A + "/walk")
for i in 0..<walkN {
    let t = 2 * pi * CGFloat(i) / CGFloat(walkN)
    let liftL = max(0, sin(t)), liftR = max(0, sin(t + pi))
    // 발 들어올림을 2 정도로 더 낮춰 무릎은 거의 안 굽고 슬쩍만 들림
    let (lL, lLB) = ik2(-3, 24, -3 - 0.6 * liftL, 2 + 2 * liftL, 12, 10, -1)
    let (lR, lRB) = ik2( 3, 24,  3 + 0.6 * liftR, 2 + 2 * liftR, 12, 10,  1)
    let sw = sin(t) * 0.32
    let rep = makeFrame { ctx in
        drawWaabi(ctx, legL: lL, legR: lR,
                  armL: -0.16 - sw * 0.5, armR: 0.16 + sw * 0.5,    // 팔 느슨하게 흔듦
                  ant: sin(t) * 0.12, bob: abs(sin(t)) * 0.8,        // 바운스 줄임
                  tilt: sin(t) * 0.05,                               // 좌우로 느긋한 스웨거
                  legLB: lLB, legRB: lRB, armLB: 0.20, armRB: -0.20) // 팔꿈치 살짝만
    }
    save(rep, to: String(format: "%@/walk/walk_%02d.png", A, i))
}

// ===== idle 3종 (앱에서 랜덤 재생) =====
try? fm.removeItem(atPath: A + "/idle")   // 옛 단일 idle 폴더 제거

// idle1: 숨쉬기 (편히 선 자세 + 더듬이 + 깜빡임)
let idle1N = 10
mkdir(A + "/idle1")
for i in 0..<idle1N {
    let t = 2 * pi * CGFloat(i) / CGFloat(idle1N)
    let breathe = sin(t)
    let rep = makeFrame { ctx in
        drawWaabi(ctx, legL: 0.04, legR: -0.04, armL: -0.10, armR: 0.10,
                  ant: breathe * 0.18, bob: 0, tilt: 0,
                  legLB: 0.10 + breathe * 0.04, legRB: 0.10 + breathe * 0.04,
                  armLB: 0.22, armRB: -0.22,
                  headBob: breathe * 1.2, eyeOpen: (i != 7))
    }
    save(rep, to: String(format: "%@/idle1/idle1_%02d.png", A, i))
}

// idle2: 푸쉬업 (옆모습 완전 플랭크 — 다리 곧게, 손은 어깨 밑 바닥, 팔꿈치는 뒤로 접힘)
let idle2N = 8
mkdir(A + "/idle2")
let pScl: CGFloat = 0.9, pOx: CGFloat = -18, pBob: CGFloat = 0, pFloorY: CGFloat = 5
// 어깨에서 손이 어깨 바로 아래 바닥에 닿도록 IK (몸이 숙일수록 팔꿈치가 뒤로 접힘)
func plantHand(_ jx: CGFloat, _ jy: CGFloat, _ tilt: CGFloat, _ oy: CGFloat) -> (CGFloat, CGFloat) {
    let rx = jx * cos(tilt) - jy * sin(tilt)
    let jcx = pOx + S * pScl * (24 + rx)
    let v0 = ((jcx - pOx) / (S * pScl) - 24, (pFloorY - oy) / (S * pScl) - (2 + pBob))
    let ct = cos(-tilt), st = sin(-tilt)
    let px = v0.0 * ct - v0.1 * st, py = v0.0 * st + v0.1 * ct
    return ik2(jx, jy, px, py, 11, 9, -1)        // dir=-1 → 팔꿈치 뒤(옆)로
}
for i in 0..<idle2N {
    let t = 2 * pi * CGFloat(i) / CGFloat(idle2N)
    let dip = (1 - cos(t)) / 2          // 0(위)→1(아래)→0(위)
    let tilt = -1.20 - dip * 0.26       // 내려갈 때 몸 전체가 더 평평하게 숙임(플랭크 유지)
    let oy: CGFloat = 12
    let (aL, aLB) = plantHand(-5, 39, tilt, oy)
    let (aR, aRB) = plantHand( 5, 39, tilt, oy)
    let rep = makeFrame { ctx in
        drawWaabi(ctx, legL: 0, legR: 0, armL: aL, armR: aR,   // 다리 곧게(무릎 안 굽힘)
                  ant: 0.04, bob: pBob, tilt: tilt,
                  legLB: 0, legRB: 0, armLB: aLB, armRB: aRB,
                  headBob: 1.2, profile: true,
                  ox: pOx, oy: oy, scl: pScl)
    }
    save(rep, to: String(format: "%@/idle2/idle2_%02d.png", A, i))
}

// idle3: 물병 들고 물마시기 (양손으로 병을 잡고 입으로 올려 마심)
let idle3N = 12
mkdir(A + "/idle3")
for i in 0..<idle3N {
    let t = CGFloat(i) / CGFloat(idle3N - 1)             // 0→1 (한 번 마시기)
    let raise: CGFloat = t < 0.25 ? t / 0.25 : (t < 0.8 ? 1 : (1 - t) / 0.2)
    let drinking = (t >= 0.25 && t < 0.8)
    let glug: CGFloat = drinking ? sin((t - 0.25) / 0.55 * pi * 3) * 0.04 : 0
    let hy = 22 + raise * 17                              // 손 높이: 허리→입
    let (aL, aLB) = ik2(-5, 39, -2, hy, 11, 9, -1)
    let (aR, aRB) = ik2( 5, 39,  2, hy, 11, 9,  1)
    let rep = makeFrame { ctx in
        drawWaabi(ctx, legL: 0.04, legR: -0.04, armL: aL, armR: aR,
                  ant: 0.05, bob: 0, tilt: -raise * 0.10,     // 마실 때 몸 살짝 뒤로
                  legLB: 0.10, legRB: 0.10, armLB: aLB, armRB: aRB,
                  headBob: raise * 2.5 + glug * 10, eyeOpen: !drinking)
        // 물병: 양손 사이에서 입쪽으로 (캔버스 좌표, 여백 보정)
        let by = GY + (2 + hy) * S
        ctx.saveGState()
        ctx.translateBy(x: GX + 32, y: by)
        ctx.rotate(by: raise * 0.5)                          // 마실수록 병을 기울임
        ctx.setFillColor(col(0.40, 0.72, 0.95, 0.92))        // 병 몸통
        ctx.fill(CGRect(x: -3, y: -2, width: 6, height: 12))
        ctx.setFillColor(col(0.95, 0.96, 0.98))              // 뚜껑
        ctx.fill(CGRect(x: -2, y: 9, width: 4, height: 3))
        ctx.restoreGState()
    }
    save(rep, to: String(format: "%@/idle3/idle3_%02d.png", A, i))
}

// climb 12프레임 (측면 mantle: 옆모습으로 dock 윗턱을 잡고 → 몸을 끌어올려 → 정상 기립)
//   정면이 아니라 옆모습(profile)이라 dock 가장자리에서 벽을 딛고 오르는 게 자연스럽다.
//   벽은 +x(캐릭터 앞쪽). app이 posX<dock중심이면 direction=+1, 아니면 -1로 뒤집어 항상 벽을 향함.
//   핵심 착시: 손이 잡는 윗턱을 "발 기준으로 진행도만큼 하강"시켜 화면상 고정된 것처럼 보이게 →
//   몸(발)이 손 쪽으로 끌려 올라오는 grab & pull. 마지막엔 손을 놓고 옆모습으로 기립.
let climbN = 12
let climbDir = A + "/climb"
try? fm.removeItem(atPath: climbDir)   // 이전 프레임 잔재 제거
mkdir(climbDir)
let edgeBase: CGFloat = 44     // 손이 잡는 윗턱이 화면상 고정돼 보이도록 (발 기준 하강량)
for i in 0..<climbN {
    let p = CGFloat(i) / CGFloat(climbN - 1)
    // 기립 전환: p>0.72부터 손을 놓고 편한 옆모습 기립으로 블렌드
    let stand = max(0, (p - 0.72) / 0.28)          // 0 → 1
    let grabW = 1 - stand
    // 손: 벽(+x) 위쪽 윗턱을 잡음. edgeY는 진행할수록 발 기준으로 내려와 화면상 고정된 듯.
    let edgeY = 2 + (1 - p) * edgeBase
    let handX: CGFloat = 8                          // 벽 앞쪽(+x)에서 잡음
    let (gaR, gaRB) = ik2( 5, 39, handX,     edgeY, 11, 9, -1)   // 팔꿈치를 몸통 쪽으로 접어 겹치게
    let (gaL, gaLB) = ik2(-5, 39, handX - 3, edgeY, 11, 9, -1)   // (dir=-1: 앞으로 안 튀어나옴)
    // 기립 팔(편한 옆모습: 앞뒤로 살짝)
    let saR: CGFloat = 0.12, saRB: CGFloat = -0.25
    let saL: CGFloat = -0.12, saLB: CGFloat = 0.25
    let aR = gaR * grabW + saR * stand,  aRB = gaRB * grabW + saRB * stand
    let aL = gaL * grabW + saL * stand,  aLB = gaLB * grabW + saLB * stand
    // 다리: 벽(+x)을 딛고 무릎을 끌어올렸다가(중간) 정상에 곧게 선다(기립).
    let tuck = max(0, sin(p * pi)) * grabW          // 중간에 무릎/발 끌어올림, 기립 땐 0
    let footX: CGFloat = 3 + tuck * 3               // 벽쪽(+x)으로 딛음
    let footYL = 2 + tuck * 13                      // 앞발 먼저 크게 끌어올림
    let footYR = 2 + tuck * 6                       // 뒷발은 덜
    let (lL, lLB) = ik2(-3, 24, footX, footYL, 12, 10,  1)   // 무릎 앞(+x/벽)으로 굽힘
    let (lR, lRB) = ik2( 3, 24, footX, footYR, 12, 10,  1)
    let tilt = -0.12 * grabW                        // 벽쪽으로 살짝 기대 매달림(기립 땐 수직)
    let rep = makeFrame { ctx in
        drawWaabi(ctx, legL: lL, legR: lR, armL: aL, armR: aR, ant: 0.05,
                  bob: 0, tilt: tilt,
                  legLB: lLB, legRB: lRB, armLB: aLB, armRB: aRB,
                  headBob: (1 - p) * 1.2, profile: true)
    }
    save(rep, to: String(format: "%@/climb/climb_%02d.png", A, i))
}

// held 3프레임 (잡혀 매달림)
mkdir(A + "/held")
let heldParams: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (-2.5, 2.5, 0.15, -0.05, 0.15),
    (-2.6, 2.45, -0.05, 0.15, -0.15),
    (-2.45, 2.55, 0.10, 0.05, 0.05),
]
for (i, p) in heldParams.enumerated() {
    let rep = makeFrame { ctx in
        drawWaabi(ctx, legL: p.2, legR: p.3, armL: p.0, armR: p.1, ant: p.4, bob: 0, tilt: 0,
                  legLB: 0.35, legRB: 0.30,            // 다리 늘어뜨려 무릎 굽힘
                  armLB: 0.55, armRB: -0.55)           // 매달린 팔 팔꿈치 굽힘
    }
    save(rep, to: String(format: "%@/held/held_%02d.png", A, i))
}

// fall 3프레임 (떨어지며 버둥)
mkdir(A + "/fall")
let fallParams: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (-2.0, 2.0, -0.5, 0.5, 0.3),
    (-2.2, 1.8, -0.4, 0.6, -0.3),
    (-1.8, 2.2, -0.6, 0.4, 0.1),
]
for (i, p) in fallParams.enumerated() {
    let rep = makeFrame { ctx in
        drawWaabi(ctx, legL: p.2, legR: p.3, armL: p.0, armR: p.1, ant: p.4, bob: 0, tilt: 0,
                  legLB: 0.5 - CGFloat(i) * 0.2, legRB: -0.4 + CGFloat(i) * 0.2,   // 버둥대는 다리
                  armLB: 0.7, armRB: -0.7)                                          // 허우적 팔
    }
    save(rep, to: String(format: "%@/fall/fall_%02d.png", A, i))
}

// ===== 댄스 =====
for n in 2...8 { try? fm.removeItem(atPath: A + "/dance\(n)") }   // 옛 댄스 정리 (dance1만 유지)

func emitDance(_ folder: String, _ n: Int,
               _ p: (CGFloat) -> (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)) {
    mkdir(A + "/" + folder)
    for i in 0..<n {
        let t = 2 * pi * CGFloat(i) / CGFloat(n)
        let v = p(t)
        // 팔꿈치는 들린 정도에 비례해 굽히고, 무릎은 바운스에 따라 굽혀 생동감
        let armBend = 0.30 + 0.20 * abs(sin(t * 2))
        let kneeBend = 0.14 + v.5 * 0.05
        let rep = makeFrame { ctx in
            drawWaabi(ctx, legL: v.0, legR: v.1, armL: v.2, armR: v.3, ant: v.4, bob: v.5, tilt: v.6,
                      legLB: kneeBend, legRB: kneeBend, armLB: armBend, armRB: -armBend)
        }
        save(rep, to: String(format: "%@/%@/%@_%02d.png", A, folder, folder, i))
    }
}
let dN = 12
// dance1: 기존 아이돌풍 (사선 펀치)
emitDance("dance1", dN) { t in
    (abs(sin(t * 2)) * 0.15, abs(sin(t * 2)) * 0.15,
     -1.35 + sin(t) * 1.05, 1.35 + sin(t) * 1.05,
     sin(t) * 0.1, abs(sin(t * 2)) * 3, sin(t) * 0.1)
}

// dance2: 마이클잭슨 골반 튕기기 — 옆모습. 발은 바닥에 고정, 골반을 앞으로 깊게 튕김.
//   모자(페도라)를 앞으로 깊게 눌러써서 눈이 안 보임. 한 손은 모자 챙.
let d2N = 12
mkdir(A + "/dance2")
let d2FloorD: CGFloat = 3                     // 발이 닿는 캔버스 바닥
// 발끝이 캔버스 footCX(고정)·바닥에 닿도록 IK (몸을 ox/bob/tilt로 움직여도 발은 안 뜸)
func d2Foot(_ jx: CGFloat, _ jy: CGFloat, _ footCX: CGFloat,
            _ ox: CGFloat, _ bob: CGFloat, _ tilt: CGFloat, _ dir: CGFloat) -> (CGFloat, CGFloat) {
    let vx = (footCX - GX - ox) / S - 24
    let vy = (d2FloorD - GY) / S - (2 + bob)
    let ct = cos(-tilt), st = sin(-tilt)
    return ik2(jx, jy, vx * ct - vy * st, vx * st + vy * ct, 12, 10, dir)
}
for i in 0..<d2N {
    let t = 2 * pi * CGFloat(i) / CGFloat(d2N)
    let snap = pow(max(0, sin(2 * t)), 0.55)   // 루프당 2번, 날카롭게
    let bob: CGFloat = -5                        // 무릎 굽힌 스탠스(낮춤)
    let ox = snap * 11                           // 골반을 앞(오른쪽)으로 깊게
    let tilt = snap * 0.13                       // 상체는 살짝 뒤로(카운터)
    let lf = d2Foot(-3, 24, 45, ox, bob, tilt,  1)   // 뒷발 고정
    let rf = d2Foot( 3, 24, 53, ox, bob, tilt,  1)   // 앞발 고정
    let (aR, aRB) = ik2(5, 39, 5, 52, 11, 9, 1)      // 오른손: 모자 챙
    let aL: CGFloat = -0.30 - snap * 0.2             // 왼팔: 뒤로 살짝
    let aLB: CGFloat = 0.6
    let rep = makeFrame { ctx in
        drawWaabi(ctx, legL: lf.0, legR: rf.0, armL: aL, armR: aR,
                  ant: 0.05, bob: bob, tilt: tilt,
                  legLB: lf.1, legRB: rf.1, armLB: aLB, armRB: aRB,
                  profile: true, hat: true, hatTilt: -0.6)
    }
    save(rep, to: String(format: "%@/dance2/dance2_%02d.png", A, i))
}

// dance3: 좋밥춤/게다리춤 — 노란 나루토 머리.
//   발은 가운데로 모으고, 무릎을 바깥으로 벌렸다(마름모) 오므렸다를 빠르게 반복 + 살짝 바운스.
let d3N = 12
mkdir(A + "/dance3")
for i in 0..<d3N {
    let t = 2 * pi * CGFloat(i) / CGFloat(d3N)
    let open = (1 - cos(4 * t)) / 2           // 0(오므림)→1(마름모)→0 : 루프당 4번 교차
    let bob = -1 - open * 7                    // 벌릴 때 살짝 앉으며 무릎이 바깥으로(마름모)
    let footY = 2 - bob
    // 발은 중앙 가까이 모으고(±2) 무릎만 바깥으로 굽힘
    let (lL, lLB) = ik2(-3, 24, -2, footY, 12, 10, -1)   // 왼무릎 바깥(왼쪽)
    let (lR, lRB) = ik2( 3, 24,  2, footY, 12, 10,  1)   // 오른무릎 바깥(오른쪽)
    // 팔: 팔꿈치 굽혀 가슴 앞에서 리듬에 맞춰 가볍게
    let aL: CGFloat = -0.55, aLB: CGFloat = 1.3 - open * 0.3
    let aR: CGFloat =  0.55, aRB: CGFloat = -(1.3 - open * 0.3)
    let rep = makeFrame { ctx in
        drawWaabi(ctx, legL: lL, legR: lR, armL: aL, armR: aR,
                  ant: 0.05, bob: bob, tilt: 0,
                  legLB: lLB, legRB: lRB, armLB: aLB, armRB: aRB,
                  hair: true)
    }
    save(rep, to: String(format: "%@/dance3/dance3_%02d.png", A, i))
}

print("와비 생성 완료: \(walkN) walk + idle3종(\(idle1N)/\(idle2N)/\(idle3N)) + \(climbN) climb + held/fall(3) + dance1~3 @\(W)x\(H) -> \(A)")
