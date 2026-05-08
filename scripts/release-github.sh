#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 vX.Y.Z" >&2
  exit 64
fi

VERSION="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP="$ROOT/dist/Codex Limits.zip"

if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must look like v1.2.3" >&2
  exit 64
fi

cd "$ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree must be clean before releasing." >&2
  exit 70
fi

./scripts/package-local.sh

git tag "$VERSION"
git push origin main
git push origin "$VERSION"

gh release create "$VERSION" "$ZIP" \
  --title "Codex Limits $VERSION" \
  --notes "Download \`Codex Limits.zip\`, unzip it, and move \`Codex Limits.app\` to Applications."

echo "Created release $VERSION"
