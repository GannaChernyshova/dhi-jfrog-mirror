#!/usr/bin/env bash
# Log regctl in to the three registries involved, and docker in to Artifactory
# (docker and cosign read docker's credential store). Needs only the organization
# access token (OAT) and the Artifactory token. It never touches your own Docker
# Hub login: Docker Scout scans use a personal token, see README.
. "$(dirname "$0")/lib.sh"
need_source
need regctl "https://github.com/regclient/regclient/releases"

: "${DOCKER_TOKEN:?set DOCKER_TOKEN in .env}"

step "Docker Hub (image) and Scout registry (attestations)"
for reg in docker.io registry.scout.docker.com; do
  printf '%s' "$DOCKER_TOKEN" | regctl registry login -u "$DOCKER_ORG" --pass-stdin "$reg" >/dev/null
  ok "regctl → $reg as $DOCKER_ORG (organization access token)"
done

step "Artifactory ($JFROG_HOST)"
: "${JFROG_USER:?set JFROG_USER in .env}" "${JFROG_TOKEN:?set JFROG_TOKEN in .env}"
printf '%s' "$JFROG_TOKEN" | regctl registry login -u "$JFROG_USER" --pass-stdin "$JFROG_HOST" >/dev/null
ok "regctl → $JFROG_HOST as $JFROG_USER"
if command -v docker >/dev/null; then
  printf '%s' "$JFROG_TOKEN" | docker login -u "$JFROG_USER" --password-stdin "$JFROG_HOST" >/dev/null
  ok "docker → $JFROG_HOST (used by cosign and docker pull)"
fi
