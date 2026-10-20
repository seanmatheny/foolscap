#!/bin/zsh
# Rebuilds and reinstalls the iPhone app before its free-team signature expires.
#
# A free Apple ID signs an app for seven days. This script, run by the LaunchAgent in
# Tools/com.seanmatheny.foolscap.ios-refresh.plist every six hours, does nothing until
# the last refresh is five days old, then builds `main` in a clean worktree and installs
# it over Wi-Fi with devicectl. The phone must be paired with "Connect via network" and
# on the same network; until it is, the script logs that and tries again next time.
#
#   Tools/ios-refresh.sh          honour the stamp
#   Tools/ios-refresh.sh --now    refresh regardless of the stamp
#
# Log: ~/Library/Logs/foolscap-ios-refresh.log. Notifications on success and failure.
set -euo pipefail

REPO="${FOOLSCAP_REPO:-$HOME/git/foolscap}"
UDID="${FOOLSCAP_IOS_UDID:-00008140-000D05C63643401C}"
BRANCH="${FOOLSCAP_IOS_BRANCH:-main}"
MAX_AGE_DAYS=5
WARN_AGE_DAYS=6
CACHE="$HOME/Library/Caches/Foolscap"
WORKTREE="$CACHE/ios-build"
DERIVED="$CACHE/ios-derived"
STAMP="$HOME/Library/Application Support/Foolscap/ios-refresh.stamp"
LOG="$HOME/Library/Logs/foolscap-ios-refresh.log"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$(dirname "$LOG")" "$(dirname "$STAMP")" "$CACHE"
if [ -f "$LOG" ] && [ "$(stat -f %z "$LOG")" -gt 1000000 ]; then mv "$LOG" "$LOG.old"; fi
exec >>"$LOG" 2>&1

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
notify() { osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true; }

cleanup() {
    if [ -d "$WORKTREE" ]; then
        git -C "$REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || rm -rf "$WORKTREE"
    fi
}
fail() {
    log "FAILED: $1"
    notify "Foolscap iPhone refresh failed" "$1 — see ~/Library/Logs/foolscap-ios-refresh.log"
    cleanup
    exit 1
}
trap 'fail "step exited with status $?"' ERR

# Fresh enough? The stamp is touched after every successful install.
if [ "${1:-}" != "--now" ] && [ -f "$STAMP" ] && [ -n "$(find "$STAMP" -mtime -${MAX_AGE_DAYS} 2>/dev/null)" ]; then
    exit 0
fi

# The phone has to be on the network: devicectl lists a reachable device as connected.
if ! xcrun devicectl list devices 2>/dev/null | grep -F -- "$UDID" | grep -Eq 'connected|available'; then
    log "phone $UDID not reachable; will try again"
    if [ -f "$STAMP" ] && [ -z "$(find "$STAMP" -mtime -${WARN_AGE_DAYS} 2>/dev/null)" ]; then
        notify "Foolscap on the iPhone expires soon" "Bring the phone onto this Mac's Wi-Fi so it can be re-signed."
    fi
    exit 2
fi

[ -f "$REPO/Mobile/team.xcconfig" ] || fail "no Mobile/team.xcconfig (see team.xcconfig.example)"

log "refreshing from $BRANCH"
cleanup
git -C "$REPO" worktree prune
git -C "$REPO" worktree add --detach "$WORKTREE" "$BRANCH" >/dev/null
cp "$REPO/Mobile/team.xcconfig" "$WORKTREE/Mobile/team.xcconfig"
# The iconset is gitignored; reuse the checkout's rather than regenerating it.
if [ -d "$REPO/Icon/Foolscap.iconset" ]; then
    mkdir -p "$WORKTREE/Icon" && cp -R "$REPO/Icon/Foolscap.iconset" "$WORKTREE/Icon/"
fi

make -C "$WORKTREE" ios-refresh IOS_UDID="$UDID" IOS_DERIVED="$DERIVED"

touch "$STAMP"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WORKTREE/Sources/FoolscapApp/Info.plist")"
build="$(git -C "$WORKTREE" rev-list --count HEAD)"
log "installed $version ($build)"
notify "Foolscap iPhone refreshed" "Version $version ($build) installed and signed for another week."
cleanup
