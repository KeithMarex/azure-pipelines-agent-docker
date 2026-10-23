<p align="center">
  <img width="96" src="docs/logo.svg" alt="">
</p>

<h1 align="center">Azure Pipelines agent for Docker</h1>

<p align="center">
  A ready-to-run container image for a self-hosted
  <a href="https://github.com/microsoft/azure-pipelines-agent">Azure Pipelines agent</a> on Linux,
  for <code>docker run</code>, Docker Compose and Portainer.
</p>

> [!IMPORTANT]
> **This is an unofficial, community-maintained image.** It is not made by, affiliated with or endorsed by
> Microsoft. The agent inside it is Microsoft's, downloaded unmodified from Microsoft's release feed; see
> [Credits](#credits). Please report problems with the image
> [here](https://github.com/KeithMarex/azure-pipelines-agent-docker/issues), not to Microsoft.

## What it is

Azure Pipelines can run jobs on your own machines through a self-hosted agent. Microsoft retired its own
Docker image for that agent ([`microsoft/vsts-agent`](https://github.com/microsoft/vsts-agent-docker),
archived in 2020) and now [documents](https://learn.microsoft.com/azure/devops/pipelines/agents/docker)
how to build one yourself. This repository does that build for you and publishes the result:

- **Ubuntu 24.04** base, rebuilt weekly for security updates
- **linux/amd64** and **linux/arm64**
- a tag for every agent release, published automatically; the download is verified against
  the SHA-256 in Microsoft's release notes
- runs as a non-root user, registers on start and removes its registration on stop
- Docker CLI with buildx and compose plugins, for jobs that use the host's Docker engine
  ([opt-in](#using-docker-in-jobs))

## Credits

The agent is the work of Microsoft and the
[contributors](https://github.com/microsoft/azure-pipelines-agent/graphs/contributors) to
[microsoft/azure-pipelines-agent](https://github.com/microsoft/azure-pipelines-agent). This image only packages it.

What this image takes from Microsoft:

- the agent itself, unmodified, from `download.agent.dev.azure.com`;
- the way the container registers, runs and removes the agent, which follows Microsoft's guide
  [Run a self-hosted agent in Docker](https://learn.microsoft.com/azure/devops/pipelines/agents/docker);
- the agent's own `installdependencies.sh` and `run-docker.sh`, which the image uses as they are.

Links to the original project:

- Source code and releases: [github.com/microsoft/azure-pipelines-agent](https://github.com/microsoft/azure-pipelines-agent)
- Documentation: [Azure Pipelines agents](https://learn.microsoft.com/azure/devops/pipelines/agents/agents)

Problems with the agent itself, rather than with this image, belong in
[Microsoft's issue tracker](https://github.com/microsoft/azure-pipelines-agent/issues).

## Quick start

Create a personal access token (PAT) with the scope **Agent Pools (Read & manage)**
(*User settings → Personal access tokens*), then:

```bash
docker run -d --name azp-agent \
  -e AZP_URL=https://dev.azure.com/<organisation> \
  -e AZP_TOKEN=<personal access token> \
  -e AZP_POOL=Default \
  -e AZP_AGENT_NAME=docker-agent-01 \
  ghcr.io/keithmarex/azure-pipelines-agent:latest
```

The agent appears under *Organization settings → Agent pools → \<pool\> → Agents*.

### Docker Compose / Portainer

[`docker-compose.yml`](docker-compose.yml) is a complete stack. In Portainer, choose
*Stacks → Add stack*, then either *Repository* (pointing to this repository) or paste the
file into the *Web editor*. Set `AZP_URL`, `AZP_TOKEN`, `AZP_AGENT_NAME` and optionally
`AZP_POOL` under *Environment variables*.

With plain Compose, put the same variables in a `.env` file next to `docker-compose.yml`
and run `docker compose up -d`.

## Configuration

| Variable | Required | Default | Description |
|---|---|---|---|
| `AZP_URL` | yes | | Organisation URL, e.g. `https://dev.azure.com/contoso` or `https://tfs.contoso.com/tfs/DefaultCollection` |
| `AZP_TOKEN` | one of these two | | Personal access token |
| `AZP_TOKEN_FILE` | one of these two | | Path to a file holding the token, e.g. a Docker secret in `/run/secrets/` |
| `AZP_POOL` | no | `Default` | Agent pool to join |
| `AZP_AGENT_NAME` | no | container hostname | Agent name; must be unique within the pool |
| `AZP_WORK` | no | `/azp/_work` | Work directory for jobs; mount a volume here |

Arguments after the image name are passed to the agent. Use `--once` to take a single job
and exit, and let your orchestrator start a fresh container for the next one.

**Agent names:** registering with an existing name replaces that agent. Give each container
a fixed, unique name. Without a fixed name, every recreated container registers under a new
name and leaves its predecessor behind as an offline agent when it was not stopped cleanly.

**Stopping:** on `docker stop` the agent stops its job and removes its registration. That can
take a while when a job is running, so allow a grace period (`docker stop -t 120`, or
`stop_grace_period` in Compose).

## Tags

| Tag | Meaning |
|---|---|
| `latest`, `ubuntu24.04` | Newest **stable** agent release |
| `<version>`, e.g. `5.280.0` | That agent release |
| `<version>-ubuntu24.04` | That agent release on Ubuntu 24.04 |

Microsoft first rolls a release out as a GitHub *pre-release* while organisations already
start receiving it. Such versions get a version tag when built on request, but never `latest`.
You do not need to chase versions: the agent updates itself in place when Azure DevOps asks it
to. An update lasts until the container is recreated.

## Using Docker in jobs

The image contains the Docker CLI but no Docker engine. To let jobs build and run containers,
mount the host's socket and add the agent user to the host's `docker` group:

```yaml
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    group_add:
      - "${DOCKER_GID}" # getent group docker | cut -d: -f3
```

**Every pipeline that runs on this agent then has root-equivalent access to the host.** Only do
this for pools that run trusted pipelines. Also note that bind mounts in `docker run -v` are
resolved on the host, not inside the agent container.

## Adding tools

Tasks expect their tools on the `PATH`. Extend the image for your stack:

```dockerfile
FROM ghcr.io/keithmarex/azure-pipelines-agent:latest
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends openjdk-21-jdk-headless \
 && rm -rf /var/lib/apt/lists/*
USER agent
```

The agent scans its environment for capabilities when it starts, so newly installed tools
show up automatically.

## Security notes

- Jobs run as the same user as the agent. The token is kept out of the job environment, but a
  malicious pipeline can still find it. Use a PAT that only has the *Agent Pools (Read & manage)*
  scope, and give it a sensible expiry.
- `AZP_TOKEN_FILE` keeps the token out of `docker inspect` output and Portainer's container view.

## Building locally

The build needs the agent version and the checksums from its release notes;
[`scripts/resolve-agent.sh`](scripts/resolve-agent.sh) looks them up:

```bash
scripts/resolve-agent.sh 5.281.0   # or no argument for the latest stable release
tests/smoke.sh 5.281.0             # builds the image and runs checks; CONTAINER_ENGINE=podman works too
```

Pull requests are built and smoke-tested by [the workflow](.github/workflows/build.yml) for both
architectures. Pushes to `main`, a daily check for new releases, a weekly rebuild and manual runs
(*Actions → build → Run workflow*, optionally with a version) publish to GHCR.

## License

The files in this repository are licensed under the [MIT license](LICENSE). The Azure Pipelines agent in the
image is licensed by Microsoft under its own
[MIT license](https://github.com/microsoft/azure-pipelines-agent/blob/master/LICENSE).

Azure, Azure DevOps and Azure Pipelines are trademarks of Microsoft. This project uses those names only to say
what the image contains. The logo is this project's own and is not derived from Microsoft's logos.
