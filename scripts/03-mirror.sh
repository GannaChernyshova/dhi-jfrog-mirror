#!/usr/bin/env bash
# Copy each tag from the Hub mirror to Artifactory together with its signed
# attestations - the regctl command from the Docker docs
# (https://docs.docker.com/dhi/how-to/mirror/), applied to a list of tags.
. "$(dirname "$0")/lib.sh"
need_source
need regctl "https://github.com/regclient/regclient/releases"

step "Mirror  $SRC  →  $DEST"
info "attestations from $ATT_SRC"
for tag in $TAGS; do
  # Resolve the tag first and copy by digest: DHI re-points tags on every CVE
  # rebuild, and this way the copy cannot mix two builds.
  digest=$(regctl manifest head "$SRC:$tag") || die "tag $tag not found in $SRC"
  printf '\n   %s%s:%s%s  %s\n' "$B" "$SRC_IMAGE" "$tag" "$N" "$digest"

  # --referrers      copy the attestations attached to the image (OCI referrers)
  # --referrers-src  ...reading them from the Scout registry, not from docker.io
  # --referrers-tgt  ...and attaching them to the same digests in Artifactory
  # --force-recursive  re-copy even if the tag already exists (picks up new attestations)
  run regctl image copy "$SRC@$digest" "$DEST:$tag" \
    --referrers --referrers-src "$ATT_SRC" --referrers-tgt "$DEST" \
    --force-recursive >/dev/null

  got=$(regctl manifest head "$DEST:$tag")
  [ "$got" = "$digest" ] || die "digest mismatch in Artifactory: $got"
  ok "$DEST:$tag is identical to Docker Hub"
done

printf '\nNext: make verify\n'
