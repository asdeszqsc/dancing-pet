import Cocoa

// Dock 창의 실제 화면 좌표를 CGWindowList로 읽을 수 있는지 실측
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly)
let info = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
print("총 onscreen 창: \(info.count)")
for w in info {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    guard owner == "Dock" else { continue }
    let name = w[kCGWindowName as String] as? String ?? "(name 없음/권한필요)"
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    print("Dock 창: name='\(name)' layer=\(layer) bounds X=\(b["X"] ?? -1) Y=\(b["Y"] ?? -1) W=\(b["Width"] ?? -1) H=\(b["Height"] ?? -1)")
}
if let s = NSScreen.screens.first {
    print("primary frame=\(s.frame)")
    print("primary visibleFrame=\(s.visibleFrame)")
}
