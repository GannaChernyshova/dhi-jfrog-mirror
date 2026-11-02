#!/usr/bin/env bash
# Show what will be mirrored: for each tag, the digest on Docker Hub, its
# platforms, and the signed attestations attached to it in the Scout registry.
. "$(dirname "$0")/lib.sh"
need_source
need regctl "https://github.com/regclient/regclient/releases"
need jq "https://jqlang.org"

step "DHI signing key"
mkdir -p "$(dirname "$DHI_KEY")"
if curl -sf "$DHI_KEY_URL" -o "$DHI_KEY.live"; then
  if [ ! -s "$DHI_KEY" ]; then
    mv "$DHI_KEY.live" "$DHI_KEY"; ok "downloaded $DHI_KEY_URL"
  elif cmp -s "$DHI_KEY" "$DHI_KEY.live"; then
    rm "$DHI_KEY.live"; ok "pinned key matches $DHI_KEY_URL"
  else
    warn "published key differs from keys/dhi-latest.pub - Docker may have rotated it; review keys/dhi-latest.pub.live"
  fi
else
  [ -s "$DHI_KEY" ] || die "cannot download $DHI_KEY_URL and no pinned key"
  warn "cannot reach $DHI_KEY_URL, using pinned key"
fi

step "Source  $SRC"
info "attestations from $ATT_SRC"
for tag in $TAGS; do
  digest=$(regctl manifest head "$SRC:$tag") || die "tag $tag not found in $SRC"
  printf '\n   %s%s:%s%s  %s\n' "$B" "$SRC_IMAGE" "$tag" "$N" "$digest"
  { echo "index $digest"; platforms "$SRC@$digest"; } | while read -r name sdig; do
    list=$(referrers "$SRC@$sdig" "$ATT_SRC" 2>&1) ||
      die "cannot read attestations from $ATT_SRC: ${list##*$'\n'} (run make login; token needs pull on $DOCKER_ORG/$SRC_IMAGE)"
    [ -n "$list" ] || { info "$(printf '%-14s' "$name") (none)"; continue; }
    while read -r r; do
      info "$(printf '%-14s %-29s %s' "$name" "$(label "$(jq -r .type <<<"$r")")" "$(jq -r .digest <<<"$r" | cut -c1-19)")"
      name=""
    done <<<"$list"
  done
done
