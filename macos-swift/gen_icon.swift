import Cocoa

// 앱 아이콘 생성기 — 와비를 정면 큰 얼굴로 그린 macOS 스타일 라운드 카드 아이콘.
// 출력: icon_1024.png (이후 sips+iconutil 로 AppIcon.icns 생성)

let SZ = 1024
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}
// 스프라이트와 동일 팔레트
let SKIN    = col(0.49, 0.84, 0.56)
let SKIN_D  = col(0.30, 0.58, 0.38)
let SKIN_L  = col(0.70, 0.95, 0.74)
let OUTLINE = col(0.09, 0.15, 0.10)
let EYE     = col(0.07, 0.10, 0.08)
let WHITE   = NSColor.white.cgColor
let BLUSH   = col(1.0, 0.52, 0.66, 0.40)
// 배경 그라디언트 (초록 캐릭터가 튀도록 보색 계열 인디고→마젠타)
let BG1 = col(0.42, 0.35, 0.92)
let BG2 = col(0.83, 0.36, 0.80)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: SZ, pixelsHigh: SZ,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let nsctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = nsctx
let ctx = nsctx.cgContext
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

func fillOutlined(_ r: CGRect, _ fill: CGColor, _ lw: CGFloat) {
    ctx.setFillColor(fill); ctx.fillEllipse(in: r)
    ctx.setStrokeColor(OUTLINE); ctx.setLineWidth(lw); ctx.strokeEllipse(in: r)
}

// ---- 라운드 카드 배경 ----
let inset: CGFloat = 96
let card = CGRect(x: inset, y: inset, width: CGFloat(SZ) - 2 * inset, height: CGFloat(SZ) - 2 * inset)
let radius: CGFloat = 205
let cardPath = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: col(0, 0, 0, 0.28))
ctx.addPath(cardPath); ctx.setFillColor(BG1); ctx.fillPath()   // 그림자용 베이스
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(cardPath); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [BG1, BG2] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: card.minX, y: card.maxY),
                       end: CGPoint(x: card.maxX, y: card.minY), options: [])
// 좌상단 은은한 광
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [col(1, 1, 1, 0.22), col(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 360, y: 720), startRadius: 0,
                       endCenter: CGPoint(x: 360, y: 720), endRadius: 460, options: [])
ctx.restoreGState()

// ---- 캐릭터 그룹 (은은한 그림자) ----
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 34, color: col(0, 0, 0, 0.30))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)

let cx: CGFloat = 512
let lw: CGFloat = 16

// 더듬이 (머리 뒤에서 위로)
func antenna(_ x: CGFloat, _ dir: CGFloat) {
    let base = CGPoint(x: x, y: 640)
    let tip  = CGPoint(x: x + dir * 70, y: 830)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(OUTLINE); ctx.setLineWidth(46)
    ctx.move(to: base); ctx.addLine(to: tip); ctx.strokePath()
    ctx.setStrokeColor(SKIN_D); ctx.setLineWidth(30)
    ctx.move(to: base); ctx.addLine(to: tip); ctx.strokePath()
    fillOutlined(CGRect(x: tip.x - 46, y: tip.y - 46, width: 92, height: 92), SKIN, lw)
}
antenna(cx - 95, -1)
antenna(cx + 95,  1)

// 몸통 (머리 아래로 살짝)
fillOutlined(CGRect(x: cx - 170, y: 150, width: 340, height: 320), SKIN, lw)
// 팔 nub
fillOutlined(CGRect(x: cx - 250, y: 250, width: 120, height: 120), SKIN, lw)
fillOutlined(CGRect(x: cx + 130, y: 250, width: 120, height: 120), SKIN, lw)

// 머리
let head = CGRect(x: cx - 245, y: 250, width: 490, height: 440)
fillOutlined(head, SKIN, lw)
// 머리 하이라이트
ctx.setFillColor(SKIN_L)
ctx.fillEllipse(in: CGRect(x: cx - 175, y: 540, width: 130, height: 90))

// 볼터치
ctx.setFillColor(BLUSH)
ctx.fillEllipse(in: CGRect(x: cx - 205, y: 400, width: 95, height: 60))
ctx.fillEllipse(in: CGRect(x: cx + 110, y: 400, width: 95, height: 60))

// 눈 (흰자 + 검은 눈동자 + 캐치라이트)
func eye(_ ex: CGFloat) {
    let white = CGRect(x: ex - 92, y: 448, width: 184, height: 200)
    ctx.setFillColor(WHITE); ctx.fillEllipse(in: white)
    ctx.setStrokeColor(OUTLINE); ctx.setLineWidth(lw); ctx.strokeEllipse(in: white)
    ctx.setFillColor(EYE); ctx.fillEllipse(in: CGRect(x: ex - 52, y: 486, width: 104, height: 118))
    ctx.setFillColor(WHITE); ctx.fillEllipse(in: CGRect(x: ex + 6, y: 560, width: 34, height: 34))
}
eye(cx - 118)
eye(cx + 118)

// 입 (작은 미소)
ctx.setStrokeColor(OUTLINE); ctx.setLineWidth(16); ctx.setLineCap(.round)
ctx.beginPath()
ctx.move(to: CGPoint(x: cx - 60, y: 405))
ctx.addQuadCurve(to: CGPoint(x: cx + 60, y: 405), control: CGPoint(x: cx, y: 355))
ctx.strokePath()

ctx.endTransparencyLayer()
ctx.restoreGState()

// 저장
let out = FileManager.default.currentDirectoryPath + "/icon_1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
NSGraphicsContext.restoreGraphicsState()
print("아이콘 생성: \(out)")
