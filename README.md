# Docker Hardened Images in JFrog Artifactory

Mirror Docker Hardened Images (DHI) from your Docker Hub organization into
Artifactory **with their signed attestations** (SBOM, SLSA provenance, VEX,
scan results), keep them in sync, and use them from laptops and CI.

Based on [Mirror a DHI repository](https://docs.docker.com/dhi/how-to/mirror/),
[Verify a DHI](https://docs.docker.com/dhi/how-to/verify/) and
[Scan a DHI](https://docs.docker.com/dhi/how-to/scan/).

## How it works

```
 Docker Hub (your org)                            Artifactory
 docker.io/<org>/dhi-node            image   ┐    dhi-local   (local)    DHI images + attestations
 registry.scout.docker.com/<org>/    attest. ┘──▶                        written only by the sync
   dhi-node                           regctl / regsync, by digest
                                                  apps-local  (local)    images you build FROM DHI
                                                  docker      (virtual)  = dhi-local + apps-local
                                                       ▲                 the one URL for laptops and CI
                                       developers, CI ─┘  pull / push
```

DHI attestations are not stored next to the image; they live in Docker's Scout
registry. A plain `docker push` or an Artifactory **remote** (pull-through)
repository copies the image only. This sync copies image and attestations into
one **local** repository, by digest, so they stay verifiable and scannable from
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
| `dhi-local` | Docker, **local** | Mirror target. Only the sync account writes here. |
| `apps-local` | Docker, local | Images your teams build. Optional. |
| `docker` | Docker, virtual | `dhi-local` + `apps-local`, default deployment repo `apps-local`. The URL developers and CI use. Optional. |

Permissions:

| Account | Permissions |
|---|---|
| Sync | Read, Deploy/Cache, **Delete/Overwrite** on `dhi-local` (DHI re-points tags on every CVE rebuild) |
| CI | Read on `docker`, `dhi-local`; Deploy/Cache on `apps-local` |
| Developers | Read on `docker`, `dhi-local`, `apps-local` |

### 2. Tokens

**Docker organization access token (OAT)**, used by the sync to read from Docker Hub.
Docker Hub → organization → **Settings → Access tokens → Generate token**
([docs](https://docs.docker.com/security/access-tokens/organization-access-tokens/#create-an-organization-access-token)).
Repository access: the mirrored `dhi-*` repositories, scope **Image Pull**. No other scopes
([reference](https://docs.docker.com/security/access-tokens/reference/#repository-scopes)).
The same token reads the attestations from `registry.scout.docker.com`.

**Docker personal access token (PAT)**, used by Docker Scout (Scout does not accept OATs).
Docker Hub → account → **Account settings → Personal access tokens → Generate new token**
([docs](https://docs.docker.com/security/access-tokens/personal-access-tokens/#create)).
Permission **Repo Read-only**. The account must be a member of the organization.

**Artifactory token**, used by the sync to write.
Repository → **Set Me Up** → generate a token, or **Edit Profile → Identity Tokens**;
for a service account use an access token
([docs](https://jfrog.com/help/r/jfrog-platform-administration-documentation/access-tokens)).
Use the token itself, not the base64 `auth` value shown for `config.json`.

### 3. Settings

```bash
cp .env.example .env && chmod 600 .env
```

Fill in the org, image, tags, Artifactory host and repository keys, and the three
tokens. Comments in `.env.example` explain each value.

## Mirror

```bash
make login     # regctl and docker log in to Docker Hub, the Scout registry and Artifactory
make inspect   # tags, digests and attestations that will be mirrored
make mirror    # copy image + attestations into dhi-local, by digest
make verify    # check the result from Artifactory: digests, attestations, signatures
```

`make mirror` runs the `regctl` command from the Docker docs once per tag:

```bash
regctl image copy docker.io/<org>/dhi-node@<digest> acme.jfrog.io/dhi-local/dhi-node:24 \
  --referrers --referrers-src registry.scout.docker.com/<org>/dhi-node \
  --referrers-tgt acme.jfrog.io/dhi-local/dhi-node --force-recursive
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
  and `make verify` hourly and on demand. Set the `.env` values as repository
  variables and `DOCKER_TOKEN`, `JFROG_TOKEN` as secrets.
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
- `make app`: verify the base's signed provenance, pin it by digest, build
  `examples/app` from Artifactory, run it.

Reference Artifactory explicitly in Dockerfiles and manifests; Docker's
`registry-mirrors` setting applies to Docker Hub pulls only. To block other
registries use [Registry Access Management](https://docs.docker.com/desktop/enterprise/hardened-desktop/registry-access-management/).

## Use from CI

`.github/workflows/build-app.yml` is an application pipeline to copy into an app
repository. It logs in to Artifactory, verifies Docker's signature on the base's
provenance, pins the base by digest, builds with `--sbom=true --provenance=mode=max`,
pushes to `apps-local` (on `main`; pull requests build and smoke-test only), and
scans with Docker Scout, failing on critical/high.

Max provenance is required: Scout follows it to the DHI base and applies its VEX
([docs](https://docs.docker.com/dhi/how-to/scan/#build-child-images-with-provenance-attestations)).

Pin base images by digest in production (`FROM …/dhi-node:24@sha256:…`) and let
Renovate or Dependabot bump them.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cannot read attestations from registry.scout.docker.com/…: unauthorized` | Run `make login`; the OAT needs Image Pull on that repository. |
| Push rejected / `403` on an existing tag | Give the sync account Delete/Overwrite on `dhi-local`. |
| Attestations missing after mirroring | `JFROG_REPO` must be a local repository. |
| Digest in Artifactory differs from Hub | Docker re-pointed the tag. Run `make sync-once`. |
| `↻ changed upstream since copy` in `make verify` | Docker re-issued an attestation. Run `make mirror` again. |
| `make verify` passes for `dhi-local` but not via `docker` | Add `dhi-local` to the virtual repo, or grant Read on it. |
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
| `.github/workflows/dhi-jfrog-sync.yml` | scheduled sync + verify |
| `.github/workflows/build-app.yml` | example app pipeline |
| `examples/app/` | example Node service built on DHI |
| `keys/dhi-latest.pub` | Docker's DHI signing key |
