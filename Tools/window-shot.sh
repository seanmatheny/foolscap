#!/bin/sh
# Capture the frontmost window of a running app to a PNG.
#   Tools/window-shot.sh [AppName] [out.png]
APP="${1:-Foolscap}"; OUT="${2:-/tmp/${APP}-window.png}"
WID=$(xcrun swift - "$APP" <<'SWIFT'
import CoreGraphics
let name = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == name && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String] as! Int); break
}
SWIFT
)
[ -z "$WID" ] && { echo "no window for $APP" >&2; exit 1; }
screencapture -x -o -l "$WID" "$OUT" && echo "$OUT"
