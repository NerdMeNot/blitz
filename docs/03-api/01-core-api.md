# Core API Reference

The main Blitz API for parallel execution.

## Initialization

### `init() !void`

Initialize the thread pool with automatic configuration.

```zig
try blitz.init();
defer blitz.deinit();
```

### `initWithConfig(config: ThreadPoolConfig) !void`

Initialize with custom configuration.

```zig
try blitz.initWithConfig(.{
    .background_worker_count = 8,
});
```

**ThreadPoolConfig fields:**
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `background_worker_count` | `?u32` | `null` (auto) | Number of background workers |

### `deinit() void`

Shutdown the thread pool and join all workers.

### `isInitialized() bool`

Check if pool is initialized.

### `numWorkers() u32`

Get total worker count (including main thread).

---

## Fork-Join

### `join(RetA, RetB, fnA, fnB, argA, argB) [2]...`

Execute two functions potentially in parallel.

```zig
pub fn join(
    comptime RetA: type,
    comptime RetB: type,
    comptime fnA: fn(ArgA) RetA,
    comptime fnB: fn(ArgB) RetB,
    argA: ArgA,
    argB: ArgB,
) [2]ReturnType
```

**Returns:** `[2]T` where `T` is `RetA` if `RetA == RetB`, else a tuple.

**Example:**
```zig
const results = blitz.join(u64, u64, computeA, computeB, arg1, arg2);
const total = results[0] + results[1];
```

### `joinVoid(fnA, fnB, argA, argB) void`

Execute two void functions in parallel.

```zig
blitz.joinVoid(processLeft, processRight, leftData, rightData);
```

---

## Parallel For

### `parallelFor(n, Context, ctx, body) void`

Execute body function over range `[0, n)` in parallel.

```zig
pub fn parallelFor(
    n: usize,
    comptime Context: type,
    ctx: Context,
    comptime body: fn(Context, usize, usize) void,
) void
```

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `n` | Range size (processes indices 0 to n-1) |
| `Context` | Type of context struct |
| `ctx` | Context instance passed to each chunk |
| `body` | `fn(ctx, start, end)` - processes `[start, end)` |

**Example:**
```zig
const Ctx = struct { data: []f64 };
blitz.parallelFor(data.len, Ctx, .{ .data = data }, struct {
    fn body(c: Ctx, start: usize, end: usize) void {
        for (c.data[start..end]) |*v| v.* = v.* * 2;
    }
}.body);
```

### `parallelForWithGrain(n, Context, ctx, body, grain) void`

Same as `parallelFor` with custom minimum chunk size.

---

## Parallel Reduce

### `parallelReduce(T, n, identity, Context, ctx, map, combine) T`

Map-reduce pattern with parallel execution.

```zig
pub fn parallelReduce(
    comptime T: type,
    n: usize,
    identity: T,
    comptime Context: type,
    ctx: Context,
    comptime map: fn(Context, usize) T,
    comptime combine: fn(T, T) T,
) T
```

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `T` | Result type |
| `n` | Number of elements |
| `identity` | Initial value (e.g., 0 for sum) |
| `map` | `fn(ctx, index) -> T` extracts/transforms element |
| `combine` | `fn(a, b) -> T` merges results (must be associative) |

**Example:**
```zig
const sum = blitz.parallelReduce(
    i64, data.len, 0,
    []const i64, data,
    struct { fn map(d: []const i64, i: usize) i64 { return d[i]; } }.map,
    struct { fn add(a: i64, b: i64) i64 { return a + b; } }.add,
);
```

### `parallelReduceWithGrain(...)`

Same with custom grain size.

### `parallelReduceChunked(T, E, slice, identity, chunkFn, combine) T`

Reduce processing chunks instead of individual elements.

---

## Parallel Collect

### `parallelCollect(In, Out, input, output, Context, ctx, map) void`

Transform input slice to output slice in parallel.

```zig
blitz.parallelCollect(i32, i64, input, output, void, {}, struct {
    fn map(_: void, x: i32) i64 {
        return @as(i64, x) * @as(i64, x);
    }
}.map);
```

### `parallelMapInPlace(T, Context, data, transform, ctx) void`

Transform slice elements in-place.

---

## Parallel Flatten & Scatter

### `parallelFlatten(T, slices, output) void`

Flatten slice of slices into single output array.

```zig
const slices = [_][]const i64{ slice1, slice2, slice3 };
blitz.parallelFlatten(i64, &slices, output);
```

### `parallelScatter(T, values, indices, output) void`

Scatter values to output at specified indices.

```zig
// output[indices[i]] = values[i]
blitz.parallelScatter(i64, values, indices, output);
```

---

## Synchronization Utilities

### `SyncPtr(T)`

Lock-free pointer for parallel writes to disjoint regions.

```zig
var buffer: [1000]u64 = undefined;
const ptr = blitz.SyncPtr(u64).init(&buffer);

// In parallel body:
ptr.writeAt(index, value);
const val = ptr.readAt(index);
```

### `computeOffsetsInto(lengths, offsets) void`

Compute cumulative offsets from lengths (exclusive scan).

---

## Grain Size Control

### `getGrainSize() usize`

Get current minimum chunk size.

### `setGrainSize(size: usize) void`

Set minimum chunk size for parallel operations.

### `defaultGrainSize: usize`

Constant for automatic grain size selection.

---

## Threshold Heuristics

### `shouldParallelize(op: OpType, len: usize) bool`

Check if parallelization is beneficial.

```zig
if (blitz.shouldParallelize(.sum, data.len)) {
    // Use parallel
} else {
    // Use sequential
}
```

### `OpType` enum

```zig
pub const OpType = enum {
    sum,
    min,
    max,
    add,
    mul,
    transform,
    filter,
    sort,
    scan,
    // ...
};
```

### `isMemoryBound(op: OpType) bool`

Check if operation is memory-bandwidth limited.
