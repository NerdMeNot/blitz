#!/usr/bin/env bash
set -euo pipefail

TAG="${1:?Usage: $0 <tag>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCS_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$DOCS_DIR")"

echo "=== Docs release: $TAG ==="
echo ""

# Step 1: Snapshot current docs under this version
echo "Step 1/4: Creating docs snapshot for $TAG..."
(cd "$DOCS_DIR" && bun scripts/snapshot.mjs "$TAG")

# Step 2: Update versions.json
echo "Step 2/4: Updating version config..."
(cd "$DOCS_DIR" && bun scripts/update-versions.mjs add "$TAG")

# Step 3: Build site
echo "Step 3/4: Building Starlight site..."
(cd "$DOCS_DIR" && bun install && bun run build)

# Copy autodocs into dist if available
if [ -d "$ROOT_DIR/zig-out/docs/api-reference" ]; then
    cp -r "$ROOT_DIR/zig-out/docs/api-reference" "$DOCS_DIR/dist/api-reference"
    echo "  Copied Zig autodocs into dist/"
else
    echo "  Skipping autodocs (run 'zig build docs' first if needed)"
fi

# Step 4: Commit snapshot to git
echo "Step 4/4: Committing snapshot..."
(cd "$ROOT_DIR" && git add docs/versions.json "docs/src/content/docs/$TAG/" "docs/src/content/versions/$TAG.json")
if ! git -C "$ROOT_DIR" diff --cached --quiet 2>/dev/null; then
    (cd "$ROOT_DIR" && git commit -m "docs: snapshot $TAG")
fi

echo ""
echo "=== Done ==="
echo "Snapshot committed. Run 'bun run deploy' to push to Cloudflare Pages."
