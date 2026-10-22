#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
    printf 'Usage: %s <base-sha> <head-sha>\n' "$0" >&2
    exit 2
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"
cd "$repository_root"

base_sha="$1"
head_sha="$2"
if [[ ! "$base_sha" =~ ^[[:xdigit:]]{40}$ || ! "$head_sha" =~ ^[[:xdigit:]]{40}$ ]]; then
    printf 'Expected 40-character Git commit IDs.\n' >&2
    exit 2
fi

if ! git rev-parse --verify "${head_sha}^{commit}" >/dev/null 2>&1; then
    printf 'Head commit is unavailable: %s\n' "$head_sha" >&2
    exit 2
fi

if [[ "$base_sha" =~ ^0{40}$ ]]; then
    printf 'No prior event commit; checking whitespace from the empty tree.\n' >&2
    empty_tree="$(git hash-object -t tree --stdin < /dev/null)"
    git diff --check "$empty_tree" "$head_sha" -- .
    exit
fi

if ! git rev-parse --verify "${base_sha}^{commit}" >/dev/null 2>&1; then
    printf 'Base commit is unavailable (%s); checking whitespace from the empty tree.\n' "$base_sha" >&2
    base_sha="$(git hash-object -t tree --stdin < /dev/null)"
fi

git diff --check "$base_sha" "$head_sha" -- .
