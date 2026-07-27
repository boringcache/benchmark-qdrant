#!/usr/bin/env bash
set -euo pipefail

version="${1:-v1.14.0}"
platform="${2:-linux-amd64}"

[[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "Invalid BoringCache CLI release tag: $version" >&2
  exit 1
}
case "$platform" in
  linux-amd64|linux-arm64) ;;
  *)
    echo "Unsupported BoringCache CLI platform: $platform" >&2
    exit 1
    ;;
esac

asset="boringcache-${platform}"
release_url="https://github.com/boringcache/cli/releases/download/${version}"
download_dir="$(mktemp -d)"
trap 'rm -rf "$download_dir"' EXIT

curl --fail --silent --show-error --location --retry 3 \
  "${release_url}/SHA256SUMS" \
  --output "${download_dir}/SHA256SUMS"
curl --fail --silent --show-error --location --retry 3 \
  "${release_url}/${asset}" \
  --output "${download_dir}/${asset}"

expected="$(awk -v asset="$asset" '$2 == asset { print $1; exit }' "${download_dir}/SHA256SUMS")"
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
  echo "SHA256SUMS does not contain an exact checksum for ${asset}" >&2
  exit 1
}
actual="$(sha256sum "${download_dir}/${asset}" | awk '{ print $1 }')"
[[ "$actual" == "$expected" ]] || {
  echo "Checksum mismatch for ${asset}" >&2
  exit 1
}

install_dir="${RUNNER_TEMP:-/tmp}/boringcache-bin"
mkdir -p "$install_dir"
install -m 0755 "${download_dir}/${asset}" "${install_dir}/boringcache"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$install_dir" >> "$GITHUB_PATH"
fi
"${install_dir}/boringcache" --version
