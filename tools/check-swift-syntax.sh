#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
    printf 'Usage: %s [swiftc-path]\n' "$0" >&2
    exit 2
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"
cd "$repository_root"

swiftc_path="${1:-swiftc}"
if ! command -v "$swiftc_path" >/dev/null 2>&1; then
    printf 'Swift compiler not found: %s\n' "$swiftc_path" >&2
    exit 127
fi

source_list="$(mktemp "${repository_root}/.postie-swift-sources.XXXXXX")"
trap 'rm "$source_list"' EXIT
git ls-files --cached --others --exclude-standard -z -- Sources Tests Package.swift > "$source_list"

source_count=0
parse_failed=0
while IFS= read -r -d '' source_path; do
    case "$source_path" in
        *.swift)
            [[ -f "$source_path" ]] || continue
            source_count=$((source_count + 1))
            if ! "$swiftc_path" -frontend -parse "$source_path"; then
                parse_failed=1
            fi
            ;;
    esac
done < "$source_list"

if (( source_count == 0 )); then
    printf 'No Swift files found to parse.\n' >&2
    exit 1
fi

exit "$parse_failed"
