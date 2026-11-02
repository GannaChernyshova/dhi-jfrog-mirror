#!/usr/bin/env bash
# Prove the mirror from Artifactory alone, for the local repo the sync writes
# to and - if there is one - for the virtual repo developers pull through:
#   1. each tag's digest in Artifactory == Docker Hub
#   2. every attestation in Scout (and the signature on it) is in Artifactory
#   3. every signature verifies with cosign against Docker's DHI key
. "$(dirname "$0")/lib.sh"
need_source
need regctl "https://github.com/regclient/regclient/releases"
need jq "https://jqlang.org"
need cosign "https://github.com/sigstore/cosign/releases"
[ -s "$DHI_KEY" ] || die "no DHI key at keys/dhi-latest.pub - run make inspect"

present=0 missing=0 changed=0 verified=0 bad=0

# True if <subject> still has referrer <digest> in Scout on three fresh reads.
source_still_lists() {
  local i
  for i in 1 2 3; do
    referrers "$ATT_SRC@$1" | jq -r .digest | grep -qx "$2" || return 1
  done
}

# check <label> <subject digest>: every referrer of the subject in Scout must be
# in TARGET too; signatures must verify; attestations are checked for their own
# signature (one level of nesting).
check() {
  local name=$1 subject=$2 r rdig type status actual in_target
  actual=$(referrers "$TARGET@$subject" | jq -r .digest)
  while read -r r; do
    [ -n "$r" ] || continue
    rdig=$(jq -r .digest <<<"$r"); type=$(jq -r .type <<<"$r")
    in_target=true
    if ! grep -qx "$rdig" <<<"$actual"; then
      in_target=false
      # Not in Artifactory. If the source itself no longer lists it on a
      # re-read, Docker re-issued the attestation since the copy (DHI updates
      # VEX often): the next make mirror / regsync pass picks it up.
      if ! source_still_lists "$subject" "$rdig"; then
        changed=$((changed + 1)); status="${Y}↻ changed upstream since copy${N}"
      else
        missing=$((missing + 1)); status="${R}✘ missing${N}"
      fi
    elif [ "$type" != "$SIG_TYPE" ]; then
      present=$((present + 1)); status="${G}✔ present${N}"
    elif cosign verify "${COSIGN_FLAGS[@]}" "$TARGET@$subject" >/dev/null 2>&1; then
      present=$((present + 1)); verified=$((verified + 1)); status="${G}✔ present, signature verified${N}"
    else
      present=$((present + 1)); bad=$((bad + 1)); status="${R}✘ present, signature does NOT verify${N}"
    fi
    printf '   %-14s %-29s %s  %s\n' "$name" "$(label "$type")" "${rdig:7:12}" "$status"
    name=""
    # An attestation carries its own signature: check it too (when it is there).
    if [ "$type" != "$SIG_TYPE" ] && $in_target; then check "  └ signed by" "$rdig"; fi
  done < <(referrers "$ATT_SRC@$subject" 2>/dev/null || true)
}

targets=("$DEST")
[ "$PULL" != "$DEST" ] && targets+=("$PULL")

for TARGET in "${targets[@]}"; do
  step "Verify  $TARGET"
  for tag in $TAGS; do
    src=$(regctl manifest head "$SRC:$tag")
    dst=$(regctl manifest head "$TARGET:$tag" 2>/dev/null || echo "not found")
    printf '\n   %s%s:%s%s\n' "$B" "$DEST_IMAGE" "$tag" "$N"
    if [ "$src" != "$dst" ]; then
      printf '   %s✘%s digest  Hub %s  Artifactory %s\n' "$R" "$N" "$src" "$dst"
      missing=$((missing + 1)); continue
    fi
    ok "digest matches Docker Hub  $dst"
    check "index" "$src"
    while read -r plat pdig; do check "$plat" "$pdig"; done < <(platforms "$SRC@$src")
  done
done

step "Summary"
if regctl tag ls "$DEST" | grep -q '^sha256-'; then
  info "Artifactory stores referrers as sha256-<digest> tags (no OCI Referrers API); regctl, cosign and Scout read these"
fi
info "attestations/signatures present: $present, missing: $missing"
[ "$changed" -gt 0 ] && warn "$changed attestation(s) were re-issued by Docker since the copy - run make mirror (or regsync) again"
info "signatures verified with Docker's DHI key: $verified, failed: $bad"
if [ $((missing + bad)) -eq 0 ]; then
  ok "image and its signed attestations are in Artifactory"
else
  die "incomplete - re-run make mirror and check the warnings"
fi
