# Docker Hardened Images in JFrog Artifactory

Copy Docker Hardened Images (DHI) from your Docker Hub organization into JFrog
Artifactory **together with their signed attestations** (SBOM, provenance, VEX,
scan results), and keep them up to date. Developers and CI then pull DHI from
Artifactory only.

## How it works

```
 Docker Hub (your org)                  Artifactory
 dhi-<name>               image  ┐
 Scout registry     attestations ┘─ sync ─▶  <jfrog-repo>  ◀── developers, CI pull
```

The image is on Docker Hub, but its signed attestations live in Docker's Scout
registry (`registry.scout.docker.com`). The sync copies both into one Artifactory
repository, by digest, so everything stays verifiable from Artifactory alone.
A plain `docker pull` / `docker push` would copy the image without them.

## Before you start

- A Docker Hub organization with a DHI Select or Enterprise subscription (or an
  active trial), and you can create access tokens for it (organization owner).
- You can create a Docker repository and a token in Artifactory (admin).
- A GitHub repository for this project (fork or copy it). Enable its workflows in
  the **Actions** tab if GitHub shows them as disabled.

## Setup

### 1. Mirror DHI into your Docker Hub organization

Skip this if your organization already has the `dhi-<name>` repository (for
example `dhi-node`). Do it once per image, with the `dhictl` CLI
([docs](https://docs.docker.com/dhi/how-to/mirror/)).

Install: download `dhictl` for your platform from the
[releases page](https://github.com/docker-hardened-images/dhictl/releases) and put
it on your `PATH` (`mv dhictl /usr/local/bin/`). Docker Desktop 4.65+ already has
the same commands as `docker dhi`.

```bash
export DHI_ORG=<org>                      # dhictl reads the organization from here
# Log in: exchange an organization access token for a short-lived API token
export DHI_API_TOKEN=$(curl -s -X POST https://hub.docker.com/v2/auth/token \
  -H "Content-Type: application/json" \
  -d '{"identifier": "'$DHI_ORG'", "secret": "<org-token>"}' | jq -r .access_token)

# Mirror dhi/node into <org>/dhi-node, then check it
dhictl mirror start dhi/node,$DHI_ORG/dhi-node
dhictl mirror list
```

Or run it from GitHub: **Actions → Mirror DHI into Docker Hub → Run workflow**
(`.github/workflows/dhi-hub-mirror.yml`). It installs `dhictl`, exchanges the
`DOCKER_TOKEN` secret for an API token, and mirrors `DHI_SOURCE` (for example
`node`) into `<DHI_ORG>/<SRC_IMAGE>`. Add the variables and secret from step 4 first.
`DHI_SOURCE` is optional: it defaults to `SRC_IMAGE` without the `dhi-` prefix.

`DHI_ORG` and `DHI_API_TOKEN` are the names `dhictl` reads. `DHI_API_TOKEN` is the
short-lived API token from the exchange above, not your organization access token,
which this project calls `DOCKER_TOKEN`.

Creating a new mirror repository needs a token with organization-wide repository
access; the sync token in step 3 only needs Image Pull. Use a separate, short-lived
token for this one-time step. For the workflow, put that token in the `DOCKER_TOKEN`
secret for the run, then replace it with the Image Pull token.

Once `<org>/dhi-node` exists, note its tags (Docker Hub → the repository → Tags):
they go in `TAGS` below.

### 2. Create the Artifactory repository

Create a **Docker** repository in Artifactory. Its name is `<jfrog-repo>` below.
Give the sync account **Read, Deploy/Cache and Delete/Overwrite** on it (DHI
re-points tags on every CVE rebuild, so overwrite is required). CI and developers
need **Read**.

### 3. Create two tokens

Mirroring needs only these two.

| Token | Create it at | Settings | Used to |
|---|---|---|---|
| **Docker organization access token (OAT)** | Docker Hub → your organization → **Settings → Access tokens → Generate token** ([docs](https://docs.docker.com/security/access-tokens/organization-access-tokens/#create-an-organization-access-token)) | Repository access: the `dhi-*` repositories. Scope: **Image Pull** only. | read the image from Docker Hub **and** the attestations from the Scout registry |
| **Artifactory token** | Artifactory → your repository → **Set Me Up** → generate a token ([docs](https://jfrog.com/help/r/jfrog-platform-administration-documentation/access-tokens)) | Use the token itself, not the base64 `auth` value Set Me Up shows. | write to `<jfrog-repo>` |

The OAT's username is the **organization name**, not your personal Docker ID.

> A Docker personal access token (PAT) is **not** needed for mirroring. It is only
> for Docker Scout scans, see [Optional: Docker Scout](#optional-docker-scout-scans).

### 4. Add the values to GitHub

In your GitHub repository: **Settings → Secrets and variables → Actions**.

| Tab | Name | Value |
|---|---|---|
| Variables | `DHI_ORG` | Docker Hub organization name (also the OAT's username) |
| Variables | `SRC_IMAGE` | the Hub repository, for example `dhi-node` |
| Variables | `DHI_SOURCE` | optional, only for the Docker Hub mirror workflow: the image's name in the DHI catalog, for example `node` (default: `SRC_IMAGE` without `dhi-`) |
| Variables | `DEST_IMAGE` | image name in Artifactory (normally the same as `SRC_IMAGE`) |
| Variables | `TAGS` | tags to mirror, space separated, for example `24 24-dev` |
| Variables | `JFROG_HOST` | Artifactory hostname without `https://`, for example `acme.jfrog.io` |
| Variables | `JFROG_REPO` | `<jfrog-repo>` |
| Variables | `JFROG_USER` | the username shown in Set Me Up |
| Secrets | `DOCKER_TOKEN` | the OAT |
| Secrets | `JFROG_TOKEN` | the Artifactory token |

### 5. Run it

**Actions → Mirror DHI → Artifactory → Run workflow.** It copies each tag with its
attestations, then checks the result from Artifactory. Success ends with:

```
━━ Summary
   attestations/signatures present: 60, missing: 0
   signatures verified with Docker's DHI key: 30, failed: 0
   ✔ image and its signed attestations are in Artifactory
```

The check confirms each tag has the same digest as on Docker Hub, every
attestation is present, and every signature verifies against Docker's DHI key
(`keys/dhi-latest.pub`).

## Keep it up to date

DHI re-points tags to new digests on every CVE rebuild (even `24.22.2`), so the
copy must be refreshed. **Actions → DHI → Artifactory sync** does that every hour
and can be run on demand. It reads the same variables and secrets as above.

It syncs the tags in `TAGS`, the same list the mirror uses.

To sync right away when Docker publishes a rebuild, add a
[Docker Hub webhook](https://docs.docker.com/docker-hub/repos/manage/webhooks/)
that triggers the workflow (`repository_dispatch`, type `dhi-updated`).

## Using Jenkins

The `Jenkinsfile` runs the same steps as the two workflows. It calls the repo's
scripts, so nothing else needs porting.

1. **Credentials** (Manage Jenkins → Credentials):
   - `dhi-docker-oat`: *Secret text*, the OAT.
   - `dhi-jfrog`: *Username with password*, the Artifactory username and token.
2. **Job**: New Item → *Pipeline* → *Pipeline script from SCM*, pointing at your
   copy of this repository, script path `Jenkinsfile`.
3. **Settings**: edit the `environment` block at the top of the `Jenkinsfile`
   (`DHI_ORG`, `SRC_IMAGE`, `DEST_IMAGE`, `JFROG_HOST`, `JFROG_REPO`; `TAGS` is a
   job parameter). Same names as in the GitHub table above.
4. **Agent**: Linux amd64 with `bash`, `curl`, `jq` and the Docker CLI, and access to
   `docker.io`, `registry.scout.docker.com`, `github.com` (tool download) and your
   Artifactory host. Without GitHub access, put `regctl`, `regsync` and `cosign`
   on the agent's `PATH` and remove the *Install tools* stage.
5. **Run**: *Build with Parameters* → `MODE=mirror` for the first copy. After that
   the hourly schedule runs `MODE=sync`, which refreshes changed tags in `TAGS`.

No PAT is needed. To sync right away when Docker publishes a rebuild, add a Docker
Hub webhook that calls the job through the Generic Webhook Trigger plugin.

## Use the images

```bash
docker login acme.jfrog.io
docker pull acme.jfrog.io/<jfrog-repo>/dhi-node:24
```

```dockerfile
FROM acme.jfrog.io/<jfrog-repo>/dhi-node:24-dev AS build
FROM acme.jfrog.io/<jfrog-repo>/dhi-node:24
```

Name Artifactory in every `FROM`: Docker's `registry-mirrors` setting only
applies to Docker Hub pulls. In production, pin by digest
(`…/dhi-node:24@sha256:…`) and let Renovate or Dependabot bump it. To block other
registries, use [Registry Access Management](https://docs.docker.com/desktop/enterprise/hardened-desktop/registry-access-management/).

Verify Docker's signature on an attestation (DHI signs each attestation, not the
image index):

```bash
regctl artifact list acme.jfrog.io/<jfrog-repo>/dhi-node:24 --platform linux/amd64 \
  --filter-annotation in-toto.io/predicate-type=https://slsa.dev/provenance/v0.2   # prints ...@sha256:<att>
cosign verify --key keys/dhi-latest.pub --insecure-ignore-tlog=true --experimental-oci11 \
  acme.jfrog.io/<jfrog-repo>/dhi-node@sha256:<att>
```

## Run from your machine instead

Install: `brew install regclient cosign jq` and Docker Desktop (other platforms:
the same tools from their releases).

```bash
cp .env.example .env && chmod 600 .env   # fill it in: the same names as the GitHub table above
make login      # log in to Docker Hub, the Scout registry and Artifactory
make inspect    # tags, digests and attestations that will be mirrored
make mirror     # copy image + attestations into Artifactory, by digest
make verify     # check digests, attestations and signatures from Artifactory
make sync-once  # one pass of the continuous sync (make sync: every hour)
```

`.env` is git-ignored.

`make mirror` is the `regctl` command from the Docker docs, once per tag:

```bash
regctl image copy docker.io/<org>/dhi-node@<digest> acme.jfrog.io/<jfrog-repo>/dhi-node:24 \
  --referrers --referrers-src registry.scout.docker.com/<org>/dhi-node \
  --referrers-tgt acme.jfrog.io/<jfrog-repo>/dhi-node --force-recursive
```

## Optional: Docker Scout scans

Only if you scan images with Docker Scout. If you use another scanner (for
example Black Duck), skip this section: **mirroring and verification never use it.**

Docker Scout does not accept organization tokens, so it needs a **personal access
token (PAT)**: Docker Hub → your avatar → **Account settings → Personal access
tokens → Generate new token**, permission **Repo Read-only**
([docs](https://docs.docker.com/security/access-tokens/personal-access-tokens/#create)).
The account must be a member of the organization.

```bash
docker login -u <your-docker-id>        # paste the PAT
IMG=registry://acme.jfrog.io/<jfrog-repo>/dhi-node:24     # registry:// = read from Artifactory
docker scout cves $IMG                  # "✓ VEX statements obtained from attestation"
docker scout attest list $IMG --platform linux/amd64
```

When you build your own images on DHI, build with `--sbom=true --provenance=mode=max`
so Scout can follow the provenance back to the DHI base and apply its VEX
([docs](https://docs.docker.com/dhi/how-to/scan/#build-child-images-with-provenance-attestations)).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `failed to ping registry docker.io: unauthorized` | `DHI_ORG` must be the organization name (not your Docker ID) and `DOCKER_TOKEN` an organization access token. |
| `cannot read attestations from registry.scout.docker.com/…: unauthorized` | The OAT needs **Image Pull** on that `dhi-*` repository. |
| Push rejected / `403` on an existing tag | Give the sync account Delete/Overwrite on the JFrog repository. |
| Attestations missing after mirroring | `JFROG_REPO` must be a Docker repository the sync account can push to. |
| Digest in Artifactory differs from Hub | Docker re-pointed the tag. Run the sync again. |
| `↻ changed upstream since copy` | Docker re-issued an attestation. Run the mirror again. |
| `docker scout` authentication error | Scout needs a Docker ID + PAT, not the OAT. See [Optional: Docker Scout](#optional-docker-scout-scans). |

## Files

| Path | Purpose |
|---|---|
| `.github/workflows/dhi-hub-mirror.yml` | mirror a DHI image into your Docker Hub org (`dhictl`, manual run) |
| `.github/workflows/mirror.yml` | one-off mirror + verify (manual run) |
| `.github/workflows/dhi-jfrog-sync.yml` | hourly sync + verify |
| `Jenkinsfile` | the same, for Jenkins |
| `regsync.yaml` | sync settings (tag allow-list is generated from `TAGS`) |
| `scripts/`, `Makefile` | the same steps for your machine (`make help`) |
| `.env.example` | settings for running from your machine |
| `keys/dhi-latest.pub` | Docker's DHI signing key |
