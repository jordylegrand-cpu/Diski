#!/bin/bash
# Creates a realistic folder to screenshot Diski with on CI.
# It lives outside ~/Desktop so no privacy prompt blocks the listing.
set -u
D="${1:-$HOME/Showcase}"
rm -rf "$D"
mkdir -p "$D"
cd "$D" || exit 1

mkdir -p "6aaad54bb2b1e1dde7d2ff9c_OLDERNEW" "Award Icons" "BL BETA LAB/Builds" "ChatGPT Icons" "Design" \
         "Documents/gdpr-data" "Media" "Misc/p2qkn5l7k2bp0mc0" "Projects/Diski/Sources" "Projects/Website"

# Fonts
for f in /System/Library/Fonts/Supplemental/Arial.ttf /System/Library/Fonts/Supplemental/Georgia.ttf \
         /System/Library/Fonts/Supplemental/Verdana.ttf; do
  [ -f "$f" ] && cp "$f" "6aaad54bb2b1e1dde7d2ff9c_OLDERNEW/OlderNew-$(basename "$f")"
done

# App icons rendered as PNG
i=0
for app in Calculator Chess "Photo Booth" Stickies "TextEdit" "Preview"; do
  icns="/System/Applications/$app.app/Contents/Resources/AppIcon.icns"
  [ -f "$icns" ] || icns=$(ls "/System/Applications/$app.app/Contents/Resources/"*.icns 2>/dev/null | head -1)
  [ -n "$icns" ] && [ -f "$icns" ] && sips -s format png -Z 512 "$icns" --out "Award Icons/$app.png" >/dev/null 2>&1
  i=$((i+1))
done
cp "Award Icons/"*.png "ChatGPT Icons/" 2>/dev/null

# Wallpapers as photos
n=0
find "/System/Library/Desktop Pictures" -maxdepth 2 \( -name "*.heic" -o -name "*.jpg" -o -name "*.png" \) 2>/dev/null | head -8 |
while IFS= read -r pic; do
  n=$((n+1))
  name=$(basename "$pic")
  sips -s format jpeg -Z 1600 "$pic" --out "Design/${name%.*}.jpg" >/dev/null 2>&1
done
first=$(ls Design/*.jpg 2>/dev/null | head -1)
if [ -n "$first" ]; then
  cp "$first" "Hill and Houses, Cape Elizabeth, Maine – Edward Hopper – 1927.jpg"
  sips -Z 900 "$first" --out "Misc/p2qkn5l7k2bp0mc0/double.png" -s format png >/dev/null 2>&1
  sips -Z 300 "$first" --out "Misc/p2qkn5l7k2bp0mc0/normal.png" -s format png >/dev/null 2>&1
  sips -Z 1400 "$first" --out "Misc/p2qkn5l7k2bp0mc0/large.png" -s format png >/dev/null 2>&1
fi
# Screenshot-like images
screencapture -x -R0,0,640,400 "Design/Screenshot 2026-10-05 at 5.01.39 PM.png" 2>/dev/null

# Audio
say -o "/tmp/greatest.aiff" "Diski is blazing fast." 2>/dev/null && \
  afconvert -f m4af -d aac /tmp/greatest.aiff "Greatest Man Alive.m4a" >/dev/null 2>&1
say -o "/tmp/truth.aiff" "Copy files at the speed of light." 2>/dev/null && \
  afconvert -f m4af -d aac /tmp/truth.aiff "Unspeakable Truth.m4a" >/dev/null 2>&1
cp "Greatest Man Alive.m4a" "Media/Intro.m4a" 2>/dev/null

# Documents
for name in _appsflyer_ids access_token ad_identifier auth-prod-login comment_translation \
            comments-prod-comments device_data device_token emotions-live-votes episode_comment friend; do
  {
    echo "id,user,value,created_at"
    for r in $(seq 1 $((RANDOM % 40 + 3))); do echo "$r,user$r,$RANDOM,2026-07-02T17:35:00Z"; done
  } > "Documents/gdpr-data/$name.csv"
done
printf '{\n  "keybinds": ["cmd+c", "cmd+v", "cmd+shift+n"],\n  "theme": "glass"\n}\n' > "Misc/Loop Keybinds.json"
printf 'Diski release notes\n\n- Instant APFS clones\n- Parallel copies\n' > "Documents/Release Notes.txt"
textutil -convert rtf "Documents/Release Notes.txt" -output "Documents/Release Notes.rtf" >/dev/null 2>&1
textutil -convert docx "Documents/Release Notes.txt" -output "Documents/Proposal.docx" >/dev/null 2>&1
printf 'import AppKit\n\nprint("Hello, Diski")\n' > "Projects/Diski/Sources/main.swift"
printf '<!doctype html><title>Diski</title><h1>Diski</h1>\n' > "Projects/Website/index.html"
printf 'build: swift build\n' > "BL BETA LAB/Makefile"
mkfile -n 48m "BL BETA LAB/Builds/Diski-1.0.dmg" 2>/dev/null

# An app bundle
ditto /System/Applications/Calculator.app "ConvertDemo.app" 2>/dev/null
ditto /System/Applications/Chess.app "Found'er.app" 2>/dev/null

# A hidden file and a symlink
echo "secret" > .env
ln -s "Projects/Diski" "Diski Link"

# Spread modification dates like a lived-in Desktop
touch -t 202609201817 "6aaad54bb2b1e1dde7d2ff9c_OLDERNEW"
touch -t 202608180726 "Award Icons"
touch -t 202209091955 "BL BETA LAB"
touch -t 202609122157 "ChatGPT Icons"
touch -t 202608111753 "Design" "Misc"
touch -t 202609171025 "Documents"
touch -t 202608262135 "Media"
touch -t 202609100110 "Projects"
touch -t 202410031949 "Greatest Man Alive.m4a" 2>/dev/null
touch -t 202410031948 "Unspeakable Truth.m4a" 2>/dev/null
echo "Demo content in $D:"
ls -la "$D"
