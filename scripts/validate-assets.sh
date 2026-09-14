#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
catalog="$repo_root/NettworkApp/Resources/Assets.xcassets"
app_icon="$catalog/AppIcon.appiconset/Contents.json"
master="$repo_root/Design/Brand/NettworkIconMaster.png"

for tool in jq plutil ruby sips; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "$tool is required to validate assets" >&2
        exit 1
    }
done

test -d "$catalog" || {
    echo "Missing asset catalog: $catalog" >&2
    exit 1
}

while IFS= read -r metadata; do
    jq -e . "$metadata" >/dev/null
    base_dir="$(dirname "$metadata")"
    while IFS= read -r filename; do
        test -f "$base_dir/$filename" || {
            echo "Missing referenced asset: $base_dir/$filename" >&2
            exit 1
        }
    done < <(jq -r '.. | objects | .filename? // empty' "$metadata")
done < <(find "$catalog" -name Contents.json -type f | sort)

test "$(jq '.images | length' "$app_icon")" -eq 28 || {
    echo "AppIcon must declare 28 platform renditions" >&2
    exit 1
}

while IFS=$'\t' read -r filename expected_pixels; do
    image="$catalog/AppIcon.appiconset/$filename"
    width="$(sips -g pixelWidth "$image" | awk '/pixelWidth/ {print $2}')"
    height="$(sips -g pixelHeight "$image" | awk '/pixelHeight/ {print $2}')"
    alpha="$(sips -g hasAlpha "$image" | awk '/hasAlpha/ {print $2}')"
    if test "$width" != "$expected_pixels" || test "$height" != "$expected_pixels"; then
        echo "$filename must be ${expected_pixels}x${expected_pixels}, got ${width}x${height}" >&2
        exit 1
    fi
    test "$alpha" = "no" || {
        echo "$filename must be opaque" >&2
        exit 1
    }
done < <(
    jq -r '.images[] | [
        .filename,
        (((.size | split("x")[0] | tonumber) * (.scale | sub("x$"; "") | tonumber)) | round | tostring)
    ] | @tsv' "$app_icon"
)

while IFS=$'\t' read -r filename expected_pixels; do
    image="$catalog/NettworkMark.imageset/$filename"
    width="$(sips -g pixelWidth "$image" | awk '/pixelWidth/ {print $2}')"
    height="$(sips -g pixelHeight "$image" | awk '/pixelHeight/ {print $2}')"
    if test "$width" != "$expected_pixels" || test "$height" != "$expected_pixels"; then
        echo "$filename must be ${expected_pixels}x${expected_pixels}, got ${width}x${height}" >&2
        exit 1
    fi
done <<'MARK_SIZES'
mark@1x.png	256
mark@2x.png	512
mark@3x.png	768
MARK_SIZES

master_width="$(sips -g pixelWidth "$master" | awk '/pixelWidth/ {print $2}')"
master_height="$(sips -g pixelHeight "$master" | awk '/pixelHeight/ {print $2}')"
master_alpha="$(sips -g hasAlpha "$master" | awk '/hasAlpha/ {print $2}')"
test "$master_width" = "1024" && test "$master_height" = "1024" && test "$master_alpha" = "no" || {
    echo "NettworkIconMaster.png must be an opaque 1024x1024 PNG" >&2
    exit 1
}

for colorset in "$catalog"/*.colorset/Contents.json; do
    test "$(jq '.colors | length' "$colorset")" -eq 2 || {
        echo "$colorset must contain light and dark colors" >&2
        exit 1
    }
done

for required_color in AccentColor BrandNavy BrandTeal LaunchBackground Surface StatusReady StatusPending StatusOffline StatusConflict StatusReserved; do
    test -f "$catalog/$required_color.colorset/Contents.json" || {
        echo "Missing required color asset: $required_color" >&2
        exit 1
    }
done

launch_color="$(plutil -extract UILaunchScreen.UIColorName raw -o - "$repo_root/NettworkApp/Resources/Info.plist")"
test "$launch_color" = "LaunchBackground" || {
    echo "UILaunchScreen must use LaunchBackground" >&2
    exit 1
}

ruby -ryaml -e '
    spec = YAML.load_file(ARGV.fetch(0))
    %w[Nettwork NettworkMac].each do |name|
      settings = spec.dig("targets", name, "settings", "base") || {}
      abort "#{name} must use AppIcon" unless settings["ASSETCATALOG_COMPILER_APPICON_NAME"] == "AppIcon"
      abort "#{name} must use AccentColor" unless settings["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] == "AccentColor"
    end
' "$repo_root/project.yml"

echo "Validated Nettwork asset catalog metadata and image dimensions."
