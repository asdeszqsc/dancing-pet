import Cocoa
import CoreAudio
import ApplicationServices

// MARK: - 캐릭터 정의
struct CharacterDef {
    let name: String
    let title: String
    let scale: CGFloat
    let smooth: Bool
}
let kCharacters: [CharacterDef] = [
    CharacterDef(name: "waabi", title: "와비 (Waabi)", scale: 1.1, smooth: false),
]

// MARK: - 설정
let kStripHeight: CGFloat = 320
let kWalkSpeed: CGFloat = 0.7
let kClimbSpeed: CGFloat = 1.5     // 등반 속도(낮출수록 동작이 또렷하게 보임)
let kGravity: CGFloat = 1.4        // 놓았을 때 낙하 가속
let kSquashTicks = 10              // 착지 찌그러짐 지속 프레임
let kFloorY: CGFloat = 6           // 바닥에서 발 높이
let kDockFeetInset: CGFloat = 8    // Dock 위에서 발을 살짝 박히게
let kFPS: Double = 30
let kWalkFrameEvery = 6
let kIdleFrameEvery = 6
let kDanceFrameEvery = 4           // 댄스 프레임 전환 간격
let kDanceMinTicks = 90            // 한 번 출 때 최소 3초 (30fps)
let kDanceMaxTicks = 150           // 최대 5초
let kDanceGapMin = 600             // 댄스 간 간격 최소 20초
let kDanceGapMax = 900             // 최대 30초
let kFallbackEmoji = "🐱"
let kPrefKey = "selectedCharacter"
// 개발 모드: DP_DEV=1 로 실행하면 손쉬운 사용 권한 없이 가짜 Dock(파란 띠)로 climb 확인 가능
let kDevMode = ProcessInfo.processInfo.environment["DP_DEV"] != nil

// MARK: - 스프라이트 로딩
func loadFrames(_ rel: String) -> [NSImage] {
    let fm = FileManager.default
    var bases: [String] = []
    if let rp = Bundle.main.resourcePath { bases.append(rp) }
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let exeDir = (exe as NSString).deletingLastPathComponent
    bases.append(exeDir)
    bases.append((exeDir as NSString).deletingLastPathComponent)
    bases.append(fm.currentDirectoryPath)
    for b in bases {
        let dir = (b as NSString).appendingPathComponent("assets/" + rel)
        if let files = try? fm.contentsOfDirectory(atPath: dir) {
            let pngs = files.filter { $0.lowercased().hasSuffix(".png") }.sorted()
            if !pngs.isEmpty {
                return pngs.compactMap { NSImage(contentsOfFile: (dir as NSString).appendingPathComponent($0)) }
            }
        }
    }
    return []
}

// MARK: - 창 (드래그 시 키 윈도우가 될 수 있게)
final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - 캐릭터 뷰
final class CharacterView: NSView {
    private enum Behavior { case idle, walkLeft, walkRight }
    private enum Climb { case none, up, down }

    private var walkFrames: [NSImage] = []
    private var danceList: [[NSImage]] = []   // 댄스 5종 (각각 프레임 배열)
    private var currentDance = 0
    private var idleList: [[NSImage]] = []     // idle 여러 종 (숨쉬기/푸쉬업/물마시기 …)
    private var currentIdle = 0
    private var idleTick = 0
    private var idleFrames: [NSImage] { idleList.first ?? [] }   // held 폴백용
    private var climbFrames: [NSImage] = []
    private var heldFrames: [NSImage] = []
    private var fallFrames: [NSImage] = []
    private var spriteSize = CGSize(width: 80, height: 80)
    private var smooth = false

    // 드래그/낙하
    private var grabbed = false
    private var falling = false
    private var vY: CGFloat = 0
    private var grabOffsetGlobal = CGPoint.zero   // 캐릭터 발-커서 사이 전역 좌표 오프셋
    private var squashTicks = 0                    // 착지 찌그러짐
    var isGrabbed: Bool { grabbed }

    /// 드래그가 다른 모니터로 넘어갈 때 창을 그 화면으로 옮겨달라는 요청 (전역 좌표)
    var ensureScreen: ((CGPoint) -> Void)?

    private var behavior: Behavior = .idle
    private var behaviorTicks = 0
    private var moveTick = 0
    private var danceTick = 0
    private var dancingTicksLeft = 0     // >0이면 댄스 중
    private var danceCooldown = 90       // 다음 댄스까지 남은 틱
    private var audioActive = false
    private var phase: CGFloat = 0
    private var tickCount = 0

    private var posX: CGFloat = 200
    private var direction: CGFloat = 1
    private var feetY: CGFloat = kFloorY
    private var climbing: Climb = .none

    private var dockValid = false
    private var dockLeft: CGFloat = 0
    private var dockRight: CGFloat = 0
    private var dockTopY: CGFloat = 0

    /// 화면 끝에 닿았을 때 옆 모니터로 이동 요청 (true=이동 성공). goingRight=오른쪽으로.
    var migrate: ((Bool) -> Bool)?

    private let emojiStr = kFallbackEmoji as NSString
    private let emojiAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 64)]

    private var isDancing: Bool { dancingTicksLeft > 0 }
    private var hasSprites: Bool { !walkFrames.isEmpty }

    func setCharacter(_ def: CharacterDef) {
        walkFrames = loadFrames(def.name + "/walk")
        // 댄스 5종 (dance1~dance5). 없으면 기존 dance 폴더로 폴백.
        danceList = []
        for i in 1...8 {
            let f = loadFrames(def.name + "/dance\(i)")
            if !f.isEmpty { danceList.append(f) }
        }
        if danceList.isEmpty {
            let f = loadFrames(def.name + "/dance")
            if !f.isEmpty { danceList.append(f) }
        }
        // idle 여러 종 (idle1~idle3). 없으면 기존 idle 폴더로 폴백.
        idleList = []
        for i in 1...3 {
            let f = loadFrames(def.name + "/idle\(i)")
            if !f.isEmpty { idleList.append(f) }
        }
        if idleList.isEmpty {
            let f = loadFrames(def.name + "/idle")
            if !f.isEmpty { idleList.append(f) }
        }
        currentIdle = 0; idleTick = 0
        climbFrames = loadFrames(def.name + "/climb")
        heldFrames = loadFrames(def.name + "/held")
        fallFrames = loadFrames(def.name + "/fall")
        smooth = def.smooth
        if let first = walkFrames.first {
            spriteSize = CGSize(width: first.size.width * def.scale,
                                height: first.size.height * def.scale)
        }
        tickCount = 0; moveTick = 0; danceTick = 0
        dancingTicksLeft = 0; danceCooldown = 90; currentDance = 0
        behavior = .idle; behaviorTicks = 0
        needsDisplay = true
    }

    /// Dock 위치 (현재 화면 로컬 좌표)
    func setDock(valid: Bool, left: CGFloat = 0, right: CGFloat = 0, topY: CGFloat = 0) {
        if valid {
            dockLeft = left; dockRight = right; dockTopY = topY; dockValid = true
        } else {
            dockValid = false
            if climbing == .none, feetY > kFloorY + 1 { climbing = .down }  // Dock 사라지면 내려오기
        }
    }

    func notifyAudio(active: Bool) {
        if active && !audioActive {
            // 소리가 (다시) 시작되면 바로 댄스부터 시작 → 이후 20~30초 간격
            danceCooldown = 0
        }
        audioActive = active
    }

    // MARK: 드래그
    /// 현재 스프라이트가 차지하는 영역 (마우스 히트 판정용)
    func spriteHitBox() -> CGRect {
        CGRect(x: posX - spriteSize.width / 2, y: feetY,
               width: spriteSize.width, height: spriteSize.height)
    }

    /// 그 x 위치의 지면 높이 — Dock 가로범위 안이면 Dock 윗면, 밖이면 바닥
    private func groundY(_ x: CGFloat) -> CGFloat {
        (dockValid && x >= dockLeft && x <= dockRight) ? dockTopY : kFloorY
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if spriteHitBox().contains(p), let win = window {
            grabbed = true; falling = false; vY = 0; climbing = .none
            // 캐릭터 발 전역좌표 - 커서 전역좌표
            let gCursor = CGPoint(x: win.frame.minX + p.x, y: win.frame.minY + p.y)
            let gChar = CGPoint(x: win.frame.minX + posX, y: win.frame.minY + feetY)
            grabOffsetGlobal = CGPoint(x: gChar.x - gCursor.x, y: gChar.y - gCursor.y)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard grabbed, let win = window else { return }
        let p = convert(event.locationInWindow, from: nil)
        // 현재(이동 전) 창 기준 전역 커서 좌표
        let gCursor = CGPoint(x: win.frame.minX + p.x, y: win.frame.minY + p.y)
        // 커서가 다른 모니터로 넘어갔으면 창을 그 화면으로 이동
        ensureScreen?(gCursor)
        guard let win2 = window else { return }
        // (이동 후) 새 창 기준으로 캐릭터 위치 재계산
        let gChar = CGPoint(x: gCursor.x + grabOffsetGlobal.x, y: gCursor.y + grabOffsetGlobal.y)
        posX = min(max(gChar.x - win2.frame.minX, spriteSize.width / 2), bounds.width - spriteSize.width / 2)
        feetY = min(max(gChar.y - win2.frame.minY, kFloorY), bounds.height - spriteSize.height)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard grabbed else { return }
        grabbed = false
        let landY = groundY(posX)
        if feetY > landY + 1 {
            falling = true; vY = 0                      // 공중이면 낙하 시작
        } else {
            feetY = landY
            behavior = .idle; behaviorTicks = 0
            squashTicks = kSquashTicks
        }
    }

    func tick() {
        tickCount += 1
        phase += 0.25

        // 잡혀있는 동안엔 마우스가 위치를 갱신 (다른 동작 정지)
        if grabbed { needsDisplay = true; return }

        // 놓으면 중력으로 낙하 → 지면(바닥/Dock)에 착지
        if falling {
            vY -= kGravity
            feetY += vY
            let landY = groundY(posX)
            if feetY <= landY {
                feetY = landY; falling = false; vY = 0
                behavior = .idle; behaviorTicks = 0
                squashTicks = kSquashTicks            // 착지 찌그러짐 시작
            }
            needsDisplay = true
            return
        }

        if squashTicks > 0 { squashTicks -= 1 }

        let half = spriteSize.width / 2
        let minX = half + 8
        let maxX = bounds.width - half - 8

        if climbing != .none {
            // 올라타기/내려오기 우선 (dance에 안 끊김). 목표 = 현재 x의 지면
            let target = groundY(posX)
            let dy = target - feetY
            if abs(dy) <= kClimbSpeed { feetY = target; climbing = .none }
            else { feetY += dy > 0 ? kClimbSpeed : -kClimbSpeed; moveTick += 1 }
        } else if dancingTicksLeft > 0 {
            // 댄스 중: 제자리에서 진행. 끝나면 다음 댄스까지 20~30초 대기
            dancingTicksLeft -= 1
            danceTick += 1
            if dancingTicksLeft == 0 { danceCooldown = Int.random(in: kDanceGapMin...kDanceGapMax) }
        } else {
            if audioActive, danceCooldown > 0 { danceCooldown -= 1 }   // 소리 날 때만 카운트다운
            let onGround = abs(feetY - groundY(posX)) < 1.0
            if audioActive, danceCooldown <= 0, !danceList.isEmpty, onGround {
                // 소리가 나는 중 + 간격 지남 → 랜덤 댄스 시작 (3~5초)
                currentDance = Int.random(in: 0..<danceList.count)
                dancingTicksLeft = Int.random(in: kDanceMinTicks...kDanceMaxTicks)
                danceTick = 0
            } else {
                // ===== 평소 행동 (어슬렁/idle/Dock 오르내리기) =====
                behaviorTicks -= 1
                if behaviorTicks <= 0 { pickBehavior(minX: minX, maxX: maxX) }
                switch behavior {
                case .idle:      idleTick += 1
                case .walkLeft:  direction = -1; posX -= kWalkSpeed; moveTick += 1
                case .walkRight: direction =  1; posX += kWalkSpeed; moveTick += 1
                }

                // 화면 끝: 옆 모니터로 이동 시도, 없으면 방향 전환
                if posX > maxX {
                    if behavior == .walkRight, migrate?(true) == true {
                        posX = spriteSize.width / 2 + 8                  // 새 화면 왼쪽에서 등장
                    } else { posX = maxX; pickBehavior(minX: minX, maxX: maxX) }
                } else if posX < minX {
                    if behavior == .walkLeft, migrate?(false) == true {
                        posX = bounds.width - spriteSize.width / 2 - 8   // 새 화면 오른쪽에서 등장
                    } else { posX = minX; pickBehavior(minX: minX, maxX: maxX) }
                }

                // 지면 높이가 어긋나면(Dock 가장자리/아래) 올라타기·내려오기, 아니면 지면에 맞춤
                let g = groundY(posX)
                if abs(feetY - g) > 1 {
                    climbing = (feetY < g) ? .up : .down
                    if dockValid { direction = (posX < (dockLeft + dockRight) / 2) ? 1 : -1 }  // 벽 바라보기
                } else {
                    feetY = g
                }
            }
        }

        needsDisplay = true
    }

    private func pickBehavior(minX: CGFloat, maxX: CGFloat) {
        let nearLeft  = posX <= minX + 12
        let nearRight = posX >= maxX - 12
        var choices: [Behavior] = [.idle, .idle, .idle]
        if !nearLeft  { choices += [.walkLeft, .walkLeft] }
        if !nearRight { choices += [.walkRight, .walkRight] }
        behavior = choices.randomElement() ?? .idle
        if behavior == .idle {
            // idle 종 랜덤 선택 + 동작이 정수 횟수만큼 끝까지 재생되도록 길이 맞춤
            if !idleList.isEmpty { currentIdle = Int.random(in: 0..<idleList.count) }
            idleTick = 0
            let reps = [3, 3, 2]   // idle1(숨쉬기)/idle2(푸쉬업)/idle3(물마시기) 반복
            let cyc = max(1, (idleList.indices.contains(currentIdle) ? idleList[currentIdle].count : 10) * kIdleFrameEvery)
            behaviorTicks = cyc * (currentIdle < reps.count ? reps[currentIdle] : 2)
        } else {
            behaviorTicks = Int.random(in: 70...160)
        }
    }

    private func frameOf(_ frames: [NSImage], _ counter: Int, _ every: Int) -> NSImage? {
        guard !frames.isEmpty else { return nil }
        return frames[(counter / max(every, 1)) % frames.count]
    }

    override func draw(_ dirtyRect: NSRect) {
        // 개발 모드: Dock 범위를 파란 띠로 시각화 (climb 정렬 확인용)
        if kDevMode && dockValid, let dctx = NSGraphicsContext.current?.cgContext {
            let band = CGRect(x: dockLeft, y: 0, width: dockRight - dockLeft, height: dockTopY)
            dctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.15).cgColor)
            dctx.fill(band)
            dctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.6).cgColor)
            dctx.setLineWidth(2)
            dctx.stroke(band.insetBy(dx: 1, dy: 1))
        }
        guard hasSprites else { drawEmojiFallback(baseY: feetY); return }

        var img: NSImage?
        var vy: CGFloat = 0

        if grabbed {
            img = frameOf(!heldFrames.isEmpty ? heldFrames : idleFrames, tickCount, 8)
            if img == nil { img = frameOf(walkFrames, 0, 1) }
        } else if falling {
            img = frameOf(!fallFrames.isEmpty ? fallFrames : walkFrames, tickCount, 4)
        } else if isDancing && climbing == .none {
            let frames = (currentDance >= 0 && currentDance < danceList.count) ? danceList[currentDance] : []
            img = frameOf(frames, danceTick, kDanceFrameEvery)
            vy = abs(sin(phase * 1.4)) * 3
        } else if climbing != .none {
            // 등반: 진행도(발 높이) → mantle 포즈. 손이 턱에 고정된 듯 보이게 매핑.
            if !climbFrames.isEmpty {
                let prog = min(1, max(0, (feetY - kFloorY) / max(1, dockTopY - kFloorY)))
                let idx = Int((prog * CGFloat(climbFrames.count - 1)).rounded())
                img = climbFrames[min(max(idx, 0), climbFrames.count - 1)]
            } else {
                img = frameOf(walkFrames, moveTick, kWalkFrameEvery)
            }
        } else if behavior == .idle {
            let frames = idleList.indices.contains(currentIdle) ? idleList[currentIdle] : []
            if !frames.isEmpty {
                img = frameOf(frames, idleTick, kIdleFrameEvery)
            } else {
                img = frameOf(walkFrames, 0, 1)
                vy = sin(phase * 0.8) * 1.5
            }
        } else {
            img = frameOf(walkFrames, moveTick, kWalkFrameEvery)
        }

        guard let image = img, let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 착지 찌그러짐: 발(바닥)을 기준으로 가로↑ 세로↓
        var sx: CGFloat = 1, sy: CGFloat = 1
        if squashTicks > 0 {
            let amt = CGFloat(squashTicks) / CGFloat(kSquashTicks)
            sx = 1 + 0.18 * amt
            sy = 1 - 0.22 * amt
        }

        ctx.saveGState()
        ctx.translateBy(x: posX, y: feetY + vy)
        ctx.scaleBy(x: direction * sx, y: sy)
        let rect = CGRect(x: -spriteSize.width / 2, y: 0,
                          width: spriteSize.width, height: spriteSize.height)
        let interp: NSImageInterpolation = smooth ? .high : .none
        image.draw(in: rect, from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true,
                   hints: [.interpolation: interp.rawValue])
        ctx.restoreGState()
    }

    private func drawEmojiFallback(baseY: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = emojiStr.size(withAttributes: emojiAttrs)
        let bob = isDancing ? abs(sin(phase * 1.6)) * 26 : abs(sin(phase * 1.2)) * 5
        ctx.saveGState()
        ctx.translateBy(x: posX, y: baseY + bob + size.height / 2)
        ctx.scaleBy(x: direction, y: 1)
        emojiStr.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: emojiAttrs)
        ctx.restoreGState()
    }
}

// MARK: - 오디오 모니터
final class AudioMonitor {
    func isOutputActive() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return false }

        var running: UInt32 = 0
        var rsize = UInt32(MemoryLayout<UInt32>.size)
        var raddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(deviceID, &raddr, 0, nil, &rsize, &running)
        guard status == noErr else { return false }
        return running != 0
    }
}

// MARK: - 앱 델리게이트
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var characterView: CharacterView!
    var statusItem: NSStatusItem!
    var characterItems: [NSMenuItem] = []
    let audio = AudioMonitor()
    var animTimer: Timer?
    var audioTimer: Timer?
    var dockTimer: Timer?
    var current = 0
    var screensSorted: [NSScreen] = []
    var currentIndex = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        window = PetWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: kStripHeight),
                           styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        characterView = CharacterView(frame: NSRect(x: 0, y: 0, width: 800, height: kStripHeight))
        characterView.autoresizingMask = [.width, .height]
        characterView.migrate = { [weak self] goingRight in self?.migrate(goingRight) ?? false }
        characterView.ensureScreen = { [weak self] g in
            guard let self = self else { return }
            if let idx = self.screensSorted.firstIndex(where: { NSPointInRect(g, $0.frame) }),
               idx != self.currentIndex {
                self.placeOnScreen(idx)
            }
        }
        window.contentView = characterView
        window.orderFrontRegardless()

        // 모니터 목록 + 시작 화면(주 모니터)에 배치
        screensSorted = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        currentIndex = screensSorted.firstIndex(where: { $0 == NSScreen.main }) ?? 0
        placeOnScreen(currentIndex)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        current = UserDefaults.standard.integer(forKey: kPrefKey)
        if current < 0 || current >= kCharacters.count { current = 0 }
        characterView.setCharacter(kCharacters[current])

        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / kFPS, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.characterView.tick()
            self.updateClickThrough()
        }
        audioTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.characterView.notifyAudio(active: self.audio.isOutputActive())
        }
        dockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.readDock()
        }

        setupStatusItem()

        if !kDevMode {   // dev 모드에선 권한 팝업 생략 (가짜 Dock 사용)
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        readDock()
    }

    // MARK: 모니터 배치 / 이동
    @objc private func screensChanged() {
        screensSorted = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        if currentIndex >= screensSorted.count { currentIndex = 0 }
        placeOnScreen(currentIndex)
    }

    private func placeOnScreen(_ idx: Int) {
        guard idx >= 0, idx < screensSorted.count else { return }
        currentIndex = idx
        let s = screensSorted[idx]
        // 드래그를 화면 어디든 할 수 있게 현재 모니터 전체를 덮음
        window.setFrame(s.frame, display: true)
        characterView.frame = NSRect(origin: .zero, size: s.frame.size)
        readDock()
    }

    /// 마우스가 캐릭터 위에 있을 때만 클릭을 받게(=드래그 가능), 그 외엔 클릭 통과
    private func updateClickThrough() {
        let p = NSEvent.mouseLocation
        let f = window.frame
        let vp = CGPoint(x: p.x - f.minX, y: p.y - f.minY)
        let over = characterView.spriteHitBox().contains(vp)
        window.ignoresMouseEvents = characterView.isGrabbed ? false : !over
    }

    /// 옆 모니터로 이동 (성공 시 true)
    private func migrate(_ goingRight: Bool) -> Bool {
        let target = currentIndex + (goingRight ? 1 : -1)
        guard target >= 0, target < screensSorted.count else { return false }
        placeOnScreen(target)
        return true
    }

    // MARK: Dock 감지 (접근성) — 현재 화면 로컬 좌표로
    private func axFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private func collectLists(_ el: AXUIElement, depth: Int, into: inout [AXUIElement]) {
        if depth > 3 { return }
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, role == (kAXListRole as String) {
            into.append(el)
        }
        var kidsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
           let kids = kidsRef as? [AXUIElement] {
            for k in kids { collectLists(k, depth: depth + 1, into: &into) }
        }
    }

    private func readDock() {
        if kDevMode {   // 화면 하단 중앙에 가짜 Dock 하나 고정 (권한/실제 Dock 불필요)
            let w = characterView.bounds.width
            let dockW = min(360, w * 0.4)
            let cx = w / 2
            characterView.setDock(valid: true, left: cx - dockW / 2, right: cx + dockW / 2, topY: 70)
            return
        }
        guard AXIsProcessTrusted() else { characterView.setDock(valid: false); return }
        guard let dock = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            characterView.setDock(valid: false); return
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var lists: [AXUIElement] = []
        collectLists(app, depth: 0, into: &lists)

        let primaryW = NSScreen.screens.first?.frame.width ?? 0
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        for l in lists {
            guard let r = axFrame(l) else { continue }
            if r.height < 10 || r.height > 200 { continue }
            if r.width >= primaryW * 0.99 { continue }
            if r.minY < primaryH * 0.5 { continue }
            minX = min(minX, r.minX); maxX = max(maxX, r.maxX)
        }
        guard minX <= maxX, currentIndex < screensSorted.count else {
            characterView.setDock(valid: false); return
        }
        // Dock이 "현재 캐릭터가 있는 화면"에 있을 때만 유효
        let cur = screensSorted[currentIndex]
        let centerX = (minX + maxX) / 2
        guard centerX >= cur.frame.minX, centerX <= cur.frame.maxX else {
            characterView.setDock(valid: false); return
        }
        let dockH = cur.visibleFrame.minY - cur.frame.minY
        guard dockH > 20 else { characterView.setDock(valid: false); return }
        characterView.setDock(valid: true,
                              left: minX - cur.frame.minX,
                              right: maxX - cur.frame.minX,
                              topY: dockH - kDockFeetInset)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎵"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "캐릭터 (Character)", action: nil, keyEquivalent: ""))
        for (i, def) in kCharacters.enumerated() {
            let item = NSMenuItem(title: "  " + def.title,
                                  action: #selector(selectCharacter(_:)), keyEquivalent: "")
            item.target = self; item.tag = i
            item.state = (i == current) ? .on : .off
            menu.addItem(item); characterItems.append(item)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "종료 (Quit)",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func selectCharacter(_ sender: NSMenuItem) {
        current = sender.tag
        for (i, item) in characterItems.enumerated() { item.state = (i == current) ? .on : .off }
        characterView.setCharacter(kCharacters[current])
        UserDefaults.standard.set(current, forKey: kPrefKey)
    }
}

// MARK: - 진입점
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
