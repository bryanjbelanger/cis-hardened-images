#!/usr/bin/env bash
# Stage SCAP datastreams that the target distro does NOT package for itself.
#
# WHY THIS EXISTS
# EL targets install scap-security-guide from their own repos and need nothing
# here. Debian-family targets cannot:
#
#   * Ubuntu 22.04 (jammy) has no ssg content at all. The datastream comes from
#     the NOBLE ssg-debderived deb, which carries both ssg-ubuntu2204-ds.xml and
#     ssg-ubuntu2404-ds.xml.
#   * Debian 12 (bookworm) packages SSG 0.1.65, and the CIS Debian 12 content
#     only appeared upstream in 0.1.78 — verified by bisecting the tags. Even
#     trixie (0.1.76) predates it. So Debian's own archive cannot supply it at
#     any release; the datastream comes from SID's ssg-debian 0.1.80.
#
# Both are ~2.5MB debs rather than the 167MB upstream release archive, and both
# are extracted into ONE directory so build-packer.sh finds any of them by name.
set -euo pipefail
cd "$(dirname "$0")"

DEST="build/ssgx/usr/share/xml/scap/ssg/content"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
install -d "$DEST"

fetch_deb() {
  local name=$1 url=$2
  echo "==> $name"
  if ! curl -fsSL --max-time 900 -o "$TMP/$name.deb" "$url"; then
    echo "    FAILED to download $url" >&2
    return 1
  fi
  echo "    $(ls -lh "$TMP/$name.deb" | awk '{print $5}')"
  ( cd "$TMP" && ar x "$name.deb" && tar xf data.tar.* )
  local n=0
  for ds in "$TMP"/usr/share/xml/scap/ssg/content/*-ds.xml; do
    [ -f "$ds" ] || continue
    cp -f "$ds" "$DEST/" && n=$((n+1))
  done
  rm -rf "$TMP/usr" "$TMP/data.tar."* "$TMP/control.tar."* "$TMP/debian-binary" 2>/dev/null || true
  echo "    staged $n datastream(s)"
}

# Ubuntu 22.04 + 24.04, from noble.
fetch_deb ssg-debderived \
  "http://archive.ubuntu.com/ubuntu/pool/universe/s/scap-security-guide/ssg-debderived_0.1.73-1_all.deb" \
  || echo "    (ubuntu datastreams may already be staged; continuing)"

# Debian 11/12/13, from sid — the only Debian archive with CIS Debian content.
fetch_deb ssg-debian \
  "http://deb.debian.org/debian/pool/main/s/scap-security-guide/ssg-debian_0.1.80-1_all.deb"

echo "==> staged datastreams"
for f in "$DEST"/*-ds.xml; do
  [ -f "$f" ] || continue
  printf '    %-28s %s\n' "$(basename "$f")" "$(ls -lh "$f" | awk '{print $5}')"
done

# Verify rather than assume: a datastream that parses but lacks the profile the
# target asks for fails 20 minutes into a build instead of here.
echo "==> profile check"
for f in "$DEST"/*-ds.xml; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  p=$(grep -oE 'content_profile_(cis[a-z0-9_]*|stig)' "$f" 2>/dev/null | sed 's/content_profile_//' | sort -u | tr '\n' ' ')
  printf '    %-28s %s\n' "$b" "${p:-NONE}"
done
