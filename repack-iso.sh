#!/usr/bin/env bash
# Repack an installer ISO with extra kernel arguments, and optionally a file
# embedded in its root.
#
#   ./repack-iso.sh <src.iso> <dest.iso> "<kernel args>" [file-to-embed]
#
# WHY THIS EXISTS
# Two of the three provisioner families cannot be driven by media alone:
#
#   * Ubuntu/Subiquity ignores CIDATA unless `autoinstall` is on the kernel
#     command line, and will otherwise stop at an interactive prompt asking a
#     human to confirm a destructive install.
#   * Debian/d-i has no volume-label discovery at all; the preseed must be named
#     on the kernel command line.
#
# Both were previously done by hand — build/<target>/installer-*.iso existed on
# this Mac with nothing in the repo to recreate it, so a fresh CI runner could
# not reproduce the build. This script is that missing step.
#
# Patches BOTH bootloaders: isolinux/*.cfg for BIOS and boot/grub/grub.cfg for
# EFI. Only patching one is a classic way to get an ISO that automates under one
# firmware and silently waits for a human under the other.
set -euo pipefail

SRC="${1:?usage: repack-iso.sh <src.iso> <dest.iso> \"<kernel args>\" [file-to-embed]}"
DEST="${2:?missing dest.iso}"
KARGS="${3:?missing kernel args}"
EMBED="${4:-}"

command -v xorriso >/dev/null || { echo "xorriso is required (brew install xorriso)" >&2; exit 1; }
[ -f "$SRC" ] || { echo "no such ISO: $SRC" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> extracting $(basename "$SRC")"
xorriso -osirrox on -indev "$SRC" -extract / "$WORK/iso" >/dev/null 2>&1
chmod -R u+w "$WORK/iso"

if [ -n "$EMBED" ]; then
  [ -f "$EMBED" ] || { echo "no such file to embed: $EMBED" >&2; exit 1; }
  cp -f "$EMBED" "$WORK/iso/$(basename "$EMBED")"
  echo "    embedded $(basename "$EMBED")"
fi

echo "==> adding kernel args: $KARGS"
patched=0
# EFI path.
for cfg in "$WORK/iso/boot/grub/grub.cfg" "$WORK/iso/EFI/BOOT/grub.cfg"; do
  [ -f "$cfg" ] || continue
  # Append to every `linux` line that boots a kernel, leaving other lines alone.
  sed -i '' -E "s|^([[:space:]]*linux[[:space:]]+/[^[:space:]]+.*)$|\1 ${KARGS}|" "$cfg" 2>/dev/null \
    || sed -i -E "s|^([[:space:]]*linux[[:space:]]+/[^[:space:]]+.*)$|\1 ${KARGS}|" "$cfg"
  patched=$((patched+1)); echo "    patched ${cfg#$WORK/iso/}"
done
# BIOS path.
for cfg in "$WORK/iso"/isolinux/*.cfg "$WORK/iso"/isolinux/*/*.cfg; do
  [ -f "$cfg" ] || continue
  grep -q '^[[:space:]]*append' "$cfg" || continue
  sed -i '' -E "s|^([[:space:]]*append[[:space:]]+.*)$|\1 ${KARGS}|" "$cfg" 2>/dev/null \
    || sed -i -E "s|^([[:space:]]*append[[:space:]]+.*)$|\1 ${KARGS}|" "$cfg"
  patched=$((patched+1)); echo "    patched ${cfg#$WORK/iso/}"
done
[ "$patched" -gt 0 ] || { echo "ERROR: no bootloader config patched — the ISO would boot interactively" >&2; exit 1; }

echo "==> writing $(basename "$DEST")"
install -d "$(dirname "$DEST")"
# -boot_image any replay reuses the source ISO's boot records, which keeps the
# result bootable under BIOS and EFI without hand-specifying El Torito options.
xorriso -as mkisofs \
  -r -V "$(xorriso -indev "$SRC" -pvd_info 2>/dev/null | sed -n 's/.*Volume Id *: *//p' | head -1 | cut -c1-32)" \
  -o "$DEST" \
  -boot_image any replay \
  "$WORK/iso" >/dev/null 2>&1 || {
    echo "    replay failed, retrying without boot image replay (EFI-only boot)"
    xorriso -as mkisofs -r -o "$DEST" "$WORK/iso" >/dev/null 2>&1
  }

[ -f "$DEST" ] || { echo "ERROR: $DEST not produced" >&2; exit 1; }
echo "==> done: $DEST ($(ls -lh "$DEST" | awk '{print $5}'))"

# Verify the arguments actually landed — a repack that silently fails to patch
# produces an ISO that waits for a human, and the build then dies 45 minutes
# later with a misleading SSH timeout.
echo "==> verifying"
hits=$(xorriso -osirrox on -indev "$DEST" -extract /boot/grub/grub.cfg "$WORK/check.cfg" >/dev/null 2>&1 \
       && grep -c -- "${KARGS%% *}" "$WORK/check.cfg" 2>/dev/null || echo 0)
if [ "${hits:-0}" -gt 0 ]; then
  echo "    grub.cfg carries the arguments ($hits line(s))"
else
  echo "    WARNING: could not confirm arguments in grub.cfg — check before building"
fi
