#!/usr/bin/env bash
# Smoke test that needs no Azure DevOps organisation: builds the image for the host
# architecture and checks the entrypoint's validation, the agent version and the tooling.
#
# Usage: tests/smoke.sh [version]                    (default: the latest stable agent)
#        CONTAINER_ENGINE=podman tests/smoke.sh 5.281.0
#        IMAGE=azure-pipelines-agent:smoke tests/smoke.sh 5.281.0   (test an existing image, skip the build)
set -euo pipefail

engine="${CONTAINER_ENGINE:-docker}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

resolved="$("$root/scripts/resolve-agent.sh" "${1:-}")"
declare -A agent
while IFS='=' read -r key value; do agent[$key]=$value; done <<<"$resolved"

if [[ -z "${IMAGE:-}" ]]; then
  IMAGE=azure-pipelines-agent:smoke
  echo "Building $IMAGE with agent ${agent[version]}"
  "$engine" build \
    --build-arg "AGENT_VERSION=${agent[version]}" \
    --build-arg "AGENT_SHA256_AMD64=${agent[sha256_amd64]}" \
    --build-arg "AGENT_SHA256_ARM64=${agent[sha256_arm64]}" \
    -t "$IMAGE" "$root"
fi

failures=0
check() {
  local name=$1; shift
  if "$@"; then echo "ok   - $name"; else echo "FAIL - $name"; failures=$((failures + 1)); fi
}
# Runs the image and captures combined output and exit code in $out / $code.
run() {
  code=0
  out="$("$engine" run --rm "$@" 2>&1)" || code=$?
}

echo "Testing $IMAGE"

run "$IMAGE"
check "exits 1 without AZP_URL" test "$code" -eq 1
check "reports the missing AZP_URL" grep -q "missing AZP_URL" <<<"$out"

run -e AZP_URL=https://dev.azure.com/example "$IMAGE"
check "exits 1 without a token" test "$code" -eq 1
check "reports the missing token" grep -q "missing AZP_TOKEN or AZP_TOKEN_FILE" <<<"$out"

run -e AZP_URL=https://dev.azure.com/example -e AZP_TOKEN_FILE=/run/secrets/missing "$IMAGE"
check "exits 1 with an unreadable AZP_TOKEN_FILE" test "$code" -eq 1

run -e AZP_URL=dev.azure.com/example -e AZP_TOKEN=x "$IMAGE"
check "rejects an AZP_URL without scheme" grep -q "must start with https://" <<<"$out"

run --entrypoint /azp/agent/bin/Agent.Listener "$IMAGE" --version
check "agent version is ${agent[version]}" test "$(tail -n1 <<<"$out")" = "${agent[version]}"

run --entrypoint id "$IMAGE" -un
check "runs as user 'agent'" test "$out" = agent

run --entrypoint bash "$IMAGE" -c 'docker --version && docker buildx version && docker compose version && git --version && jq --version'
check "docker, buildx, compose, git and jq are installed" test "$code" -eq 0

if ((failures > 0)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "All checks passed"
