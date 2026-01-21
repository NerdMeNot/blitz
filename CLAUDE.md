# CLAUDE.md

This file provides guidance for Claude Code when working with the Blitz codebase.

## Project Overview

Blitz is a high-performance, lock-free work-stealing parallel runtime for Zig, inspired by Rust's Rayon library. It provides fork-join parallelism, parallel iterators, and SIMD-accelerated operations.

## Build Commands

```bash
# Build the library
zig build

# Run all tests
zig build test

# Run benchmarks
zig build bench

# Run a specific example
zig build run-example -- <example_name>

# Format code
zig fmt .
```

## Project Structure

- `api.zig` - Public high-level API entry point
- `mod.zig` - Library module definition
- `pool.zig` - ThreadPool with lock-free futex wake
- `worker.zig` - Worker threads and Task management
- `deque.zig` - Chase-Lev lock-free work-stealing deque
- `future.zig` - Future for fork-join operations
- `job.zig` - Minimal Job struct
- `latch.zig` - Synchronization primitives
- `scope.zig` - Scope-based parallelism
- `algorithms.zig` - Parallel algorithms (sort, scan, find)
- `sync.zig` - SyncPtr for lock-free parallel writes
- `iter/` - Parallel iterators (Rayon-style composable)
- `simd/` - SIMD-accelerated operations
- `sort/` - Parallel PDQSort implementation
- `internal/` - Internal utilities (threshold, splitter, rng)
- `examples/` - Runnable examples
- `benchmarks/` - Performance benchmarks

## Code Style

- Follow Zig standard library conventions
- Use `zig fmt` before committing
- Keep functions focused and small
- Prefer lock-free algorithms on hot paths
- Document public APIs with doc comments

## Commit Guidelines

**Important:** Do not add Claude, Anthropic, or any AI assistant as a co-author in commit messages. Commits should only attribute human contributors.
