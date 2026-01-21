# Contributing to Blitz

Thanks for your interest in contributing to Blitz! This document provides guidelines and information for contributors.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/blitz.git`
3. Create a branch: `git checkout -b my-feature`
4. Make your changes
5. Run tests: `make test`
6. Push and create a PR

## Development Setup

### Requirements

- Zig 0.15.0 or later
- Make (for convenience commands)
- Rust (optional, for Rayon benchmark comparisons)

### Common Commands

```bash
make test           # Run all tests
make test-verbose   # Run tests with output
make fmt            # Format code
make check          # Format check + tests
make bench          # Run benchmarks
make help           # See all commands
```

## Code Guidelines

### Style

- Follow Zig's standard style (use `zig fmt`)
- Keep functions focused and small
- Use descriptive names
- Add doc comments for public APIs

### Testing

- Add tests for new functionality
- Tests should be fast and deterministic
- Use descriptive test names: `test "parallelFor - handles empty range"`

### Performance

- Benchmark significant changes: `make bench`
- Avoid allocations in hot paths
- Consider cache effects and false sharing
- Document performance characteristics

## Pull Request Process

1. **Before submitting:**
   - Run `make check` (format + tests)
   - Update documentation if needed
   - Add tests for new features

2. **PR description should include:**
   - Summary of changes
   - Type of change (bug fix, feature, etc.)
   - Test plan
   - Related issues

3. **Review process:**
   - CI must pass
   - At least one maintainer approval
   - Address review feedback

## Reporting Issues

- Use the issue templates
- Include Zig version and OS
- Provide minimal reproduction code
- Check existing issues first

## Architecture Overview

```
blitz/
├── api.zig         # Public API entry point
├── pool.zig        # Thread pool with work stealing
├── worker.zig      # Worker threads
├── deque.zig       # Lock-free Chase-Lev deque
├── future.zig      # Fork-join futures
├── iter/           # Parallel iterators
├── sort/           # Parallel sorting
└── simd/           # SIMD operations
```

Key design principles:
- Lock-free hot paths
- Zero allocations during parallel execution
- Cache-line isolation to prevent false sharing
- Comptime specialization for type safety

## Questions?

- Open a [Discussion](https://github.com/NerdMeNot/blitz/discussions)
- Check the [README](README.md) and [BENCHMARKS](BENCHMARKS.md)

## License

By contributing, you agree that your contributions will be licensed under the Apache 2.0 License.
