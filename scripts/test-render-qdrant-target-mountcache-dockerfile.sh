#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
renderer="$repo_root/scripts/render-qdrant-target-mountcache-dockerfile.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/qdrant-target-mountcache.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

rendered="$test_root/Dockerfile"
"$renderer" "$rendered"

[[ "$(grep -Fc 'FROM chef AS dependency-builder' "$rendered")" -eq 1 ]]
[[ "$(grep -Fc 'FROM dependency-builder AS builder' "$rendered")" -eq 1 ]]
[[ "$(grep -Fc 'mv /qdrant/target /qdrant/target-dependency-seed' "$rendered")" -eq 1 ]]
[[ "$(grep -Fc 'id=qdrant-cargo-target' "$rendered")" -eq 1 ]]
[[ "$(grep -Fc 'sharing=locked,target=/qdrant/target' "$rendered")" -eq 1 ]]
[[ "$(grep -Fc 'cp -a /qdrant/target-dependency-seed/. /qdrant/target/' "$rendered")" -eq 1 ]]
if grep -Fq 'from=dependency-builder' "$rendered"; then
  echo "Rendered cache mount must be empty before the offloader hydrates it." >&2
  exit 1
fi
[[ "$(grep -Ec 'xx-cargo chef cook .*--recipe-path recipe.json$' "$rendered")" -eq 1 ]]
[[ "$(grep -Ec 'xx-cargo build .*--bin qdrant' "$rendered")" -eq 1 ]]

unsupported_source="$test_root/unsupported.Dockerfile"
sed 's/FROM chef AS builder/FROM chef AS compile/' "$repo_root/upstream/Dockerfile" > "$unsupported_source"
if QDRANT_SOURCE_DOCKERFILE="$unsupported_source" "$renderer" "$test_root/unsupported-rendered.Dockerfile" >/dev/null 2>&1; then
  echo "Expected an unsupported upstream Dockerfile to fail closed." >&2
  exit 1
fi

echo "Qdrant target mountcache Dockerfile rendering is valid."
