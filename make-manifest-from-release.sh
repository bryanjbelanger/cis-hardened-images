#!/usr/bin/env bash
# Build manifest.json for a release from the release's OWN assets.
#
# WHY THIS EXISTS ALONGSIDE make-manifest.sh
# make-manifest.sh globs build/packer in one workspace. That is correct for a
# local run, and wrong in CI: the matrix fans out over several self-hosted
# runners, so each runner holds only the images it happened to build. A manifest
# generated per job would describe a subset of the release while looking
# complete, and `gh release upload --clobber` means whichever job finished last
# would win. This runs ONCE, after the matrix, and reads what was actually
# published.
#
# Only small text assets are downloaded — never the OVAs. Sizes come from the
# releases API and checksums from the .sha256 files uploaded beside each image,
# so a full manifest costs a few KB rather than several GB.
set -euo pipefail

TAG="${1:?usage: make-manifest-from-release.sh <tag>}"
REPO="${GH_REPO:-bryanjbelanger/cis-hardened-images}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> collecting metadata from $REPO release $TAG"
if [ -n "${META_DIR:-}" ]; then
  # Test hook: take the evidence files from a local directory instead of the
  # release, so the parsing can be exercised without publishing anything.
  echo "    META_DIR set — using local evidence from $META_DIR"
  cp "$META_DIR"/*release.txt "$META_DIR"/*audit*.txt "$META_DIR"/*.ova.sha256 "$WORK/" 2>/dev/null || true
else
  gh release download "$TAG" --repo "$REPO" --dir "$WORK" \
    --pattern '*release.txt' --pattern '*audit*.txt' --pattern '*.ova.sha256' \
    --clobber >/dev/null 2>&1 || true
fi

# name<TAB>size for every published OVA. This is the authoritative list of what
# the release contains — not what any one runner built.
gh api "repos/$REPO/releases/tags/$TAG" \
  --jq '.assets[] | select(.name | endswith(".ova")) | [.name, .size] | @tsv' \
  > "$WORK/ovas.tsv"

count=$(wc -l < "$WORK/ovas.tsv" | tr -d ' ')
echo "    $count OVA(s) published"
[ "$count" -gt 0 ] || { echo "ERROR: no OVAs in release $TAG" >&2; exit 1; }

OUT=manifest.json
WORK="$WORK" TAG="$TAG" REPO="$REPO" python3 - "$OUT" <<'PYEOF'
import json, os, re, sys

work, tag, repo = os.environ["WORK"], os.environ["TAG"], os.environ["REPO"]
out = sys.argv[1]

def read_kv(path):
    d = {}
    if os.path.exists(path):
        for line in open(path):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                d[k] = v.strip().strip('"')
    return d

def read_audit(path):
    d = {}
    if os.path.exists(path):
        for line in open(path):
            m = re.match(r"^(pass|fail|total|mount_rules_passing)=(\d+)$", line.strip())
            if m:
                d[m.group(1)] = int(m.group(2))
    return d

def find(suffix, target, hv, variant):
    """Evidence is named after the VM: cis-<target>[-stig][-fips]-<hv>-iso-<kind>.
    Match target, hypervisor AND variant, or a STIG image would happily pick up
    its CIS sibling's audit numbers and report them as its own."""
    want = []
    if variant.startswith("stig"):
        want.append("-stig")
    if variant.endswith("fips"):
        want.append("-fips")
    for f in sorted(os.listdir(work)):
        if not (f.startswith(f"cis-{target}-") and f.endswith(suffix) and hv in f):
            continue
        if all(w in f for w in want) and \
           ("-stig" in f) == variant.startswith("stig") and \
           ("-fips" in f) == variant.endswith("fips"):
            return os.path.join(work, f)
    return None

images = []
for line in open(os.path.join(work, "ovas.tsv")):
    name, size = line.rstrip("\n").split("\t")
    # Assets are <variant>-<target>-<hypervisor>-<arch>.ova, where variant is
    # cis | cis-fips | stig | stig-fips. The variant MUST be part of the match:
    # an earlier version anchored on "cis-" and would have silently skipped
    # every STIG asset, publishing a manifest that omitted half the release
    # while looking complete.
    m = re.match(r"^(cis|cis-fips|stig|stig-fips)-([a-z0-9]+)-(vmware|virtualbox)-([a-z0-9]+)\.ova$", name)
    if not m:
        print(f"    WARNING: unrecognised asset name, skipping: {name}")
        continue
    variant, target, hv, arch = m.groups()
    hv_tag = "vmware" if hv == "vmware" else "virtualbox"

    rel = read_kv(find("release.txt", target, hv_tag, variant) or "")
    aud = read_audit(find("audit.txt", target, hv_tag, variant) or "")

    sha = "unknown"
    shafile = find(".ova.sha256", target, hv_tag, variant)
    if shafile and os.path.exists(shafile):
        sha = open(shafile).read().split()[0]

    def g(k):
        v = rel.get(k, "")
        return v if v else "unknown"

    images.append({
        "asset": name,
        "sha256": sha,
        "size_bytes": int(size),
        "target": target,
        "variant": variant,
        "benchmark_family": "stig" if variant.startswith("stig") else "cis",
        "hypervisor": hv,
        "arch": arch,
        "os": g("OS_PRETTY_NAME"),
        "os_version": g("OS_VERSION"),
        "benchmark": g("BENCHMARK"),
        "scap_profile": g("SCAP_PROFILE"),
        "scap_datastream": g("SCAP_DATASTREAM"),
        "scap_content_version": g("SCAP_CONTENT_VERSION"),
        "fips_mode": g("FIPS_MODE"),
        "build_date": g("BUILD_DATE"),
        "audit": ({"pass": aud.get("pass", 0), "fail": aud.get("fail", 0),
                   "total": aud.get("total", 0),
                   "mount_rules_passing": aud.get("mount_rules_passing", 0)}
                  if aud else None),
    })

images.sort(key=lambda i: (i["variant"], i["target"], i["hypervisor"]))
json.dump({
    "release": tag,
    "generated": __import__("datetime").datetime.now(
        __import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "project": f"https://github.com/{repo}",
    "images": images,
}, open(out, "w"), indent=2)
open(out, "a").write("\n")

incomplete = [i["asset"] for i in images
              if i["os"] == "unknown" or i["sha256"] == "unknown" or i["audit"] is None]
print(f"    wrote {out} with {len(images)} image(s)")
if incomplete:
    print("    WARNING: incomplete metadata for: " + ", ".join(incomplete))
PYEOF

python3 -c "import json;json.load(open('$OUT'));print('    manifest is valid JSON')"
