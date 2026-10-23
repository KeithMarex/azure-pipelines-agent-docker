#!/usr/bin/env bash
# Looks up an Azure Pipelines agent release on GitHub and prints, as KEY=VALUE lines
# (for $GITHUB_OUTPUT or docker build --build-arg):
#   version       agent version, e.g. 5.281.0
#   prerelease    true while Microsoft is still rolling the release out
#   latest        true when this is the newest stable release (gets the "latest" image tag)
#   sha256_amd64  checksum of vsts-agent-linux-x64-<version>.tar.gz
#   sha256_arm64  checksum of vsts-agent-linux-arm64-<version>.tar.gz
#
# Usage: scripts/resolve-agent.sh [version]   (default: the latest stable release)
# Set GH_TOKEN to avoid GitHub's anonymous API rate limit.
set -euo pipefail

api=https://api.github.com/repos/microsoft/azure-pipelines-agent/releases
version_re='^[0-9]+\.[0-9]+\.[0-9]+$'

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

fetch() {
  local auth=()
  [[ -n "${GH_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GH_TOKEN")
  curl -fsSL "${auth[@]}" -H 'Accept: application/vnd.github+json' "$1" || die "GitHub API request failed: $1"
}

requested="${1:-}"
requested="${requested#v}"
[[ -z "$requested" || "$requested" =~ $version_re ]] || die "'$requested' is not a version like 5.281.0"

latest_stable="$(fetch "$api/latest" | jq -r '.tag_name | ltrimstr("v")')"
[[ "$latest_stable" =~ $version_re ]] || die "unexpected latest release tag '$latest_stable'"

version="${requested:-$latest_stable}"
release="$(fetch "$api/tags/v$version")"
prerelease="$(jq -r '.prerelease' <<<"$release")"
body="$(jq -r '.body' <<<"$release")"

# The release notes list every package as: | Linux x64 | [<file>](<url>) | <sha256> |
checksum() {
  local file="vsts-agent-linux-$1-$version.tar.gz" sha
  sha="$(grep -F "[$file]" <<<"$body" | grep -oE '\b[0-9a-f]{64}\b' | head -n1 || true)"
  [[ -n "$sha" ]] || die "no SHA-256 for $file in the v$version release notes"
  printf '%s' "$sha"
}
sha256_amd64="$(checksum x64)"
sha256_arm64="$(checksum arm64)"

cat <<EOF
version=$version
prerelease=$prerelease
latest=$([[ "$version" == "$latest_stable" ]] && echo true || echo false)
sha256_amd64=$sha256_amd64
sha256_arm64=$sha256_arm64
EOF
