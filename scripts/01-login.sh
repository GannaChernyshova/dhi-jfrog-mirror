#!/usr/bin/env bash
# Log regctl in to the three registries involved, and docker in to Artifactory
# (docker and cosign read docker's credential store).
. "$(dirname "$0")/lib.sh"
need_source
need regctl "https://github.com/regclient/regclient/releases"

: "${DOCKER_TOKEN:?set DOCKER_TOKEN in .env}"

step "Docker Hub (image) and Scout registry (attestations)"
for reg in docker.io registry.scout.docker.com; do
  printf '%s' "$DOCKER_TOKEN" | regctl registry login -u "$DOCKER_ORG" --pass-stdin "$reg" >/dev/null
  ok "regctl → $reg as $DOCKER_ORG (organization access token)"
done

step "Docker Scout (docker login docker.io)"
# Scout signs in as a user: organization access tokens are rejected, so use a
# Docker ID + personal access token here (SCOUT_*), defaulting to DOCKER_*.
if command -v docker >/dev/null; then
  if printf '%s' "${SCOUT_TOKEN:-$DOCKER_TOKEN}" |
      docker login -u "${SCOUT_USERNAME:-$DOCKER_ORG}" --password-stdin >/dev/null 2>&1; then
    ok "docker → docker.io as ${SCOUT_USERNAME:-$DOCKER_ORG}"
  else
    warn "docker login docker.io failed - set SCOUT_USERNAME/SCOUT_TOKEN (Docker ID + PAT) for docker scout"
  fi
fi

step "Artifactory ($JFROG_HOST)"
: "${JFROG_USER:?set JFROG_USER in .env}" "${JFROG_TOKEN:?set JFROG_TOKEN in .env}"
printf '%s' "$JFROG_TOKEN" | regctl registry login -u "$JFROG_USER" --pass-stdin "$JFROG_HOST" >/dev/null
ok "regctl → $JFROG_HOST as $JFROG_USER"
if command -v docker >/dev/null; then
  printf '%s' "$JFROG_TOKEN" | docker login -u "$JFROG_USER" --password-stdin "$JFROG_HOST" >/dev/null
  ok "docker → $JFROG_HOST (used by cosign and docker pull)"
fi
