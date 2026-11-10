#!/usr/bin/env bash
# Copies the registry and the Source and App fixtures of grafana/viz-contract into this repository, and writes the
# pin tools/viz_contract/CONTRACT. Run it with a ref (a commit or a tag) when the contract changes:
#
#   scripts/sync-viz-contract.sh <ref>
#
# It needs the gh CLI. The copies are in tools/viz_contract (registry), tools/testdata/viz-contract (Source
# fixtures) and ui/mcp-apps/test/viz-contract (App fixtures). See tools/viz_contract/README.md.
set -euo pipefail

ref="${1:?usage: scripts/sync-viz-contract.sh <commit-or-tag>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
registry="$root/tools/viz_contract"
fixtures="$root/tools/testdata/viz-contract"
app_fixtures="$root/ui/mcp-apps/test/viz-contract"

hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# The archive is untrusted data: it goes into its own empty directory.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sha="$(gh api "repos/grafana/viz-contract/commits/$ref" --jq .sha)"
gh api "repos/grafana/viz-contract/tarball/$sha" >"$work/contract.tgz"
mkdir "$work/src"
tar -xzf "$work/contract.tgz" -C "$work/src" --strip-components=1
src="$work/src"
# The version comes from the tag: package.json on main keeps a placeholder (viz-contract 8-versioning.md).
semver='^[0-9]+\.[0-9]+\.[0-9]+$'
tags="$(gh api --paginate "repos/grafana/viz-contract/tags" --jq ".[] | select(.commit.sha == \"$sha\") | .name")"
version="$(printf '%s\n' "$tags" | sed -n 's/^v//p' | { grep -E "$semver" || true; } | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)"
if [ -z "$version" ]; then
  version="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$src/package.json" | head -n1)"
fi
echo "$version" | grep -qE "$semver" || { echo "$ref has no release tag and no release version in package.json" >&2; exit 1; }

mkdir -p "$registry"
cp "$src/registry/chart-types.json" "$src/registry/pick.json" "$src/LICENSE" "$registry/"

# The Source fixtures: the sets that have a response and a result. Other files of a set are for the App and the Renderer.
rm -rf "$fixtures"
mkdir -p "$fixtures"
for dir in "$src"/fixtures/*/; do
  name="$(basename "$dir")"
  if [ ! -f "$dir/response.json" ] || [ ! -f "$dir/result.json" ]; then
    continue
  fi
  mkdir -p "$fixtures/$name"
  for file in args meta request response result; do
    if [ -f "$dir/$file.json" ]; then
      cp "$dir/$file.json" "$fixtures/$name/"
    fi
  done
done

# The App fixtures: the sets that have arguments, a result and a viz spec (fixtures.9).
rm -rf "$app_fixtures"
mkdir -p "$app_fixtures"
for dir in "$src"/fixtures/*/; do
  name="$(basename "$dir")"
  if [ ! -f "$dir/args.json" ] || [ ! -f "$dir/result.json" ] || [ ! -f "$dir/spec.json" ]; then
    continue
  fi
  mkdir -p "$app_fixtures/$name"
  cp "$dir/args.json" "$dir/result.json" "$dir/spec.json" "$app_fixtures/$name/"
done

cat >"$registry/CONTRACT" <<PIN
repository: grafana/viz-contract
commit: $sha
version: $version
sha256 chart-types.json: $(hash "$registry/chart-types.json")
sha256 pick.json: $(hash "$registry/pick.json")
PIN

echo "Synced grafana/viz-contract $version ($sha)."
echo "Next: go test -tags unit ./tools -run 'VizContract|QueryDatasource', and npm test in ui/mcp-apps, then commit tools/viz_contract, tools/testdata/viz-contract and ui/mcp-apps/test/viz-contract."
