#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

bash "$repo_root/scripts/validate-demo.sh"

printf '%s\n' "Static demo is ready in $repo_root/site"
