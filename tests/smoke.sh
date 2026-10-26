#!/usr/bin/env bash
# Smoke test that needs no Azure DevOps organisation: builds the image for the host
# architecture and checks the entrypoint's validation, the agent version and the tooling.
#
# Usage: tests/smoke.sh [version]                    (default: the latest stable agent)
#        CONTAINER_ENGINE=podman tests/smoke.sh 5.281.0
#        IMAGE=azure-pipelines-agent:smoke tests/smoke.sh 5.281.0   (test an existing image, skip the build)
#        DOCKER_SOCKET=/path/to/engine.sock tests/smoke.sh   (default /var/run/docker.sock; skipped if absent)
set -euo pipefail

engine="${CONTAINER_ENGINE:-docker}"
socket="${DOCKER_SOCKET:-/var/run/docker.sock}"
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

# --once also checks that arguments survive the entrypoint's switch to the agent user.
run "$IMAGE" --once
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

# Only root can read /etc/shadow, so this fails only once the entrypoint has switched to the agent user.
run -e AZP_URL=https://dev.azure.com/example -e AZP_TOKEN_FILE=/etc/shadow "$IMAGE"
check "switches from root to the agent user" grep -q "'/etc/shadow' does not exist or is not readable" <<<"$out"

run --entrypoint bash "$IMAGE" -c 'docker --version && docker buildx version && docker compose version && git --version && jq --version'
check "docker, buildx, compose, git and jq are installed" test "$code" -eq 0

# The agent's self-update script waits with ping; one that fails at once makes that wait spin.
# ping needs NET_RAW, which Docker grants by default and podman does not.
run --cap-add NET_RAW --user agent --entrypoint ping "$IMAGE" -c 1 -i 1 127.0.0.1
check "ping works as user 'agent'" test "$code" -eq 0

if [[ -S "$socket" ]]; then
  run -v "$socket:/var/run/docker.sock" "$IMAGE"
  check "the agent user can use a mounted Docker socket" grep -q "Jobs can use the Docker engine" <<<"$out"
else
  echo "skip - no Docker socket at $socket (set DOCKER_SOCKET)"
fi

if ((failures > 0)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "All checks passed"
