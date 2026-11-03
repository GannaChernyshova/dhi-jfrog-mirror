# Docker Hardened Images in JFrog Artifactory

Copy Docker Hardened Images (DHI) into JFrog Artifactory **together with their
signed attestations** (SBOM, provenance, VEX, scan results) and keep them current.
Developers and CI then pull DHI from Artifactory only.

## How it works

```
 DHI catalog ──mirror──▶ Docker Hub (your org)             Artifactory
                         dhi-<name>              image  ┐
                         Scout registry   attestations  ┘─ sync ─▶ <jfrog-repo> ◀── developers, CI
```

1. **Docker Hub mirror:** you mirror a DHI image from the catalog into your
   Docker Hub organization as `dhi-<name>` (for example `dhi-node`). Docker keeps it
   up to date.
2. **Sync:** a workflow copies the image **and** its attestations into Artifactory,
   by digest. The attestations live in Docker's Scout registry
   (`registry.scout.docker.com`), not next to the image, so a plain `docker pull` /
   `push` would lose them.
3. **Verify:** the workflow checks the copy from Artifactory alone: same digests as
   Hub, all attestations present, signatures valid.

## Prerequisites

- A Docker Hub organization with a DHI Select or Enterprise subscription (or trial),
  and organization-owner rights to create tokens.
- Admin rights in Artifactory (to create a Docker repository and a token).
- A GitHub repository holding this project (fork or copy it). Enable its workflows
  in the **Actions** tab if they show as disabled.

## Setup

### 1. Create two tokens

**Docker organization access token (OAT).** Docker Hub → your organization →
**Settings → Access tokens → Generate token**
([docs](https://docs.docker.com/security/access-tokens/organization-access-tokens/#create-an-organization-access-token)).
Scopes:

| Level | Resource | Scopes |
|---|---|---|
| Repositories | `*/*/public` | `scope-image-pull` |
| Repositories | `<org>/*` | `scope-image-push`, `scope-repository-edit` |
| Organization | `<org>` | `scope-repository-create`, `scope-repository-list` |

It is shown once, so copy it. Its username is the **organization name**, not your
Docker ID. It creates the Docker Hub mirror and reads the image and attestations.

**Artifactory token.** Avatar → **Edit Profile → Identity Tokens**, or **Set Me
Up** on the repository
([docs](https://jfrog.com/help/r/jfrog-platform-administration-documentation/access-tokens)).
Use the token itself, not the base64 `auth` value Set Me Up shows.

> A Docker personal access token (PAT) is **not** needed to mirror. It is only for
> Docker Scout scans: [Optional: Docker Scout](#optional-docker-scout-scans).

### 2. Create the Artifactory repository

Create a **Docker** repository (`<jfrog-repo>` below). Give the sync account
**Read, Deploy/Cache and Delete/Overwrite** on it: DHI re-points tags on every CVE
rebuild, so overwrite is required. CI and developers need **Read**.

### 3. Add the values to GitHub

Your GitHub repository → **Settings → Secrets and variables → Actions**.

| Tab | Name | Value |
|---|---|---|
| Variables | `DHI_ORG` | Docker Hub organization name |
| Variables | `SRC_IMAGE` | the Hub repository, starts with `dhi-`, for example `dhi-node` |
| Variables | `DHI_SOURCE` | optional: name in the DHI catalog, for example `node` (default: `SRC_IMAGE` without `dhi-`) |
| Variables | `DEST_IMAGE` | image name in Artifactory, normally the same as `SRC_IMAGE` |
| Variables | `TAGS` | tags to copy, space separated, for example `24 24-dev` (set it after step 4, when you can see the tags) |
| Variables | `JFROG_HOST` | Artifactory hostname, no `https://`, for example `acme.jfrog.io` |
| Variables | `JFROG_REPO` | `<jfrog-repo>` |
| Variables | `JFROG_USER` | username shown in Set Me Up |
| Secrets | `DOCKER_TOKEN` | the OAT |
| Secrets | `JFROG_TOKEN` | the Artifactory token |

### 4. Mirror DHI into your Docker Hub organization

Once per image; skip it if `dhi-<name>` already exists
([docs](https://docs.docker.com/dhi/how-to/mirror/)).

**Docker Hub UI (recommended):** **My Hub** → your organization → **Hardened Images
→ Catalog** → open the image → **Use this image → Mirror repository**. After a few
minutes it is listed under **Hardened Images → Manage → Mirrored Images**. Note
its tags (repository → Tags) for `TAGS`.

**GitHub workflow, if you prefer to script it:** **Actions → Mirror DHI into Docker
Hub → Run workflow**. It mirrors the catalog image `DHI_SOURCE` into
`<DHI_ORG>/<SRC_IMAGE>` with `dhictl`, and is safe to re-run. To mirror another image
once, type `src_image` (starts with `dhi-`) and `dhi_source` in the run dialog.

**`dhictl` on your machine:** download it from the
[releases page](https://github.com/docker-hardened-images/dhictl/releases) onto your
`PATH` (Docker Desktop 4.65+ has the same commands as `docker dhi`).

```bash
export DHI_ORG=<org>
export DHI_API_TOKEN=$(curl -s -X POST https://hub.docker.com/v2/auth/token \
  -H "Content-Type: application/json" \
  -d '{"identifier": "'$DHI_ORG'", "secret": "<the OAT>"}' | jq -r .access_token)
dhictl mirror start dhi/node,$DHI_ORG/dhi-node     # catalog image, your repository
dhictl mirror list
```

(`DHI_API_TOKEN` here is the short-lived token `dhictl` needs, not the OAT itself.)

### 5. Copy it into Artifactory

**Actions → Mirror DHI → Artifactory → Run workflow** (optionally type tags to copy;
the default is `TAGS`). Success ends with:

```
━━ Summary
   attestations/signatures present: 60, missing: 0
   signatures verified with Docker's DHI key: 30, failed: 0
   ✔ image and its signed attestations are in Artifactory
```

The signatures are checked against Docker's DHI key (`keys/dhi-latest.pub`).

## Keep it up to date

DHI re-points tags to new digests on every CVE rebuild, even `24.22.2`. **Actions →
DHI → Artifactory sync** refreshes the tags in `TAGS` every hour and on demand, with
the same variables and secrets. To sync as soon as Docker publishes a rebuild, add a
[Docker Hub webhook](https://docs.docker.com/docker-hub/repos/manage/webhooks/) that
triggers it (`repository_dispatch`, type `dhi-updated`).

## Use the images

```bash
docker login acme.jfrog.io
docker pull acme.jfrog.io/<jfrog-repo>/dhi-node:24
```

```dockerfile
FROM acme.jfrog.io/<jfrog-repo>/dhi-node:24-dev AS build
FROM acme.jfrog.io/<jfrog-repo>/dhi-node:24
```

Name Artifactory in every `FROM`: Docker's `registry-mirrors` setting only applies
to Docker Hub pulls. In production, pin by digest (`…/dhi-node:24@sha256:…`) and let
Renovate or Dependabot bump it. To block other registries, use
[Registry Access Management](https://docs.docker.com/desktop/enterprise/hardened-desktop/registry-access-management/).

Verify Docker's signature on an attestation (DHI signs each attestation, not the
image index):

```bash
regctl artifact list acme.jfrog.io/<jfrog-repo>/dhi-node:24 --platform linux/amd64 \
  --filter-annotation in-toto.io/predicate-type=https://slsa.dev/provenance/v0.2   # prints ...@sha256:<att>
cosign verify --key keys/dhi-latest.pub --insecure-ignore-tlog=true --experimental-oci11 \
  acme.jfrog.io/<jfrog-repo>/dhi-node@sha256:<att>
```

## Other ways to run the sync

### Jenkins

The `Jenkinsfile` runs the same steps and calls the repo's scripts.

1. **Credentials**: `dhi-docker-oat` (*Secret text*, the OAT) and `dhi-jfrog`
   (*Username with password*, Artifactory user and token).
2. **Job**: *Pipeline* → *Pipeline script from SCM* → your copy of this repository,
   script path `Jenkinsfile`.
3. **Settings**: edit the `environment` block at the top (`DHI_ORG`, `SRC_IMAGE`,
   `DEST_IMAGE`, `JFROG_HOST`, `JFROG_REPO`, same names as above). `TAGS` is a job
   parameter.
4. **Agent**: Linux amd64 with `bash`, `curl`, `jq` and the Docker CLI, with access to
   `docker.io`, `registry.scout.docker.com`, `github.com` (tool download) and
   Artifactory. Without GitHub access, put `regctl`, `regsync` and `cosign` on the
   `PATH` and remove the *Install tools* stage.
5. **Run**: *Build with Parameters* with `MODE=mirror` for the first copy. The hourly
   schedule then runs `MODE=sync`. For instant syncs, call the job from a Docker Hub
   webhook with the Generic Webhook Trigger plugin.

### Your machine

```bash
brew install regclient cosign jq        # and Docker Desktop
cp .env.example .env && chmod 600 .env  # same names as the GitHub table; .env is git-ignored
make login      # Docker Hub, Scout registry and Artifactory
make inspect    # tags, digests and attestations that will be copied
make mirror     # copy image + attestations into Artifactory, by digest
make verify     # check digests, attestations and signatures from Artifactory
make sync-once  # one sync pass (make sync: every hour)
```

`make mirror` is the `regctl` command from the Docker docs, once per tag:

```bash
regctl image copy docker.io/<org>/dhi-node@<digest> acme.jfrog.io/<jfrog-repo>/dhi-node:24 \
  --referrers --referrers-src registry.scout.docker.com/<org>/dhi-node \
  --referrers-tgt acme.jfrog.io/<jfrog-repo>/dhi-node --force-recursive
```

## Optional: Docker Scout scans

Only if you scan with Docker Scout. If you use another scanner (for example Black
Duck), skip this: **mirroring and verification never use it.**

Scout does not accept organization tokens, so it needs a **personal access token
(PAT)**: Docker Hub → avatar → **Account settings → Personal access tokens →
Generate new token**, permission **Repo Read-only**
([docs](https://docs.docker.com/security/access-tokens/personal-access-tokens/#create)).
The account must be an organization member.

```bash
docker login -u <your-docker-id>                          # paste the PAT
IMG=registry://acme.jfrog.io/<jfrog-repo>/dhi-node:24     # registry:// = read from Artifactory
docker scout cves $IMG                                    # "✓ VEX statements obtained from attestation"
docker scout attest list $IMG --platform linux/amd64
```

For your own images built on DHI, use `--sbom=true --provenance=mode=max` so Scout can
follow the provenance to the DHI base and apply its VEX
([docs](https://docs.docker.com/dhi/how-to/scan/#build-child-images-with-provenance-attestations)).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `failed to ping registry docker.io: unauthorized` | `DHI_ORG` must be the organization name (not your Docker ID) and `DOCKER_TOKEN` the OAT. |
| `cannot read attestations from registry.scout.docker.com/…: unauthorized` | The OAT is missing a scope from step 1, or `DHI_ORG` is not the organization name. |
| `Source repository does not exist` (mirror workflow) | `DHI_SOURCE` is the catalog name without `dhi-`, for example `node`. |
| `Destination repository is already used for mirroring` | It is already a mirror. Nothing to do (the workflow now skips it). |
| Push rejected / `403` on an existing tag | Give the sync account Delete/Overwrite on the JFrog repository. |
| Attestations missing after mirroring | `JFROG_REPO` must be a Docker repository the sync account can push to. |
| Digest in Artifactory differs from Hub | Docker re-pointed the tag. Run the sync again. |
| `↻ changed upstream since copy` | Docker re-issued an attestation. Run the mirror again. |
| `docker scout` authentication error | Scout needs a Docker ID + PAT, not the OAT. |

## Files

| Path | Purpose |
|---|---|
| `.github/workflows/dhi-hub-mirror.yml` | DHI catalog → your Docker Hub org (`dhictl`) |
| `.github/workflows/mirror.yml` | Docker Hub → Artifactory, one-off, with verify |
| `.github/workflows/dhi-jfrog-sync.yml` | hourly sync + verify |
| `Jenkinsfile` | the same, for Jenkins |
| `regsync.yaml` | sync settings (tag allow-list generated from `TAGS`) |
| `scripts/`, `Makefile` | the same steps for your machine (`make help`) |
| `.env.example` | settings for running from your machine |
| `keys/dhi-latest.pub` | Docker's DHI signing key |
