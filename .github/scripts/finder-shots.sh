#!/bin/bash
# Screenshots of Finder itself on the same runner, in the same window frame
# as Diski's, so the two can be compared on identical system settings.
# usage: finder-shots.sh <output dir> <demo dir>
set -u
OUT="$1"
DEMO="$2"
mkdir -p "$OUT"

# osascript may wait forever on an automation consent prompt: give up after 20 s.
run_osascript() {
  osascript "$@" &
  local pid=$!
  for _ in $(seq 1 40); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      return $?
    fi
    sleep 0.5
  done
  kill "$pid" 2>/dev/null
  echo "osascript timed out"
  return 1
}

pkill -x Diski 2>/dev/null
defaults write com.apple.finder ShowPathbar -bool true
defaults write com.apple.finder ShowStatusBar -bool false
defaults write com.apple.finder _FXShowPosixPathInTitle -bool true
defaults write com.apple.finder FXPreferredViewStyle -string Nlsv
killall Finder 2>/dev/null
sleep 3

shoot_finder() {
  local name="$1" view="$2" select="$3"
  local selection=""
  if [ -n "$select" ]; then
    selection="select (POSIX file \"$DEMO/$select\" as alias)"
  fi
  # Diski's CI window: the screen below the menu bar, inset by 10 x 8 pt.
  if ! run_osascript -e "tell application \"Finder\"
      activate
      close every Finder window
      set w to make new Finder window to (POSIX file \"$DEMO\" as alias)
      set current view of w to $view
      set bounds of w to {10, 32, 1014, 760}
      $selection
    end tell"; then
    open "$DEMO"
  fi
  sleep 3
  screencapture -x "$OUT/$name.png" || return
  sips -s format jpeg -s formatOptions 82 "$OUT/$name.png" --out "$OUT/$name.jpg" >/dev/null 2>&1 && rm -f "$OUT/$name.png"
}

shoot_finder finder-list "list view" "6aaad54bb2b1e1dde7d2ff9c_OLDERNEW"
shoot_finder finder-columns "column view" "Misc/p2qkn5l7k2bp0mc0"
shoot_finder finder-icons "icon view" ""
killall Finder 2>/dev/null
exit 0
