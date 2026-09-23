import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let name = w[kCGWindowName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    if layer != 0 || (w[kCGWindowLayer as String] as? Int) == 0 {
        print("\(owner) '\(name)' layer=\(layer) y=\(b["Y"] ?? -1) h=\(b["Height"] ?? -1) x=\(b["X"] ?? -1) w=\(b["Width"] ?? -1)")
    }
}
// Diagnostic: lists on-screen windows (layer 0 and above), e.g. the Window Server's
// 'Menubar' window in a full-screen space.  Run:  sleep 5; xcrun swift Tools/winlist.swift
