#!/bin/sh
# Capture windows of a running app to PNG.
#   Tools/window-shot.sh [AppName] [out.png]        the frontmost window
#   Tools/window-shot.sh [AppName] [out.png] all    every window: out-1.png, out-2.png, …
APP="${1:-Foolscap}"; OUT="${2:-/tmp/${APP}-window.png}"; MODE="${3:-front}"
IDS=$(xcrun swift - "$APP" <<'SWIFT'
import CoreGraphics
let name = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == name && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String] as! Int)
}
SWIFT
)
[ -z "$IDS" ] && { echo "no window for $APP" >&2; exit 1; }
if [ "$MODE" = "all" ]; then
  n=1; for id in $IDS; do f="${OUT%.png}-$n.png"; screencapture -x -o -l "$id" "$f" && echo "$f"; n=$((n+1)); done
else
  screencapture -x -o -l "$(echo "$IDS" | head -1)" "$OUT" && echo "$OUT"
fi
