#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
master="$repo_root/Design/Brand/NettworkIconMaster.png"
icon_dir="$repo_root/NettworkApp/Resources/Assets.xcassets/AppIcon.appiconset"
mark_dir="$repo_root/NettworkApp/Resources/Assets.xcassets/NettworkMark.imageset"

command -v sips >/dev/null 2>&1 || {
    echo "sips is required to generate Apple icon renditions" >&2
    exit 1
}

test -f "$master" || {
    echo "Missing icon master: $master" >&2
    exit 1
}

mkdir -p "$icon_dir" "$mark_dir"

render() {
    local output="$1"
    local pixels="$2"
    sips -z "$pixels" "$pixels" "$master" --out "$output" >/dev/null
}

while IFS=' ' read -r filename pixels; do
    render "$icon_dir/$filename" "$pixels"
done <<'SIZES'
iphone-20@2x.png 40
iphone-20@3x.png 60
iphone-29@2x.png 58
iphone-29@3x.png 87
iphone-40@2x.png 80
iphone-40@3x.png 120
iphone-60@2x.png 120
iphone-60@3x.png 180
ipad-20@1x.png 20
ipad-20@2x.png 40
ipad-29@1x.png 29
ipad-29@2x.png 58
ipad-40@1x.png 40
ipad-40@2x.png 80
ipad-76@1x.png 76
ipad-76@2x.png 152
ipad-83.5@2x.png 167
mac-16@1x.png 16
mac-16@2x.png 32
mac-32@1x.png 32
mac-32@2x.png 64
mac-128@1x.png 128
mac-128@2x.png 256
mac-256@1x.png 256
mac-256@2x.png 512
mac-512@1x.png 512
mac-512@2x.png 1024
app-store-1024.png 1024
SIZES

render "$mark_dir/mark@1x.png" 256
render "$mark_dir/mark@2x.png" 512
render "$mark_dir/mark@3x.png" 768

echo "Generated Nettwork app icon and mark renditions."
