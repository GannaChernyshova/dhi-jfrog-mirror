#!/usr/bin/env bash
# Developer / CI flow: build an application on the DHI image from Artifactory.
#
#   1. verify the base image signature from Artifactory (supply-chain gate)
#   2. pin the base to its current digest
#   3. build examples/app FROM it
#        default    load into the local image store and run it
#        PUSH=true  push to Artifactory with SBOM + max provenance, which Docker
#                   Scout follows back to the DHI base to apply its VEX
. "$(dirname "$0")/lib.sh"
need regctl "https://github.com/regclient/regclient/releases"
need cosign "https://github.com/sigstore/cosign/releases"
need docker "https://docs.docker.com/get-docker/"
[ -s "$DHI_KEY" ] || die "no DHI key at keys/dhi-latest.pub - run make inspect"

APP_NAME="${APP_NAME:-hello-dhi}"
APP_TAG="${APP_TAG:-1.0.0}"
NODE_TAG="${NODE_TAG:-24}"
NODE_DEV_TAG="${NODE_DEV_TAG:-${NODE_TAG}-dev}"
APP_IMAGE="${APPS}/${APP_NAME}:${APP_TAG}"

step "Gate: verify the DHI base images from Artifactory"
# Each DHI attestation is signed by Docker; checking the SLSA provenance
# attestation for our platform proves the base is Docker's build.
for t in "$NODE_TAG" "$NODE_DEV_TAG"; do
  pdig=$(regctl manifest head "$PULL:$t" --platform "$PLATFORM") || die "$PULL:$t not found"
  verify_attestation "$PULL" "$pdig" "https://slsa.dev/provenance" ||
    die "$PULL:$t ($PLATFORM): no DHI-signed provenance in Artifactory - not building on it"
  ok "$PULL:$t  provenance signed by Docker (DHI key)"
done

step "Pin base images to digests"
run_digest=$(regctl manifest head "$PULL:$NODE_TAG")
dev_digest=$(regctl manifest head "$PULL:$NODE_DEV_TAG")
info "$NODE_TAG      → $run_digest"
info "$NODE_DEV_TAG  → $dev_digest"

build=(docker buildx build "$ROOT/examples/app" --progress "${BUILD_PROGRESS:-quiet}"
  --build-arg "BASE_IMAGE=$PULL"
  --build-arg "NODE_TAG=$NODE_TAG@$run_digest"
  --build-arg "NODE_DEV_TAG=$NODE_DEV_TAG@$dev_digest"
  --label "org.opencontainers.image.base.name=$PULL:$NODE_TAG"
  --label "org.opencontainers.image.base.digest=$run_digest"
  --tag "$APP_IMAGE")

if [ "${PUSH:-false}" = true ]; then
  step "Build and push $APP_IMAGE (SBOM + max provenance)"
  run "${build[@]}" --platform "${APP_PLATFORMS:-linux/amd64,linux/arm64}" \
    --sbom=true --provenance=mode=max --push
  ok "pushed $APP_IMAGE"
  info "scan: docker scout cves registry://$APP_IMAGE"
  exit 0
fi

step "Build $APP_IMAGE and run it locally"
run "${build[@]}" --platform "$PLATFORM" --load
cid=$(docker run -d --rm -p 127.0.0.1::3000 "$APP_IMAGE")
trap 'docker rm -f "$cid" >/dev/null 2>&1' EXIT
port=$(docker port "$cid" 3000/tcp | head -n1 | sed 's/.*://')
for _ in 1 2 3 4 5 6 7 8 9 10; do
  resp=$(curl -sf "http://127.0.0.1:$port" 2>/dev/null) && break
  sleep 1
done
[ -n "${resp:-}" ] || die "app did not answer on port $port"
ok "app answered: $resp"
info "user: $(docker inspect -f '{{.Config.User}}' "$APP_IMAGE")  (non-root, from the DHI base)"
