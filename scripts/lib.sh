#!/usr/bin/env bash
# Shared config and helpers, sourced by every script in scripts/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/.env"
  set +a
fi

DOCKER_ORG="${DOCKER_ORG:-}"
SRC_IMAGE="${SRC_IMAGE:-dhi-node}"
DEST_IMAGE="${DEST_IMAGE:-$SRC_IMAGE}"
TAGS="${TAGS:-24}"
case "$(uname -m)" in arm64|aarch64) host_arch=arm64 ;; *) host_arch=amd64 ;; esac
PLATFORM="${PLATFORM:-linux/$host_arch}"

# Source: the DHI repo mirrored into your Hub org. The image is on docker.io;
# its signed attestations (SBOM, provenance, VEX, ...) are in the Scout
# registry under the same org/repo name.
SRC="docker.io/${DOCKER_ORG}/${SRC_IMAGE}"
ATT_SRC="registry.scout.docker.com/${DOCKER_ORG}/${SRC_IMAGE}"

# Destination in Artifactory (repository-path method: <host>/<repo-key>/<image>).
#   DEST  the local repo the sync writes to
#   PULL  what developers and CI use: the virtual repo if there is one
#   APPS  where application images are pushed
: "${JFROG_HOST:?set JFROG_HOST in .env (e.g. acme.jfrog.io)}"
JFROG_REPO="${JFROG_REPO:-dhi-local}"
JFROG_VIRTUAL="${JFROG_VIRTUAL:-}"
JFROG_APPS_REPO="${JFROG_APPS_REPO:-}"
DEST="${JFROG_HOST}/${JFROG_REPO}/${DEST_IMAGE}"
PULL="${JFROG_HOST}/${JFROG_VIRTUAL:-$JFROG_REPO}/${DEST_IMAGE}"
APPS="${JFROG_HOST}/${JFROG_VIRTUAL:-${JFROG_APPS_REPO:-$JFROG_REPO}}"

DHI_KEY="$ROOT/keys/dhi-latest.pub"
DHI_KEY_URL="https://registry.scout.docker.com/keyring/dhi/latest.pub"
OUT="$ROOT/out"

# DHI signatures are OCI referrers (--experimental-oci11) and are not in the
# public Rekor log (--insecure-ignore-tlog), as documented by Docker.
COSIGN_FLAGS=(--key "$DHI_KEY" --insecure-ignore-tlog=true --experimental-oci11)

if [ -t 1 ]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' D=$'\e[2m' N=$'\e[0m'; else B='' G='' Y='' R='' D='' N=''; fi
step() { printf '\n%s━━ %s%s\n' "$B" "$*" "$N"; }
info() { printf '   %s\n' "$*"; }
ok()   { printf '   %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '   %s⚠%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '   %s✘ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
run()  { printf '   %s$ %s%s\n' "$D" "$*" "$N" >&2; "$@"; }

need() { type -P "$1" >/dev/null 2>&1 || die "missing tool: $1 ($2)"; }

# regctl warns on every call when docker's config.json has a different user
# for docker.io than regctl's own config (expected here: Scout uses a PAT,
# the sync an OAT). Only errors are useful.
regctl() { command regctl -v error "$@"; }
need_source() { [ -n "$DOCKER_ORG" ] || die "set DOCKER_ORG in .env (your Docker Hub org that holds the DHI mirror)"; }

# Platform manifests of an index as "os/arch digest" lines.
platforms() {
  regctl manifest get "$1" --format raw-body |
    jq -r '.manifests // [] | .[] | select(.platform.os != "unknown")
           | "\(.platform.os)/\(.platform.architecture) \(.digest)"'
}

# Referrers of <ref> as JSON lines {digest, type}. The optional second argument
# reads them from another repository (the Scout registry).
referrers() {
  local args=("$1")
  [ -n "${2:-}" ] && args+=(--external "$2")
  regctl artifact list "${args[@]}" --format '{{json .Manifest}}' |
    jq -c '.manifests // [] | .[] | {digest, type: (.annotations["in-toto.io/predicate-type"] // .artifactType // "unknown")}'
}

# Digest of the first referrer of <ref> whose type starts with <prefix>.
referrer_of_type() {
  referrers "$1" | jq -r --arg p "$2" 'select(.type | startswith($p)) | .digest' | head -n1
}

# Verify Docker's signature on an attestation of <image>@<platform digest>, as in
# https://docs.docker.com/dhi/how-to/verify/ : DHI signs each attestation (the
# image index itself carries no signature for images mirrored via Docker Hub).
verify_attestation() { # <repo> <platform digest> <predicate type prefix>
  local att
  att=$(referrer_of_type "$1@$2" "$3")
  [ -n "$att" ] && cosign verify "${COSIGN_FLAGS[@]}" "$1@$att" >/dev/null 2>&1
}

SIG_TYPE="application/vnd.dev.cosign.artifact.sig.v1+json"

# Short, human label for a referrer type.
label() {
  case "$1" in
    "$SIG_TYPE")                               echo "cosign signature" ;;
    https://cyclonedx.org/bom*)                echo "SBOM (CycloneDX)" ;;
    https://spdx.dev/Document*)                echo "SBOM (SPDX)" ;;
    https://scout.docker.com/sbom*)            echo "SBOM (Scout)" ;;
    https://openvex.dev/*)                     echo "VEX (OpenVEX)" ;;
    https://slsa.dev/provenance*)              echo "SLSA provenance" ;;
    https://slsa.dev/verification_summary*)    echo "SLSA verification summary" ;;
    https://scout.docker.com/provenance*)      echo "Provenance (Scout)" ;;
    https://scout.docker.com/vulnerabilities*) echo "Vulnerability scan" ;;
    https://in-toto.io/attestation/vulns*)     echo "Vulnerability scan (in-toto)" ;;
    https://scout.docker.com/virus*)           echo "Virus scan" ;;
    https://scout.docker.com/secrets*)         echo "Secrets scan" ;;
    https://scout.docker.com/tests*)           echo "Test results" ;;
    https://docker.com/dhi/changelog*)         echo "DHI changelog" ;;
    https://docker.com/dhi/source*)            echo "Source" ;;
    *)                                         echo "$1" ;;
  esac
}
