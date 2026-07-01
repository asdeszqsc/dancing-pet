import Cocoa
import ApplicationServices

print("AXIsProcessTrusted = \(AXIsProcessTrusted())")

guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
    print("Dock 앱 못 찾음"); exit(0)
}
let axApp = AXUIElementCreateApplication(dockApp.processIdentifier)

func attr(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
    var ref: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, key as CFString, &ref)
    if err != .success { return nil }
    return ref
}

func dump(_ el: AXUIElement, depth: Int) {
    let role = (attr(el, kAXRoleAttribute) as? String) ?? "?"
    var pos = CGPoint.zero, size = CGSize.zero
    if let p = attr(el, kAXPositionAttribute) { AXValueGetValue((p as! AXValue), .cgPoint, &pos) }
    if let s = attr(el, kAXSizeAttribute) { AXValueGetValue((s as! AXValue), .cgSize, &size) }
    let pad = String(repeating: "  ", count: depth)
    print("\(pad)\(role) pos=(\(Int(pos.x)),\(Int(pos.y))) size=(\(Int(size.width))x\(Int(size.height)))")
    if depth < 2, let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
        for k in kids { dump(k, depth: depth + 1) }
    }
}
dump(axApp, depth: 0)
