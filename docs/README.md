# Blitz Documentation

Astro/Starlight documentation site for Blitz. Uses **bun** (not node).

## Setup

```bash
bun install
```

## Development

```bash
bun run dev          # Start dev server with hot reload (localhost:4321)
bun run build        # Build static site to dist/
bun run preview      # Preview the built site locally
bun run clean        # Remove dist/ and caches
```

## Versioned Releases

```bash
# Snapshot current docs as a version, build, and commit
bun run release v2.0.0-zig0.15.3

# Change which version is marked as latest
bun run set-latest v2.0.0-zig0.15.3

# Deploy the built dist/ to Cloudflare Pages
bun run deploy
```

### How versioning works

- `versions.json` tracks `current` (latest) and `history` (older versions)
- `bun run release <tag>` copies root docs into `src/content/docs/<tag>/`, updates `versions.json`, builds the site, and commits
- The `starlight-versions` plugin reads `versions.json` to render a version picker
- `sidebar.mjs` is the shared sidebar config used by both the site and the snapshot script

### Scripts

| Script | What it does |
|--------|-------------|
| `scripts/release.sh` | Full release flow: snapshot + update versions + build + commit |
| `scripts/snapshot.mjs` | Copy current docs into a versioned subdirectory |
| `scripts/update-versions.mjs` | Manage `versions.json` (add, set-latest, list) |

## Zig Autodocs

If you've built Zig autodocs (`zig build docs` from the project root), release.sh will copy them into `dist/api-reference/` automatically. You can also do this manually:

```bash
cp -r ../zig-out/docs/api-reference dist/api-reference
```

## Project Structure

```
docs/
  astro.config.mjs    # Astro + Starlight + versions plugin config
  sidebar.mjs          # Shared sidebar (used by config and snapshot)
  versions.json        # Version registry (current + history)
  package.json         # Scripts and dependencies
  scripts/
    release.sh         # Release flow
    snapshot.mjs       # Version snapshot
    update-versions.mjs # Version management
  src/
    content/
      docs/            # Root docs (working copy = next release)
        <tag>/         # Versioned snapshots
      versions/        # Per-version sidebar JSON
    components/        # Custom Astro components
    styles/            # Global CSS
```
