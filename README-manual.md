# Manual mirror with `regctl`

Copy a DHI image from your Docker Hub organization into Artifactory, together
with its signed attestations, using only `regctl` commands. The steps follow
Docker's
[Example mirroring with `regctl`](https://docs.docker.com/dhi/how-to/mirror/#example-mirroring-with-regctl);
step 5 adds a signature check. `scripts/03-mirror.sh` runs the same copy command
in a loop.

Before you start:

- `dhi-<name>` must already exist in your Docker Hub org (Hub UI → **Use this
  image → Mirror repository**, or `dhictl mirror start dhi/devcontainers-base,$DOCKER_ORG/dhi-devcontainers-base`).
  `regctl` cannot copy straight from the DHI catalog.
- Install [`regctl`](https://github.com/regclient/regclient/releases). For step 5
  also install [`cosign`](https://github.com/sigstore/cosign/releases) and `jq`.

## 1. Set environment variables

```bash
export DOCKER_ORG="YOUR_DOCKER_ORG"
export DOCKER_OAT="YOUR_DOCKER_OAT"
export DEST_REG="acme.jfrog.io"
export DEST_REPO="YOUR_JFROG_REPO/dhi-devcontainers-base"
export DEST_REG_USERNAME="YOUR_ARTIFACTORY_USERNAME"
export DEST_REG_TOKEN="YOUR_ARTIFACTORY_TOKEN"
export SRC_REPO="docker.io/${DOCKER_ORG}/dhi-devcontainers-base"
export SRC_ATT_REPO="registry.scout.docker.com/${DOCKER_ORG}/dhi-devcontainers-base"
export TAG="2-debian13-dev"
```

- `DOCKER_OAT` is an organization access token. Its username is the
  **organization name**, not your Docker ID. See the main
  [README](README.md#1-create-two-tokens) for the scopes.
- `DEST_REG` is the Artifactory hostname with no `https://`. `DEST_REPO` is
  `<jfrog-repo>/<image>`.

> Exporting credentials on the command line exposes them in your shell history
> and process list. In production, read them from a restricted file, an env file
> loaded at runtime, or a secrets manager.

## 2. Log in

```bash
echo $DOCKER_OAT | regctl registry login -u "$DOCKER_ORG" --pass-stdin docker.io
echo $DOCKER_OAT | regctl registry login -u "$DOCKER_ORG" --pass-stdin registry.scout.docker.com
echo $DEST_REG_TOKEN | regctl registry login -u "$DEST_REG_USERNAME" --pass-stdin "$DEST_REG"
```

The three logins are Docker Hub (the image), the Scout registry (the
attestations) and Artifactory.

## 3. Mirror the image and attestations

```bash
regctl image copy \
     "${SRC_REPO}:${TAG}" \
     "${DEST_REG}/${DEST_REPO}:${TAG}" \
     --referrers \
     --referrers-src "${SRC_ATT_REPO}" \
     --referrers-tgt "${DEST_REG}/${DEST_REPO}" \
     --force-recursive
```

| Flag | Meaning |
|---|---|
| `--referrers` | copy the artifacts attached to the image (SBOM, provenance, VEX, scans) **and the cosign signatures attached to them** |
| `--referrers-src` | read them from the Scout registry, not from docker.io |
| `--referrers-tgt` | attach them to the same digests in Artifactory |
| `--force-recursive` | re-copy even if the tag already exists, which picks up new attestations |

Without `--referrers` only the image is copied, with no attestations and no
signatures.

## 4. Verify that artifacts were preserved

Get the digest for a tag and platform, for example `linux/amd64`:

```bash
DIGEST="$(regctl manifest head "${DEST_REG}/${DEST_REPO}:${TAG}" --platform linux/amd64)"
```

List the attached artifacts (SBOM, provenance, VEX, vulnerability reports):

```bash
regctl artifact list "${DEST_REG}/${DEST_REPO}@${DIGEST}"
```

## 5. Verify the signatures from Artifactory

Docker signs each attestation, not the image index. The signature is attached to
the attestation and was copied in step 3, so it can be checked from Artifactory
alone with Docker's public DHI key
([docs](https://docs.docker.com/dhi/how-to/verify/)).

`cosign` reads the same credentials as `docker login`, so log in once:

```bash
echo $DEST_REG_TOKEN | cosign login "$DEST_REG" -u "$DEST_REG_USERNAME" --password-stdin
```

`$DIGEST` is the platform digest from step 4. Get the digests of its
attestations (SBOM, provenance, VEX and so on):

```bash
ATTS=$(regctl artifact list "${DEST_REG}/${DEST_REPO}@${DIGEST}" \
    --format '{{json .Manifest}}' |
  jq -r '.manifests[] | select(.annotations["in-toto.io/predicate-type"] != null) | .digest')
echo "$ATTS"
```

Verify the first one:

```bash
ATT=$(echo "$ATTS" | head -n1)
cosign verify \
    "${DEST_REG}/${DEST_REPO}@${ATT}" \
    --key https://registry.scout.docker.com/keyring/dhi/latest.pub \
    --insecure-ignore-tlog=true \
    --experimental-oci11
```

Or verify all of them in one go:

```bash
echo "$ATTS" | while read -r ATT; do
  printf '%s  ' "$ATT"
  cosign verify "${DEST_REG}/${DEST_REPO}@${ATT}" \
    --key https://registry.scout.docker.com/keyring/dhi/latest.pub \
    --insecure-ignore-tlog=true --experimental-oci11 >/dev/null 2>&1 \
    && echo "signature OK" || echo "NO VALID SIGNATURE"
done
```

This reads one digest per line, so it works in both bash and zsh. (A
`for ATT in $ATTS` loop does not: zsh does not split the variable, so `cosign`
gets all digests as one reference.)

- `--insecure-ignore-tlog=true` is needed because DHI attestations are not
  recorded in the public Rekor log. The signature is still checked against
  Docker's key.
- `--experimental-oci11` makes `cosign` find signatures stored as OCI referrers.
  Newer `cosign` versions print "flag has been deprecated" because referrers
  become the default; the command still works, and you can drop the flag once
  your version no longer needs it.
- The "skipping tlog verification" warning is expected with
  `--insecure-ignore-tlog=true`.
- A copy of the key is in `keys/dhi-latest.pub`; pass `--key keys/dhi-latest.pub`
  to avoid fetching it.
- `scripts/04-verify.sh` does the full check: digests match Hub, every Scout
  attestation is present, every signature verifies.

## Several tags

```bash
for TAG in 2-debian13-dev; do
  regctl image copy \
    "${SRC_REPO}:${TAG}" \
    "${DEST_REG}/${DEST_REPO}:${TAG}" \
    --referrers \
    --referrers-src "${SRC_ATT_REPO}" \
    --referrers-tgt "${DEST_REG}/${DEST_REPO}" \
    --force-recursive
done
```

## Notes

- **Artifactory permissions:** the account needs Read, Deploy/Cache and
  Delete/Overwrite on the repository, because tags are overwritten on each rebuild.
- **Referrers storage:** Artifactory has no OCI Referrers API. The attestations and
  signatures appear as `sha256-<digest>` tags in the repository. `regctl`, `cosign`
  and Scout read them from there.
- **Rebuilds:** DHI re-points tags on every CVE rebuild, so re-run step 3 to pick
  up a new build. For continuous sync use `regsync` or the scheduled workflow in the
  main [README](README.md#keep-it-up-to-date).
