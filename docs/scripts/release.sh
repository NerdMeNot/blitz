#!/usr/bin/env bash
set -euo pipefail

TAG="${1:?Usage: $0 <tag>}"
PROJECT_NAME="${CLOUDFLARE_PROJECT:-blitz-docs}"

# Verify tag exists
git rev-parse "$TAG" >/dev/null 2>&1 || { echo "Error: tag '$TAG' not found in git"; exit 1; }

# Verify clean working tree
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: working tree not clean. Commit or stash changes first."
    exit 1
fi

ORIGINAL_BRANCH=$(git symbolic-ref --short HEAD)
trap 'git checkout --quiet "$ORIGINAL_BRANCH" 2>/dev/null || true' EXIT

echo "=== Building and deploying docs for $TAG ==="

# Step 1: Checkout the tag
echo "Step 1/4: Checking out $TAG..."
git checkout --quiet "$TAG"

# Step 2: Build Starlight site
echo "Step 2/4: Building Starlight site..."
cd docs && bun install --frozen-lockfile && bun run build && cd ..

# Step 3: Build Zig autodocs
echo "Step 3/4: Generating Zig autodocs..."
zig build docs
cp -r zig-out/docs/api-reference docs/dist/_autodocs

# Step 4: Deploy to Cloudflare Pages
echo "Step 4/4: Deploying to Cloudflare Pages..."
cd docs && bunx wrangler pages deploy dist/ --project-name="$PROJECT_NAME" --commit-hash="$(git rev-parse HEAD)" --commit-message="$TAG" && cd ..

# Return to original branch (handled by trap, but be explicit)
git checkout --quiet "$ORIGINAL_BRANCH"

echo ""
echo "=== Done ==="
echo "Docs for $TAG deployed to Cloudflare Pages ($PROJECT_NAME)"
