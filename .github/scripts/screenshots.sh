#!/bin/bash
# Launches Diski in several states and captures the screen for each.
# usage: screenshots.sh <Diski.app> <output dir> <demo dir>
set -u
APP="$1"
OUT="$2"
DEMO="$3"
mkdir -p "$OUT"

shoot() {
  local name="$1"; shift
  pkill -x Diski 2>/dev/null
  sleep 0.6
  open -n -a "$APP" --stdout "$OUT/$name.log" --stderr "$OUT/$name.log" --args -DiskiCIMode YES "$@"
  sleep "${SHOT_DELAY:-6}"
  if pgrep -x Diski >/dev/null; then
    screencapture -x "$OUT/$name.png" || echo "capture failed: $name"
    sips -s format jpeg -s formatOptions 82 "$OUT/$name.png" --out "$OUT/$name.jpg" >/dev/null 2>&1 && rm -f "$OUT/$name.png"
  else
    echo "Diski is not running for $name (crashed?)"
  fi
  pkill -x Diski 2>/dev/null
  sleep 0.4
}

shoot list     -DiskiCIPath "$DEMO" -DiskiCIViewMode 1 -DiskiCISelect "6aaad54bb2b1e1dde7d2ff9c_OLDERNEW" -DiskiCIExpand "Misc"
shoot columns  -DiskiCIPath "$DEMO/Misc/p2qkn5l7k2bp0mc0" -DiskiCIViewMode 2
shoot gallery  -DiskiCIPath "$DEMO/Design" -DiskiCIViewMode 3
shoot icons    -DiskiCIPath "$DEMO" -DiskiCIViewMode 0
shoot dark     -DiskiCIPath "$DEMO" -DiskiCIViewMode 1 -DiskiCIAppearance dark -DiskiCISelect "Design"
shoot dual     -DiskiCIPath "$DEMO" -DiskiCIViewMode 1 -DiskiCIDualPane YES
shoot search   -DiskiCIPath "$DEMO" -DiskiCIViewMode 1 -DiskiCISearch "an"

# Crash reports, if any
for report in "$HOME"/Library/Logs/DiagnosticReports/Diski*; do
  [ -f "$report" ] || continue
  echo "==== crash report: $report"
  head -c 6000 "$report"
  cp "$report" "$OUT/" 2>/dev/null
done
ls -la "$OUT"
