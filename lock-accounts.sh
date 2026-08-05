#!/usr/bin/env bash
# The LAST root action before export. Split out from seal.sh deliberately:
# locking root kills MCP guest operations instantly, so anything that needs
# verifying must be verified BEFORE this runs. Do not merge these back together
# — that made a silently-failed AIDE baseline indistinguishable from success.
#
# Run only after seal.sh's log has been retrieved and checked.
set -u
# Deliberately NOT `set -e`, and callers must not impose it either: Packer runs
# provisioner scripts with `bash -eux`, and several commands here can return
# non-zero harmlessly (locking an account that is already locked, chage on a
# system account). seal.sh has the same note. Each step is checked explicitly.
set +e
# PUBLISHED DEFAULT PASSWORD.
# The build password lives in local-creds.env and is never published, so leaving
# it in place would ship an image nobody can log into: root is locked below and
# builder's password would be both unknown and expired. Set a documented default
# instead, expired immediately so the first login MUST change it. This is the
# same model Vagrant boxes use.
: "${DEFAULT_PASSWORD:=cis-hardened}"
echo "[lock] setting documented default password for builder"
# Set it as a PRE-HASHED value. Plain `chpasswd` runs the password through PAM,
# and by this point CIS remediation has enabled pwquality — which rejects the
# documented default and left the image with NO usable credentials. Hashing here
# bypasses the quality check deliberately: the password is public by design and
# force-expired below, so its strength is irrelevant; being able to log in at
# all is not.
_hash=""
if command -v openssl >/dev/null 2>&1; then
  _hash=$(openssl passwd -6 "${DEFAULT_PASSWORD}" 2>/dev/null)
fi
if [ -z "$_hash" ] && command -v mkpasswd >/dev/null 2>&1; then
  _hash=$(mkpasswd -m sha-512 "${DEFAULT_PASSWORD}" 2>/dev/null)
fi
if [ -z "$_hash" ]; then
  echo "[lock] ERROR: no way to hash the default password (need openssl or mkpasswd)" >&2
  exit 1
fi
if ! usermod -p "$_hash" builder; then
  echo "[lock] ERROR: could not set the default password — image would be unusable" >&2
  exit 1
fi
# Prove it took: an empty or '!'-prefixed field would mean no login is possible.
_field=$(getent shadow builder | cut -d: -f2)
case "$_field" in
  '$6$'*) echo "[lock] default password set (sha512)" ;;
  *) echo "[lock] ERROR: builder password field is '${_field:0:3}...' — not a usable hash" >&2; exit 1 ;;
esac

echo "[lock] expiring builder password (forces change at first login)"
chage -d 0 builder 2>/dev/null || echo "[lock] warning: chage failed (password not pre-expired)"
echo "[lock] locking root — guest operations stop working now"
passwd -l root >/dev/null 2>&1 || echo "[lock] note: passwd -l root returned non-zero (often already locked)"

# Power off from here: builder's password just changed, so Packer's
# shutdown_command (which sudo's with the build password) cannot work any more.
# Detached so this provisioner returns before the machine goes down.
echo "[lock] powering off"
nohup sh -c 'sleep 3; systemctl poweroff' >/dev/null 2>&1 &
