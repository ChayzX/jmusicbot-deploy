#!/usr/bin/env bash
set -euo pipefail

# Print the newest stable (vX.Y.Z / X.Y.Z, no pre-release suffix) tag of a
# GitHub repo. Uses git's smart protocol rather than the REST API, so shared
# CI runners never hit GitHub's anonymous API rate limit (60 req/h per IP,
# which a busy shared-runner IP can exhaust on its own).
repo=${1:?usage: $0 owner/repo}
tag=$(git ls-remote --tags --refs --sort=-v:refname "https://github.com/${repo}.git" \
  | sed 's|.*refs/tags/||' \
  | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
  | head -n1)
test -n "$tag" || { echo "no stable tag found for $repo" >&2; exit 1; }
echo "$tag"
