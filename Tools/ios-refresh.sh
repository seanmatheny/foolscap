#!/bin/zsh
# Rebuilds and reinstalls the iPhone app before its free-team signature expires.
#
# A free Apple ID signs an app for seven days. This script, run by the LaunchAgent in
# Tools/com.seanmatheny.foolscap.ios-refresh.plist every six hours, does nothing while
# the installed app's provisioning profile has more than two days left, then builds `main`
# in a clean worktree and installs it over Wi-Fi with devicectl. The phone must be paired
# with "Connect via network" and on the same network; until it is, the script logs that
# and tries again next time.
#
# The clock that matters is the profile's ExpirationDate, not the install date: Xcode
# reuses a cached team profile while it is still valid, so on 2026-11-21 an install made
# 87 minutes before its profile ran out stopped opening ("no longer available") the same
# evening while the stamp said it was fresh. So before building, cached profiles for the
# app with under six days left are deleted (Xcode fetches a new one), the built app's
# embedded profile must have six days, and the stamp holds that profile's expiry.
#
#   Tools/ios-refresh.sh          honour the stamp
#   Tools/ios-refresh.sh --now    refresh regardless of the stamp
#
# Log: ~/Library/Logs/foolscap-ios-refresh.log. Notifications on success and failure.
set -euo pipefail

REPO="${FOOLSCAP_REPO:-$HOME/git/foolscap}"
UDID="${FOOLSCAP_IOS_UDID:-00008140-000D05C63643401C}"
BRANCH="${FOOLSCAP_IOS_BRANCH:-main}"
BUNDLE_ID="com.seanmatheny.foolscap.ios"
REFRESH_LEFT_DAYS=2   # refresh once the installed profile has less than this left
WARN_LEFT_DAYS=1      # nag about the phone being away below this
NEED_LEFT_DAYS=6      # a fresh build's profile must have at least this
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

# Expiry of a .mobileprovision as epoch seconds (empty if unreadable).
profile_expiry() {
    local raw
    raw="$(security cms -D -i "$1" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null)" || return 0
    TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$raw" +%s 2>/dev/null || true
}
profile_app() {
    security cms -D -i "$1" 2>/dev/null | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || true
}
now=$(date +%s)
day=86400

# Fresh enough? The stamp holds the installed profile's expiry (epoch seconds); an
# empty or older stamp counts as stale.
expires="$(cat "$STAMP" 2>/dev/null || true)"
[[ "$expires" == <-> ]] || expires=0
left=$(( expires - now ))
if [ "${1:-}" != "--now" ] && [ $left -gt $(( REFRESH_LEFT_DAYS * day )) ]; then
    exit 0
fi

# The phone has to be on the network: devicectl lists a reachable device as connected.
if ! xcrun devicectl list devices 2>/dev/null | grep -F -- "$UDID" | grep -Eq 'connected|available'; then
    log "phone $UDID not reachable; will try again"
    if [ $left -lt $(( WARN_LEFT_DAYS * day )) ]; then
        notify "Foolscap on the iPhone expires soon" "Bring the phone onto this Mac's Wi-Fi so it can be re-signed."
    fi
    exit 2
fi

# Make Xcode fetch a new profile rather than reuse one about to run out.
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    for p in "$dir"/*.mobileprovision(N); do
        [[ "$(profile_app "$p")" == *".$BUNDLE_ID" ]] || continue
        e="$(profile_expiry "$p")"
        if [ -z "$e" ] || [ $(( e - now )) -lt $(( NEED_LEFT_DAYS * day )) ]; then
            log "removing cached profile $(basename "$p") (expires $(date -r "${e:-0}" '+%Y-%m-%d %H:%M'))"
            rm -f "$p"
        fi
    done
done

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

make -C "$WORKTREE" ios IOS_DERIVED="$DERIVED"

app="$DERIVED/Build/Products/Release-iphoneos/Foolscap.app"
expires="$(profile_expiry "$app/embedded.mobileprovision")"
[ -n "$expires" ] || fail "could not read the built app's provisioning profile"
if [ $(( expires - $(date +%s) )) -lt $(( NEED_LEFT_DAYS * day )) ]; then
    fail "Xcode signed with a profile expiring $(date -r "$expires" '+%Y-%m-%d %H:%M'); not installing"
fi

make -C "$WORKTREE" ios-install IOS_UDID="$UDID" IOS_DERIVED="$DERIVED"

print -r -- "$expires" > "$STAMP"
until="$(date -r "$expires" '+%a %-d %b %H:%M')"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WORKTREE/Sources/FoolscapApp/Info.plist")"
build="$(git -C "$WORKTREE" rev-list --count HEAD)"
log "installed $version ($build), signed until $until"
notify "Foolscap iPhone refreshed" "Version $version ($build) installed, signed until $until."
cleanup
