#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dockerfile="${QDRANT_SOURCE_DOCKERFILE:-${repo_root}/upstream/Dockerfile}"
output_dockerfile="${1:-}"

if [[ -z "$output_dockerfile" ]]; then
  echo "Usage: $0 OUTPUT_DOCKERFILE" >&2
  exit 2
fi
if [[ ! -f "$source_dockerfile" ]]; then
  echo "Qdrant source Dockerfile does not exist: ${source_dockerfile}" >&2
  exit 2
fi
if [[ "$(grep -Ec '^FROM chef AS builder$' "$source_dockerfile")" -ne 1 ]] ||
  [[ "$(grep -Ec 'xx-cargo chef cook .*--recipe-path recipe.json$' "$source_dockerfile")" -ne 1 ]] ||
  [[ "$(grep -Ec 'xx-cargo build .*--bin qdrant' "$source_dockerfile")" -ne 1 ]]; then
  echo "Unsupported Qdrant Dockerfile: expected one builder, cargo-chef cook, and qdrant build." >&2
  exit 1
fi

output_dir="$(dirname "$output_dockerfile")"
mkdir -p "$output_dir"
source_dockerfile="$(cd "$(dirname "$source_dockerfile")" && pwd)/$(basename "$source_dockerfile")"
output_dockerfile="$(cd "$output_dir" && pwd)/$(basename "$output_dockerfile")"
if [[ "$output_dockerfile" == "$source_dockerfile" ]]; then
  echo "Generated Dockerfile must not replace Qdrant's source Dockerfile." >&2
  exit 2
fi

rendered_dockerfile="$(mktemp "$(dirname "$output_dockerfile")/qdrant-target-mountcache.Dockerfile.XXXXXX")"
trap 'rm -f "$rendered_dockerfile"' EXIT

awk '
  BEGIN { dependency_stage = 0; build_mount = 0; cooked = 0 }
  /^FROM chef AS builder$/ {
    print "FROM chef AS dependency-builder"
    dependency_stage += 1
    next
  }
  /xx-cargo chef cook .*--recipe-path recipe.json$/ {
    print
    print ""
    print "# Keep cargo-chef output in an ordinary layer so the cache mount starts empty for hydration."
    print "RUN mv /qdrant/target /qdrant/target-dependency-seed"
    print ""
    print "# Benchmark option: preserve first-party Cargo state with an empty-cache fallback."
    print "FROM dependency-builder AS builder"
    cooked = 1
    next
  }
  cooked && /^RUN PKG_CONFIG=/ {
    print "RUN --mount=type=cache,id=qdrant-cargo-target,sharing=locked,target=/qdrant/target \\"
    print "    if [ -z \"$(find /qdrant/target -mindepth 1 -maxdepth 1 -print -quit)\" ]; then \\"
    print "      cp -a /qdrant/target-dependency-seed/. /qdrant/target/; \\"
    print "    fi && \\"
    sub(/^RUN /, "    ")
    print
    build_mount += 1
    cooked = 0
    next
  }
  { print }
  END {
    if (dependency_stage != 1 || build_mount != 1) {
      printf "Unsupported Qdrant Dockerfile: rendered %d dependency stages and %d target mounts.\n", dependency_stage, build_mount > "/dev/stderr"
      exit 1
    }
  }
' "$source_dockerfile" > "$rendered_dockerfile"

mv "$rendered_dockerfile" "$output_dockerfile"
