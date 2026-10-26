#!/usr/bin/env bash
# Container entrypoint: registers the agent with Azure DevOps, runs it, and removes the
# registration again when the agent exits or the container is stopped.
# Arguments are passed to the agent, e.g. "--once" to take a single job and exit.
set -euo pipefail

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# The image starts as root only to give the agent user the group of a mounted Docker socket, which
# differs per host; the script then restarts itself as "agent". Started as another user (e.g.
# Kubernetes runAsUser), it just continues as that user.
socket=/var/run/docker.sock
if ((EUID == 0)); then
  groups=agent
  [[ -S "$socket" ]] && groups+=",$(stat -c %g "$socket")"
  exec env HOME=/home/agent USER=agent LOGNAME=agent \
    setpriv --reuid=agent --regid=agent --groups="$groups" -- "$0" "$@"
fi

if [[ -S "$socket" ]]; then
  if docker --host "unix://$socket" version >/dev/null 2>&1; then
    log "Jobs can use the Docker engine at $socket"
  else
    printf 'warning: %s is mounted, but user %s cannot use it\n' "$socket" "$(id -un)" >&2
  fi
fi

[[ -n "${AZP_URL:-}" ]] || die "missing AZP_URL environment variable (e.g. https://dev.azure.com/<organisation>)"
[[ "$AZP_URL" =~ ^https?:// ]] || die "AZP_URL must start with https:// or http://, got '$AZP_URL'"

if [[ -n "${AZP_TOKEN_FILE:-}" ]]; then
  [[ -r "$AZP_TOKEN_FILE" ]] || die "AZP_TOKEN_FILE '$AZP_TOKEN_FILE' does not exist or is not readable"
  token="$(<"$AZP_TOKEN_FILE")"
elif [[ -n "${AZP_TOKEN:-}" ]]; then
  token="$AZP_TOKEN"
else
  die "missing AZP_TOKEN or AZP_TOKEN_FILE environment variable"
fi
[[ -n "$token" ]] || die "the personal access token is empty"

# The token stays in this (unexported) shell variable, so jobs do not inherit it, and
# the agent does not report the token variables as capabilities.
unset AZP_TOKEN
export VSO_AGENT_IGNORE="AZP_TOKEN,AZP_TOKEN_FILE${VSO_AGENT_IGNORE:+,$VSO_AGENT_IGNORE}"

agent_name="${AZP_AGENT_NAME:-$(hostname)}"
pool="${AZP_POOL:-Default}"
work="${AZP_WORK:-_work}"

cd /azp/agent
mkdir -p "$work"

agent_pid=""

# A running job blocks removal, so retry for about a minute (compose waits stop_grace_period).
deregister() {
  [[ -f .agent ]] || return 0
  log "Removing agent '$agent_name' from Azure DevOps"
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if VSTS_AGENT_INPUT_TOKEN="$token" ./config.sh remove --unattended --auth PAT; then
      return 0
    fi
    echo "Removal failed (attempt $attempt/6), retrying in 10 seconds..."
    sleep 10
  done
  echo "warning: could not remove the agent; it stays registered as offline" >&2
}

# Invoked by the traps below; ShellCheck reports that as SC2317 (before 0.10) or SC2329.
# shellcheck disable=SC2317,SC2329
shutdown() {
  trap '' INT TERM
  if [[ -n "$agent_pid" ]] && kill -0 "$agent_pid" 2>/dev/null; then
    log "Stopping agent"
    # The agent runs in its own process group (setsid below), so this also reaches the listener and its job.
    kill -TERM -- "-$agent_pid" 2>/dev/null || true
    wait "$agent_pid" 2>/dev/null || true
  fi
  deregister
  exit "$1"
}
trap 'shutdown 130' INT
trap 'shutdown 143' TERM

# Commands run in the background and are awaited so the traps above fire immediately.
log "Configuring agent '$agent_name' for pool '$pool' at $AZP_URL"
VSTS_AGENT_INPUT_TOKEN="$token" ./config.sh --unattended \
  --agent "$agent_name" \
  --url "$AZP_URL" \
  --auth PAT \
  --pool "$pool" \
  --work "$work" \
  --replace \
  --acceptTeeEula &
wait $!

# run-docker.sh is the agent's container-aware launcher: it applies agent self-updates in place.
# It ships without the execute bit, so run it through bash.
log "Starting agent"
setsid bash ./run-docker.sh "$@" &
agent_pid=$!
status=0
wait "$agent_pid" || status=$?
agent_pid=""

deregister
exit "$status"
