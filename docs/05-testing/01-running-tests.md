# Running Tests

How to run and understand Blitz's test suite.

## Quick Start

```bash
cd core/src/blitz

# Run all tests
zig test api.zig

# Run with verbose output
zig test api.zig --summary all
```

## Test Organization

Tests are distributed across modules:

```
blitz/
├── api.zig           # Integration tests
├── iter/
│   └── tests.zig     # Iterator tests
├── simd/
│   └── tests.zig     # SIMD tests
├── sort/
│   └── tests.zig     # Sorting tests
├── internal/
│   └── mod.zig       # Internal utility tests
└── ...
```

## Running Specific Test Files

```bash
# Test iterators only
zig test iter/mod.zig

# Test SIMD only
zig test simd/mod.zig

# Test sorting only
zig test sort/mod.zig

# Test internal utilities
zig test internal/mod.zig
```

## Test Categories

### Unit Tests

Test individual functions in isolation:

```zig
test "simd sum" {
    const data = [_]i64{ 1, 2, 3, 4, 5 };
    const result = simd.sum(i64, &data);
    try std.testing.expectEqual(@as(i64, 15), result);
}
```

### Integration Tests

Test module interactions:

```zig
test "parallel reduce with SIMD" {
    try blitz.init();
    defer blitz.deinit();

    const data = try allocator.alloc(i64, 100_000);
    defer allocator.free(data);

    // Initialize data
    for (data, 0..) |*v, i| v.* = @intCast(i);

    const sum = blitz.iter(i64, data).sum();
    const expected: i64 = 100_000 * 99_999 / 2;
    try std.testing.expectEqual(expected, sum);
}
```

### Stress Tests

Test under load:

```zig
test "concurrent work stealing" {
    try blitz.init();
    defer blitz.deinit();

    // Spawn many recursive tasks
    const result = parallelFib(40);
    try std.testing.expectEqual(@as(u64, 102334155), result);
}
```

## Test Output

### All Tests Pass

```
$ zig test api.zig

1/117 api.test.parallel for basic...OK
2/117 api.test.parallel reduce sum...OK
...
117/117 internal.threshold.test.cost model values...OK
All 117 tests passed.
```

### Test Failure

```
$ zig test api.zig

1/117 api.test.parallel for basic...FAIL
    Expected 100, found 99
    /blitz/api.zig:245:5: test failure
```

## Debug Mode

Run tests with debug output:

```bash
# Enable debug prints
zig test api.zig -Dlog-level=debug

# Run single test
zig test api.zig --test-filter "parallel for basic"
```

## Memory Safety

Zig's safety checks are enabled in test mode:

```zig
test "bounds checking" {
    var arr = [_]i32{ 1, 2, 3 };
    _ = arr[5];  // Panic: index out of bounds
}

test "use after free" {
    var alloc = std.testing.allocator;
    const ptr = try alloc.alloc(u8, 100);
    alloc.free(ptr);
    _ = ptr[0];  // Panic: use after free
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
- Tests share global thread pool state
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
      - uses: actions/checkout@v3
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.13.0
      - name: Run tests
        run: cd core/src/blitz && zig test api.zig
```
