#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
site_dir="$repo_root/site"

fail() {
    printf 'Demo validation failed: %s\n' "$*" >&2
    exit 1
}

command -v rg >/dev/null 2>&1 || fail "required tool 'rg' is not installed or not on PATH"

# Returns 0 on a match and 1 on no match; any rg error fails validation.
rg_matches() {
    local status=0
    rg "$@" || status=$?
    ((status < 2)) || fail "rg failed with exit $status"
    ((status == 0))
}

[[ -d "$site_dir" ]] || fail "missing site directory"

required_files=(
    "index.html"
    "styles.css"
    "mock-data.js"
    "search.js"
    "app.js"
    "assets/nettwork-icon-master.png"
)

for relative_path in "${required_files[@]}"; do
    file_path="$site_dir/$relative_path"
    [[ -s "$file_path" ]] || fail "missing or empty required file: site/$relative_path"
done

while IFS= read -r -d '' file_path; do
    relative_path="${file_path#"$site_dir"/}"
    case "$relative_path" in
        .env | .env.* | *.xcconfig | *.mobileprovision | *.p8 | *.p12 | *.pem | *.key | *.cer | *.secret)
            fail "production configuration or credential file found: site/$relative_path"
            ;;
    esac
done < <(find "$site_dir" -type f -print0)

if rg_matches -n -i --glob '!*.png' \
    '(BEGIN (RSA|EC|OPENSSH) PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]+|AKIA[[:alnum:]]{16})' \
    "$site_dir"; then
    fail "possible production secret found in site artifact"
fi

if rg_matches -n --glob '*.{html,css,js}' \
    '(?:src|href|poster|action)[[:space:]]*=[[:space:]]*"[[:space:]]*/|url\([[:space:]]*"?/' \
    "$site_dir"; then
    fail "root-absolute asset URL found; use a site-relative path"
fi

if rg_matches -n -i --glob '*.{html,css,js}' \
    'screenshot' \
    "$site_dir"; then
    fail "runtime screenshot dependency found in site artifact"
fi

if command -v node >/dev/null 2>&1; then
    while IFS= read -r -d '' script_path; do
        node --check "$script_path"
    done < <(find "$site_dir" -type f -name '*.js' -print0)
else
    printf '%s\n' "node is unavailable; skipped JavaScript parse validation"
fi

printf '%s\n' "Demo validation passed"
