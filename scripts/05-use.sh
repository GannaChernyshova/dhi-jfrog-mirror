#!/usr/bin/env bash
# Use the mirrored image the way a developer would, through the consumer URL
# in Artifactory: pull and run it, export its SBOM and VEX, scan it with
# Docker Scout (which applies DHI's VEX from the attestation in Artifactory).
. "$(dirname "$0")/lib.sh"
need regctl "https://github.com/regclient/regclient/releases"
need jq "https://jqlang.org"
need docker "https://docs.docker.com/get-docker/"

tag="${1:-${TAGS%% *}}"
mkdir -p "$OUT"

step "Run $PULL:$tag ($PLATFORM)"
run docker pull -q --platform "$PLATFORM" "$PULL:$tag"
run docker run --rm --platform "$PLATFORM" "$PULL:$tag" node --version

# Save one attestation's predicate (the bare SBOM / VEX document) from
# Artifactory, e.g. for audit or to feed other tools.
export_predicate() { # <predicate-type-prefix> <file>
  local pdig rdig
  pdig=$(regctl manifest head "$PULL:$tag" --platform "$PLATFORM")
  rdig=$(referrer_of_type "$PULL@$pdig" "$1")
  [ -n "$rdig" ] || { warn "no $1 attestation on $PLATFORM"; return 1; }
  regctl artifact get "$PULL@$rdig" |
    jq 'if .payload then (.payload | @base64d | fromjson) else . end | .predicate' >"$OUT/$2"
  ok "$OUT/$2  (from $PULL@${rdig:0:19})"
}

step "Export attestations from Artifactory"
export_predicate "https://cyclonedx.org/bom" "sbom.cdx.json" &&
  info "$(jq '.components | length' "$OUT/sbom.cdx.json") components in SBOM"
export_predicate "https://openvex.dev/" "vex.json" &&
  info "$(jq '.statements | length' "$OUT/vex.json") VEX statements"

step "Scan with Docker Scout"
# registry:// makes Scout read the image and its attestations from Artifactory
# (not from a local image or Docker Hub). Expect "VEX statements obtained from
# attestation" in the output: the VEX copied by make mirror is being applied.
docker scout version >/dev/null 2>&1 || { warn "docker scout not installed - https://github.com/docker/scout-cli"; exit 0; }
run docker scout attest list "registry://$PULL:$tag" --platform "$PLATFORM" ||
  { warn "docker scout needs docker login with a Docker ID + PAT (make login)"; exit 0; }
printf '\n'
run docker scout cves "registry://$PULL:$tag" --platform "$PLATFORM"
