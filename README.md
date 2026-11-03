# Docker Hardened Images in JFrog Artifactory

Mirror Docker Hardened Images (DHI) from your Docker Hub organization into
Artifactory **with their signed attestations** (SBOM, SLSA provenance, VEX,
scan results), keep them in sync, and use them from laptops and CI.

Based on [Mirror a DHI repository](https://docs.docker.com/dhi/how-to/mirror/),
[Verify a DHI](https://docs.docker.com/dhi/how-to/verify/) and
[Scan a DHI](https://docs.docker.com/dhi/how-to/scan/).

## How it works

```
 Docker Hub (your org)                    Artifactory
 docker.io/<org>/dhi-node         image  ┐
 registry.scout.docker.com/...    attest.┘─ sync, by digest ─▶  <dhi-repo>   DHI images + attestations
                                                                   ▲
                                                 developers, CI ───┘ pull
```

The image is on Docker Hub, but its signed attestations (SBOM, provenance, VEX,
scan results) are in Docker's Scout registry. The sync copies both into one
Artifactory repository, by digest, so they stay verifiable and scannable from
Artifactory alone.

Repository names are settings in `.env`. The minimum is one local repository.

## Prerequisites

| Tool | Install (macOS) |
|---|---|
| `regctl`, `regsync` | `brew install regclient` |
| `cosign` ≥ 2.2 | `brew install cosign` |
| `jq`, `curl` | `brew install jq` |
| Docker Desktop (includes Docker Scout) | docker.com |

## Setup

### 1. Artifactory repositories

| Key (default) | Type | Purpose |
|---|---|---|
| `<dhi-repo>` | Docker, **local** | Mirror target. Only the sync account writes here. |
| `apps-local` | Docker, local | Images your teams build. Optional. |
| `docker` | Docker, virtual | the DHI repository + `apps-local`, default deployment repo `apps-local`. The URL developers and CI use. Optional. |

Permissions:

| Account | Permissions |
|---|---|
| Sync | Read, Deploy/Cache, **Delete/Overwrite** on the DHI repository (DHI re-points tags on every CVE rebuild) |
| CI | Read on `docker` and the DHI repository; Deploy/Cache on `apps-local` |
| Developers | Read on `docker`, the DHI repository, `apps-local` |

### 2. Tokens

**Docker organization access token (OAT)**, used by the sync to read from Docker Hub.
Docker Hub → organization → **Settings → Access tokens → Generate token**
([docs](https://docs.docker.com/security/access-tokens/organization-access-tokens/#create-an-organization-access-token)).
Repository access: the mirrored `dhi-*` repositories, scope **Image Pull**. No other scopes
([reference](https://docs.docker.com/security/access-tokens/reference/#repository-scopes)).
The same token reads the attestations from `registry.scout.docker.com`.
Goes into `.env` as `DOCKER_TOKEN`, with `DOCKER_USERNAME` set to the organization name.

**Docker personal access token (PAT)**, used by Docker Scout (Scout does not accept OATs).
Docker Hub → account → **Account settings → Personal access tokens → Generate new token**
([docs](https://docs.docker.com/security/access-tokens/personal-access-tokens/#create)).
Permission **Repo Read-only**. The account must be a member of the organization.
Goes into `.env` as `SCOUT_TOKEN`, with `SCOUT_USERNAME` set to your personal Docker ID.

**Artifactory token**, used by the sync to write.
Repository → **Set Me Up** → generate a token, or **Edit Profile → Identity Tokens**;
for a service account use an access token
([docs](https://jfrog.com/help/r/jfrog-platform-administration-documentation/access-tokens)).
Use the token itself, not the base64 `auth` value shown for `config.json`.
Goes into `.env` as `JFROG_TOKEN`, with `JFROG_USER` set to the username shown in **Set Me Up**.

### 3. Settings

```bash
cp .env.example .env && chmod 600 .env
```

Fill in the org, image, tags, Artifactory host and repository keys, and the three
tokens. Comments in `.env.example` explain where to get each value.

| `.env` variable | Value | Used for |
|---|---|---|
| `DOCKER_USERNAME` | organization name | reading from Docker Hub and the Scout registry |
| `DOCKER_TOKEN` | **OAT** (Image Pull) | reading from Docker Hub and the Scout registry |
| `SCOUT_USERNAME` | your personal Docker ID | `docker scout` |
| `SCOUT_TOKEN` | **PAT** (Repo Read-only) | `docker scout` |
| `JFROG_HOST` | Artifactory hostname, no `https://` | writing to Artifactory |
| `JFROG_USER` | username from Set Me Up | writing to Artifactory |
| `JFROG_TOKEN` | **Artifactory token** | writing to Artifactory |

`.env` is git-ignored. For GitHub Actions, see the next step.

### 4. GitHub Actions variables and secrets (to run the workflows)

The workflows do not read `.env`. Add the same values to the GitHub repository
that holds this project: **Settings → Secrets and variables → Actions**.

| Tab | Name | Value from `.env` |
|---|---|---|
| **Variables** | `DOCKER_ORG`, `SRC_IMAGE`, `DEST_IMAGE`, `TAGS`, `DOCKER_USERNAME` | same as in `.env` |
| **Variables** | `JFROG_HOST`, `JFROG_REPO`, `JFROG_USER` | same as in `.env` |
| **Variables** | `JFROG_VIRTUAL` | same as in `.env`; optional, skip it if empty |
| **Secrets** | `DOCKER_TOKEN` | the OAT |
| **Secrets** | `JFROG_TOKEN` | the Artifactory token |

Tokens go in **Secrets**, never in Variables. `SCOUT_USERNAME` and `SCOUT_TOKEN`
are not needed by these workflows.

Or set them all from `.env` with the [GitHub CLI](https://cli.github.com/)
(`gh auth login` first; run it inside the cloned repository, or add `-R <owner>/<repo>`):

```bash
set -a; . ./.env; set +a
for v in DOCKER_ORG SRC_IMAGE DEST_IMAGE TAGS DOCKER_USERNAME \
         JFROG_HOST JFROG_REPO JFROG_VIRTUAL JFROG_USER; do
  [ -n "${!v}" ] && gh variable set "$v" --body "${!v}"
done
for s in DOCKER_TOKEN JFROG_TOKEN; do
  printf '%s' "${!s}" | gh secret set "$s"
done
```

Check with `gh variable list` and `gh secret list` (secret values are never shown).
The workflows use repository-level values. If you would rather use a GitHub
*environment* (for approvals or per-environment values), create it under
**Settings → Environments**, store the values there, and add `environment: <name>`
to the job in `mirror.yml` and `dhi-jfrog-sync.yml`.

## Mirror

```bash
make login     # regctl and docker log in to Docker Hub, the Scout registry and Artifactory
make inspect   # tags, digests and attestations that will be mirrored
make mirror    # copy image + attestations into the DHI repository, by digest
make verify    # check the result from Artifactory: digests, attestations, signatures
```

**In GitHub Actions:** run the **Mirror DHI → Artifactory** workflow
(`.github/workflows/mirror.yml`, Actions tab → Run workflow). It runs the four
steps above, reading the `.env` values from repository variables and secrets
(Setup, step 4). Optionally enter tags to mirror; the default is the `TAGS` variable.

`make mirror` runs the `regctl` command from the Docker docs once per tag:

```bash
regctl image copy docker.io/<org>/dhi-node@<digest> acme.jfrog.io/<dhi-repo>/dhi-node:24 \
  --referrers --referrers-src registry.scout.docker.com/<org>/dhi-node \
  --referrers-tgt acme.jfrog.io/<dhi-repo>/dhi-node --force-recursive
```

`make verify` reads only from Artifactory (the local repo, then the virtual repo
if configured) and checks that each tag's digest equals Docker Hub, every
attestation from Scout is present, and every signature verifies against Docker's
DHI key (`keys/dhi-latest.pub`, from `https://registry.scout.docker.com/keyring/dhi/latest.pub`).
Expected ending:

```
━━ Summary
   attestations/signatures present: 60, missing: 0
   signatures verified with Docker's DHI key: 30, failed: 0
   ✔ image and its signed attestations are in Artifactory
```

## Keep in sync

DHI updates tags in place: a CVE rebuild points the existing tag (even `24.22.2`)
at a new digest. Run the sync continuously.

- **regsync**: `make sync-once` (one pass) or `make sync` (runs hourly).
  Tags are an allow-list in `regsync.yaml`; keep it equal to `TAGS` in `.env`.
- **GitHub Actions**: `.github/workflows/dhi-jfrog-sync.yml` runs `regsync once`
  and `make verify` hourly and on demand. Set the variables and secrets from
  Setup, step 4. The mirror workflow uses the same ones.
- **On change**: add a [Docker Hub webhook](https://docs.docker.com/docker-hub/repos/manage/webhooks/)
  on the mirrored repository that triggers the workflow (`repository_dispatch`,
  type `dhi-updated`). The payload's `dhi_metadata` lists the CVEs fixed.

## Use from a laptop

```bash
docker login acme.jfrog.io
docker pull acme.jfrog.io/docker/dhi-node:24
```

```dockerfile
FROM acme.jfrog.io/docker/dhi-node:24-dev AS build
FROM acme.jfrog.io/docker/dhi-node:24
```

Scan and inspect attestations with Docker Scout, reading from Artifactory
(`registry://` prefix):

```bash
IMG=registry://acme.jfrog.io/docker/dhi-node:24
docker scout cves $IMG                                  # "✓ VEX statements obtained from attestation"
docker scout attest list $IMG --platform linux/amd64    # attached attestations and their predicate types
docker scout attest get  $IMG --platform linux/amd64 --predicate \
  --predicate-type https://openvex.dev/ns/v0.2.0        # the VEX document; same for the SBOM, provenance
docker scout attest get  $IMG --platform linux/amd64 --verify --skip-tlog \
  --predicate-type https://slsa.dev/provenance/v0.2     # verify Docker's signature on it first
```

Verify with cosign (DHI signs each attestation, not the image index):

```bash
regctl artifact list acme.jfrog.io/docker/dhi-node:24 --platform linux/amd64 \
  --filter-annotation in-toto.io/predicate-type=https://slsa.dev/provenance/v0.2   # Name: ...@sha256:<att>
cosign verify --key keys/dhi-latest.pub --insecure-ignore-tlog=true --experimental-oci11 \
  acme.jfrog.io/docker/dhi-node@sha256:<att>
```

Make targets:

- `make use`: pull and run, export SBOM and VEX to `out/`, scan with Scout.
- `make app`: verify the base's signed provenance, pin it by digest, build an
  app from Artifactory, run it.

Reference Artifactory explicitly in Dockerfiles and manifests; Docker's
`registry-mirrors` setting applies to Docker Hub pulls only. To block other
registries use [Registry Access Management](https://docs.docker.com/desktop/enterprise/hardened-desktop/registry-access-management/).

## Use from CI

In an application pipeline, pull the base from Artifactory, build with
`--sbom=true --provenance=mode=max`, and scan with Docker Scout.

Max provenance is required: Scout follows it to the DHI base and applies its VEX
([docs](https://docs.docker.com/dhi/how-to/scan/#build-child-images-with-provenance-attestations)).

Pin base images by digest in production (`FROM …/dhi-node:24@sha256:…`) and let
Renovate or Dependabot bump them.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cannot read attestations from registry.scout.docker.com/…: unauthorized` | Run `make login`; the OAT needs Image Pull on that repository. |
| Push rejected / `403` on an existing tag | Give the sync account Delete/Overwrite on the DHI repository. |
| Attestations missing after mirroring | `JFROG_REPO` must be a local repository. |
| Digest in Artifactory differs from Hub | Docker re-pointed the tag. Run `make sync-once`. |
| `↻ changed upstream since copy` in `make verify` | Docker re-issued an attestation. Run `make mirror` again. |
| `make verify` passes for the DHI repository but not via `docker` | Add the DHI repository to the virtual repo, or grant Read on it. |
| `no DHI-signed provenance in Artifactory - not building on it` | Mirror that tag (`TAGS` and `regsync.yaml`), or re-check the key with `make inspect`. |
| `docker scout` authentication error | Set `SCOUT_USERNAME`/`SCOUT_TOKEN` (Docker ID + PAT), run `make login`. |

## Files

| Path | Purpose |
|---|---|
| `.env.example` | All settings |
| `Makefile` | `make help` lists the targets |
| `scripts/01-login.sh` … `04-verify.sh` | login, inspect, mirror, verify |
| `scripts/05-use.sh`, `06-app.sh` | use from a laptop, build an app |
| `regsync.yaml` | continuous sync |
| `.github/workflows/mirror.yml` | one-off mirror + verify (manual run) |
| `.github/workflows/dhi-jfrog-sync.yml` | scheduled sync + verify |
| `keys/dhi-latest.pub` | Docker's DHI signing key |
