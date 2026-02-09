---
title: Running Tests
description: How to run and understand Blitz's test suite.
---

## Quick Start

```bash
# Run all unit tests
zig build test

# Run stress tests (ReleaseFast)
zig build test-stress

# Run everything (unit + stress)
zig build test-all
```

## Test Organization

Tests are distributed across the codebase:

```
blitz/
├── blitz.zig            # Test entry point (imports all modules)
├── ops/
│   ├── parallel_for.zig # parallelFor tests
│   ├── parallel_reduce.zig # parallelReduce tests
│   ├── collect.zig      # collect/scatter tests
│   ├── runtime.zig      # init/deinit/config tests
│   ├── try_join.zig     # tryJoin tests
│   └── try_ops.zig      # tryForEach/tryReduce tests
├── iter/
│   ├── iter.zig         # Iterator integration tests
│   ├── Chunks.zig       # Chunk iterator tests
│   ├── Combinators.zig  # Map/filter tests
│   ├── Enumerate.zig    # Enumerate tests
│   ├── Find.zig         # Find/search tests
│   ├── Mutable.zig      # Mutable iterator tests
│   └── Range.zig        # Range iterator tests
├── sort/                # Sorting algorithm tests
├── internal/            # Internal utility tests
├── tests/
│   └── stress.zig       # Stress tests (separate build step)
├── Pool.zig             # Thread pool tests
├── Deque.zig            # Chase-Lev deque tests
├── Future.zig           # Future/fork-join tests
├── Latch.zig            # Synchronization tests
└── Scope.zig            # Scope/spawn/broadcast tests
```

## Build Steps

The `build.zig` defines three test-related steps:

| Command | Step | Description |
|---------|------|-------------|
| `zig build test` | `test` | Unit tests via `blitz.zig` (Debug mode) |
| `zig build test-stress` | `test-stress` | Stress tests via `tests/stress.zig` (ReleaseFast) |
| `zig build test-all` | `test-all` | Both unit and stress tests |

## Test Categories

### Unit Tests

Test individual functions in isolation:

```zig
test "iterator sum" {
    const data = [_]i64{ 1, 2, 3, 4, 5 };
    const result = blitz.iter(i64, &data).sum();
    try std.testing.expectEqual(@as(i64, 15), result);
}
```

### Integration Tests

Test module interactions:

```zig
test "parallel sum" {
    try blitz.init();
    defer blitz.deinit();

    const allocator = std.testing.allocator;
    const data = try allocator.alloc(i64, 100_000);
    defer allocator.free(data);

    for (data, 0..) |*v, i| v.* = @intCast(i);

    const sum = blitz.iter(i64, data).sum();
    const expected: i64 = 100_000 * 99_999 / 2;
    try std.testing.expectEqual(expected, sum);
}
```

### Stress Tests

Test under high contention and large data (run with `zig build test-stress`):

```zig
test "parallelSum - 10M elements" {
    blitz.init() catch {};
    defer blitz.deinit();

    const data = try std.testing.allocator.alloc(i64, 10_000_000);
    defer std.testing.allocator.free(data);

    for (data, 0..) |*v, i| v.* = @intCast(i);
    const result = blitz.iter(i64, data).sum();
    // Verify correctness...
}
```

Stress tests include:
- Deque concurrent producer-stealer (10K items, 4 stealers)
- Deque high contention steal (100 items, 8 stealers)
- Parallel sort, sum, min/max, find, forEach with 10M elements
- Iterator reduce with 10M elements
- Recursive join stress (fibonacci)

## Test Output

### All Tests Pass

```
$ zig build test
All 179 tests passed.
```

### Test Failure

```
$ zig build test

1/179 ops.test.parallel for basic...FAIL
    Expected 100, found 99
```

## Debug Mode

Run tests with filtering:

```bash
# Run single test by name
zig build test -- --test-filter "parallel for basic"

# Run with summary
zig build test -- --summary all
```

## Memory Safety

Zig's safety checks are enabled in test mode:

```zig
test "bounds checking" {
    var arr = [_]i32{ 1, 2, 3 };
    _ = arr[5];  // Panic: index out of bounds
}
```

## Test Allocator

Use `std.testing.allocator` to detect memory leaks:

```zig
test "no memory leaks" {
    const allocator = std.testing.allocator;

    const data = try allocator.alloc(i64, 1000);
    defer allocator.free(data);

    // If we forget to free, test fails with:
    // "Memory leak detected"
}
```

## Parallel Test Execution

Zig runs tests sequentially by default. For Blitz, this is intentional because:
- Tests share global thread pool state (`init()`/`deinit()` per test)
- Parallel test execution could cause interference

## Writing New Tests

### Test File Structure

```zig
const std = @import("std");
const blitz = @import("../api.zig");

test "descriptive test name" {
    // Setup
    try blitz.init();
    defer blitz.deinit();

    // Execute
    const result = someFunction();

    // Verify
    try std.testing.expectEqual(expected, result);
}
```

### Testing Parallel Correctness

```zig
test "parallel sum equals sequential sum" {
    try blitz.init();
    defer blitz.deinit();

    const data = generateTestData(10_000);

    // Sequential
    var seq_sum: i64 = 0;
    for (data) |v| seq_sum += v;

    // Parallel
    const par_sum = blitz.iter(i64, data).sum();

    try std.testing.expectEqual(seq_sum, par_sum);
}
```

### Testing Edge Cases

```zig
test "empty array" {
    const empty: []const i64 = &.{};
    try std.testing.expectEqual(@as(?i64, null), blitz.iter(i64, empty).min());
}

test "single element" {
    const single = [_]i64{42};
    try std.testing.expectEqual(@as(i64, 42), blitz.iter(i64, &single).sum());
}
```

## Continuous Integration

Example CI configuration:

```yaml
# .github/workflows/test.yml
name: Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.0
      - name: Run unit tests
        run: zig build test
      - name: Run stress tests
        run: zig build test-stress
```
