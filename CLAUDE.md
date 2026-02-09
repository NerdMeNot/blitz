# CLAUDE.md

## Project Overview

Blitz is a lock-free work-stealing parallel runtime for Zig (inspired by Rust's Rayon). Fork-join parallelism, parallel iterators, parallel sort.

## Build

```bash
zig build            # build
zig build test       # run all tests
zig build bench      # benchmarks
zig fmt .            # format before committing
```

## Docs (uses bun, not node)

```bash
cd docs
bun install            # install deps (once)
bun run dev            # dev server
bun run build          # build static site
bun run preview        # preview build
bun run clean          # clean build artifacts
bun run release <tag>  # snapshot + build + commit
bun run set-latest <tag>  # mark version as latest
bun run deploy         # push dist/ to Cloudflare Pages
```

## Structure

- `api.zig` — public API (re-exports from `ops/`)
- `blitz.zig` — library root / test entry point
- `Pool.zig` → `Future.zig` → `Latch.zig` → `Deque.zig` — core chain
- `Scope.zig` — scope-based parallelism
- `Sync.zig` — lock-free parallel writes
- `algorithms.zig` — parallel sort, scan, find
- `ops/` — API operation implementations
- `iter/` — parallel iterators
- `sort/` — parallel PDQSort
- `internal/` — utilities (threshold, splitter, rng)
- `examples/`, `benchmarks/`, `tests/`
- `docs/` — Astro/Starlight site (bun)

## Commit Rules

- `zig fmt .` before committing
- Do NOT add AI co-author attribution
