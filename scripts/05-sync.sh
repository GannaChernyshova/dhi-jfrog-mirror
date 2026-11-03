#!/usr/bin/env bash
# Sync the tags in TAGS from Docker Hub to Artifactory with regsync.
#   bash scripts/05-sync.sh          one pass (default)
#   bash scripts/05-sync.sh server   keep running, re-check every `interval`
#
# regsync tag filters are regular expressions and cannot read environment
# variables, so this script writes the allow-list from TAGS into a temporary
# copy of regsync.yaml (at the "@TAGS@" marker) and runs regsync on that.
. "$(dirname "$0")/lib.sh"
need regsync "https://github.com/regclient/regclient/releases"
need_source
: "${DOCKER_TOKEN:?set DOCKER_TOKEN in .env}" "${JFROG_USER:?set JFROG_USER in .env}" "${JFROG_TOKEN:?set JFROG_TOKEN in .env}"
[ -n "${TAGS// /}" ] || die "TAGS is empty: a DHI repository has thousands of tags, list the ones to sync"
export DHI_ORG SRC_IMAGE DEST_IMAGE JFROG_HOST JFROG_REPO DOCKER_TOKEN JFROG_USER JFROG_TOKEN

cfg=$(mktemp)
trap 'rm -f "$cfg"' EXIT
awk -v tags="$TAGS" '
  /# @TAGS@/ {
    n = split(tags, t, " ")
    for (i = 1; i <= n; i++) { g = t[i]; gsub(/\./, "\\.", g); printf "        - '\''^%s$'\''\n", g }
    next
  }
  { print }' "$ROOT/regsync.yaml" > "$cfg"

step "Sync  $SRC  →  $DEST   (tags: $TAGS)"
run regsync "${1:-once}" -c "$cfg"
