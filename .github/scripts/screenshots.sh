#!/bin/bash
# Launches Diski in several states and captures the screen for each.
# usage: screenshots.sh <Diski.app> <output dir> <demo dir>
set -u
APP="$1"
OUT="$2"
DEMO="$3"
mkdir -p "$OUT"
# Non-zero when Diski quit or crashed during a shot.
FAILED=0
# Let the Dock finish hiding, and launch once without a screenshot: the very
# first window can open while the Dock is still on screen.
sleep 3
open -n -a "$APP" --args -DiskiCIMode YES -DiskiCIPath "$DEMO" >/dev/null 2>&1
sleep 4
pkill -x Diski 2>/dev/null
sleep 0.6

shoot() {
  local name="$1"; shift
  pkill -x Diski 2>/dev/null
  sleep 0.6
  open -n -a "$APP" --stdout "$OUT/$name.log" --stderr "$OUT/$name.log" --args -DiskiCIMode YES "$@"
  sleep "${SHOT_DELAY:-6}"
  if pgrep -x Diski >/dev/null; then
    screencapture -x "$OUT/$name.png" || echo "capture failed: $name"
    sips -s format jpeg -s formatOptions 82 "$OUT/$name.png" --out "$OUT/$name.jpg" >/dev/null 2>&1 && rm -f "$OUT/$name.png"
    # Where every thread is at capture time (shows a busy or stuck main thread).
    if [ -n "${SAMPLE_SHOTS:-}" ]; then
      sample "$(pgrep -x Diski | head -1)" 1 -mayDie -file "$OUT/$name.sample.txt" >/dev/null 2>&1 || true
    fi
  else
    echo "Diski is not running for $name (crashed?)"
    FAILED=1
  fi
  pkill -x Diski 2>/dev/null
  sleep 0.4
}

shoot list     -DiskiCIPath "$DEMO" -DiskiCIViewMode 1 -DiskiCISelect "6aaad54bb2b1e1dde7d2ff9c_OLDERNEW" -DiskiCIExpand "Misc"
shoot columns  -DiskiCIPath "$DEMO/Misc" -DiskiCIViewMode 2 -DiskiCISelect "p2qkn5l7k2bp0mc0"
shoot viewoptions -DiskiCIPath "$DEMO" -DiskiCIViewMode 1 -DiskiCIViewOptions YES
shoot getinfo  -DiskiCIPath "$DEMO" -DiskiCIViewMode 1 -DiskiCISelect "Hill and Houses, Cape Elizabeth, Maine – Edward Hopper – 1927.jpg" -DiskiCIGetInfo YES
# The sidebar at each system sidebar size (System Settings › Appearance).
for size in 1 2 3; do
  shoot "sidebar-$size" -DiskiCIPath "$DEMO" -DiskiCIViewMode 1 -NSTableViewDefaultSizeMode $size
done
shoot gallery  -DiskiCIPath "$DEMO/Design" -DiskiCIViewMode 3
shoot icons    -DiskiCIPath "$DEMO" -DiskiCIViewMode 0
shoot dark     -DiskiCIPath "$DEMO" -DiskiCIViewMode 1 -DiskiCIAppearance dark -DiskiCISelect "Design"
shoot dual     -DiskiCIPath "$DEMO" -DiskiCIViewMode 1 -DiskiCIDualPane YES
shoot search   -DiskiCIPath "$DEMO" -DiskiCIViewMode 1 -DiskiCISearch "an"

# Speed demos: an instant APFS clone of a 2 GB folder, then a real copy of it
# to a RAM disk. The toast and the operations popover show the timings.
mkdir -p "$DEMO/Big Media"
dd if=/dev/zero of="$DEMO/Big Media/Raw Footage.mov" bs=1m count=1400 2>/dev/null
dd if=/dev/zero of="$DEMO/Big Media/Interview.mov" bs=1m count=600 2>/dev/null
for i in $(seq 1 400); do printf 'frame %d\n' "$i" > "$DEMO/Big Media/frame-$i.txt"; done
mkdir -p "$DEMO/Clones"
SHOT_DELAY=3.4 shoot clone -DiskiCIPath "$DEMO/Clones" -DiskiCIViewMode 1 \
  -DiskiCICopy "$DEMO/Big Media|$DEMO/Clones"
# The same copy again: the native "already exists" alert.
SHOT_DELAY=3.4 shoot conflict -DiskiCIPath "$DEMO/Clones" -DiskiCIViewMode 1 \
  -DiskiCICopy "$DEMO/Big Media|$DEMO/Clones"

DEV=$(hdiutil attach -nomount ram://6291456 2>/dev/null | awk '{print $1}')
if [ -n "$DEV" ] && diskutil erasevolume APFS "Fast Drive" "$DEV" >/dev/null 2>&1; then
  # Late enough for the copy to finish on a slow runner (the result stays in
  # the operations popover for 6 s).
  # Mid-copy: Finder's "Copy" progress window.
  SHOT_DELAY=3 shoot progress -DiskiCIPath "/Volumes/Fast Drive" -DiskiCIViewMode 1 \
    -DiskiCICopy "$DEMO/Big Media|/Volumes/Fast Drive"
  rm -rf "/Volumes/Fast Drive/Big Media"
  # Late enough for the copy to finish on a slow runner.
  SHOT_DELAY=9 shoot copy -DiskiCIPath "/Volumes/Fast Drive" -DiskiCIViewMode 1 \
    -DiskiCICopy "$DEMO/Big Media|/Volumes/Fast Drive" -DiskiCIShowOperations YES
  ls -la "/Volumes/Fast Drive" "/Volumes/Fast Drive/Big Media" 2>/dev/null | head -8
  hdiutil detach "$DEV" -force >/dev/null 2>&1
else
  echo "RAM disk unavailable"
fi

# Crash reports (.ips) fail the run; other diagnostics are kept for reference.
for report in "$HOME"/Library/Logs/DiagnosticReports/Diski*; do
  [ -f "$report" ] || continue
  echo "==== diagnostic report: $report"
  head -c 6000 "$report"
  cp "$report" "$OUT/" 2>/dev/null
  case "$report" in *.ips) FAILED=1 ;; esac
done
ls -la "$OUT"
exit $FAILED
