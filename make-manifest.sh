#!/usr/bin/env bash
# Build manifest.json for a release from the artifacts in build/packer/.
#
# WHY: the release tag is a date (vYYYY.MM.DD), which says WHEN an image was
# built and nothing about WHAT is in it. Three things vary independently and all
# matter to a consumer:
#   * the OS point release  (Rocky 9.8 -> 9.9)
#   * the benchmark and SCAP content version (CIS RHEL9 v2.0.0, SSG 0.1.80)
#   * the build date (package/CVE currency)
# A tag cannot carry all three across multiple targets in one release, so the
# manifest does. Diffing two manifests tells you exactly what changed — which is
# the question a bare date can never answer.
#
# The same fields ship inside each image at /etc/cis-image-release, so a running
# VM can answer the question without reference to its origin.
set -euo pipefail
cd "$(dirname "$0")"

OUT="build/packer/manifest.json"
TAG="${1:-v$(date +%Y.%m.%d)}"

{
  printf '{\n  "release": "%s",\n' "$TAG"
  printf '  "generated": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "project": "https://github.com/bryanjbelanger/cis-hardened-images",\n'
  printf '  "images": [\n'

  first=1
  for ova in build/packer/*.ova; do
    [ -f "$ova" ] || continue
    base=$(basename "$ova" .ova)                 # cis-rocky9-vmware-amd64
    target=$(echo "$base" | sed -E 's/^cis-([a-z0-9]+)-.*/\1/')
    hv=$(echo "$base" | sed -E 's/.*-(vmware|virtualbox)-.*/\1/')

    # `|| true`: ls exits non-zero when a file is absent, and under `set -e` a
    # failing command substitution in an assignment kills the script mid-loop —
    # which silently truncated the JSON.
    rel=$(ls build/packer/cis-${target}-*release.txt 2>/dev/null | head -1 || true)
    aud=$(ls build/packer/cis-${target}-*audit*.txt 2>/dev/null | head -1 || true)
    # A missing field must read "unknown", never "". `grep ... | cut | tr || echo`
    # cannot do that: the pipeline's exit status is tr's, which is 0 even when
    # grep matched nothing, so the fallback never fired and absent provenance
    # was published as an empty string instead of announcing itself.
    get() {
      local v=""
      if [ -n "${rel:-}" ] && [ -f "$rel" ]; then
        v=$(grep "^$1=" "$rel" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
      fi
      [ -n "$v" ] && printf '%s' "$v" || printf 'unknown'
    }

    [ $first -eq 1 ] || printf ',\n'
    first=0
    printf '    {\n'
    printf '      "asset": "%s",\n' "$(basename "$ova")"
    printf '      "sha256": "%s",\n' "$(shasum -a 256 "$ova" | cut -d' ' -f1)"
    printf '      "size_bytes": %s,\n' "$(stat -f%z "$ova")"
    printf '      "target": "%s",\n' "$target"
    printf '      "hypervisor": "%s",\n' "$hv"
    printf '      "os": "%s",\n' "$(get OS_PRETTY_NAME)"
    printf '      "os_version": "%s",\n' "$(get OS_VERSION)"
    printf '      "benchmark": "%s",\n' "$(get BENCHMARK)"
    printf '      "scap_profile": "%s",\n' "$(get SCAP_PROFILE)"
    printf '      "scap_datastream": "%s",\n' "$(get SCAP_DATASTREAM)"
    printf '      "scap_content_version": "%s",\n' "$(get SCAP_CONTENT_VERSION)"
    printf '      "fips_mode": "%s",\n' "$(get FIPS_MODE)"
    printf '      "build_date": "%s",\n' "$(get BUILD_DATE)"
    if [ -f "${aud:-}" ]; then
      printf '      "audit": { "pass": %s, "fail": %s, "total": %s, "mount_rules_passing": %s }\n' \
        "$(grep -oE '^pass=[0-9]+' "$aud" | cut -d= -f2 || echo 0)" \
        "$(grep -oE '^fail=[0-9]+' "$aud" | cut -d= -f2 || echo 0)" \
        "$(grep -oE '^total=[0-9]+' "$aud" | cut -d= -f2 || echo 0)" \
        "$(grep -oE '^mount_rules_passing=[0-9]+' "$aud" | cut -d= -f2 || echo 0)"
    else
      printf '      "audit": null\n'
    fi
    printf '    }'
  done
  printf '\n  ]\n}\n'
} > "$OUT"

python3 -c "import json;json.load(open('$OUT'));print('  manifest valid JSON')"
echo "  wrote $OUT ($(python3 -c "import json;print(len(json.load(open('$OUT'))['images']))") image(s))"
