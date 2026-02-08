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

### Core Files
- `api.zig` - Public high-level API entry point (what users import as "blitz")
- `blitz.zig` - Library module definition (test entry point)
- `pool.zig` - ThreadPool with lock-free futex wake
- `deque.zig` - Chase-Lev lock-free work-stealing deque
- `future.zig` - Future for fork-join operations
- `job.zig` - Minimal Job struct
- `latch.zig` - Synchronization primitives (OnceLatch, CountLatch, SpinWait)
- `sleep.zig` - Progressive sleep manager for workers
- `scope.zig` - Scope-based parallelism
- `algorithms.zig` - Parallel algorithms (sort, scan, find)
- `sync.zig` - SyncPtr for lock-free parallel writes

### Subdirectories
- `ops/` - API tests (split from api.zig for smaller files)
- `iter/` - Parallel iterators (composable)
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

## blitz-io Integration

Blitz is designed to complement [blitz-io](../blitz-io/) - an async I/O runtime. Together they form a complete async system like Tokio + Rayon in Rust:

- **Blitz**: CPU-bound parallelism (fork-join, parallel iterators, work-stealing)
- **blitz-io**: I/O-bound async (networking, file I/O, timers)

### Integration Points

1. **Job Injection** - blitz-io submits CPU work to Blitz via `ThreadPool.injectJob()`
2. **Result Delivery** - Blitz workers signal completion back to blitz-io tasks
3. **No Cross-Blocking** - Blitz workers never block on I/O; blitz-io tasks never do heavy CPU work

### Key APIs for Integration

```zig
// Submit work from outside the pool
pool.injectJob(job) // Existing - works but allocates InjectedJob node

// Check for external work
pool.hasInjectedJobs() // Existing - used in sleep protocol
pool.popInjectedJob()  // Existing - called by idle workers
```

### Potential Enhancements for blitz-io

| Enhancement | Description |
|-------------|-------------|
| Callback on completion | Allow injected jobs to specify a completion callback |
| External waker support | Let blitz-io provide a custom waker for result notification |
| Oneshot channel | Built-in single-value result delivery primitive |
