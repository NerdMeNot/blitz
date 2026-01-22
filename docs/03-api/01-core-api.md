# Core API Reference

This document provides comprehensive documentation for all Blitz APIs, including function signatures, parameters, return types, examples, limitations, and best practices.

## Table of Contents

- [Initialization](#initialization)
- [Iterator API](#iterator-api)
- [Fork-Join API](#fork-join-api)
- [Parallel Algorithms](#parallel-algorithms)
- [Low-Level API](#low-level-api)
- [Configuration](#configuration)

---

## Initialization

Blitz uses a global thread pool that auto-initializes on first use. You can also initialize explicitly for custom configuration.

### `init() !void`

Initialize the thread pool with default settings (CPU count - 1 workers).

```zig
try blitz.init();
defer blitz.deinit();
```

**Errors**: Returns error if thread creation fails.

**Notes**:
- Safe to call multiple times (no-op if already initialized)
- Auto-called on first API use if not explicitly initialized

### `initWithConfig(config: Config) !void`

Initialize with custom configuration.

```zig
try blitz.initWithConfig(.{
    .background_worker_count = 8,
});
defer blitz.deinit();
```

**Parameters**:
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `background_worker_count` | `?usize` | `null` (auto) | Number of worker threads. `null` = CPU count - 1 |

**Example - Fixed thread count**:
```zig
// Use exactly 4 workers regardless of CPU count
try blitz.initWithConfig(.{ .background_worker_count = 4 });
```

**Example - Maximum parallelism**:
```zig
// Use all CPUs (including main thread participates)
const cpu_count = std.Thread.getCpuCount() catch 1;
try blitz.initWithConfig(.{ .background_worker_count = cpu_count });
```

### `deinit() void`

Shut down the thread pool and release resources.

```zig
blitz.deinit();
```

**Notes**:
- Waits for all pending work to complete
- Safe to call multiple times
- Must be called before program exit to avoid resource leaks

### `isInitialized() bool`

Check if the thread pool is initialized.

```zig
if (!blitz.isInitialized()) {
    try blitz.init();
}
```

### `numWorkers() usize`

Get the number of worker threads.

```zig
const workers = blitz.numWorkers();
std.debug.print("Using {} workers\n", .{workers});
```

---

## Iterator API

The iterator API is the **recommended** way to use Blitz. It provides composable, chainable operations that automatically parallelize when beneficial.

### Creating Iterators

#### `iter(T, slice) ParallelSliceIterator(T)`

Create an immutable parallel iterator over a slice.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5 };
const it = blitz.iter(i64, &data);
const sum = it.sum();  // 15
```

**Parameters**:
- `T`: Element type
- `slice`: `[]const T` - The slice to iterate over

**Returns**: `ParallelSliceIterator(T)` with aggregation and search methods.

#### `iterMut(T, slice) ParallelMutSliceIterator(T)`

Create a mutable parallel iterator for in-place operations.

```zig
var data = [_]i64{ 1, 2, 3, 4, 5 };
blitz.iterMut(i64, &data).mapInPlace(double);
// data is now [2, 4, 6, 8, 10]
```

**Parameters**:
- `T`: Element type
- `slice`: `[]T` - The mutable slice

**Returns**: `ParallelMutSliceIterator(T)` with mutation methods.

#### `range(start, end) RangeIterator`

Create a parallel iterator over an index range.

```zig
// Sum of 0 + 1 + 2 + ... + 99
const sum = blitz.range(0, 100).sum(i64, identity);

// Execute function for each index
blitz.range(0, 1000).forEach(processIndex);
```

**Parameters**:
- `start`: `usize` - Start index (inclusive)
- `end`: `usize` - End index (exclusive)

**Returns**: `RangeIterator` for index-based operations.

---

### Aggregation Methods

#### `.sum() T`

Compute the sum of all elements in parallel.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5 };
const total = blitz.iter(i64, &data).sum();  // 15
```

**Returns**: Sum of all elements (type `T`).

**Performance**: O(n/p) where p = number of workers. Uses SIMD when applicable.

**Limitations**:
- Type must support `+` operator
- Overflow follows Zig's default semantics (wrapping for unsigned, undefined for signed in ReleaseFast)

**Best Practice**: For large sums that might overflow, use a wider type:
```zig
// Avoid overflow by using i128 for accumulation
const result = blitz.iter(i64, &data).reduce(@as(i128, 0), struct {
    fn add(acc: i128, val: i64) i128 { return acc + val; }
}.add);
```

#### `.min() ?T`

Find the minimum element in parallel.

```zig
const data = [_]i64{ 5, 2, 8, 1, 9 };
if (blitz.iter(i64, &data).min()) |m| {
    std.debug.print("Min: {}\n", .{m});  // Min: 1
}
```

**Returns**: `?T` - The minimum element, or `null` if the slice is empty.

**Performance**: O(n/p). Uses SIMD when applicable.

#### `.max() ?T`

Find the maximum element in parallel.

```zig
const data = [_]i64{ 5, 2, 8, 1, 9 };
if (blitz.iter(i64, &data).max()) |m| {
    std.debug.print("Max: {}\n", .{m});  // Max: 9
}
```

**Returns**: `?T` - The maximum element, or `null` if the slice is empty.

#### `.reduce(identity, combine) T`

Perform a custom parallel reduction.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5 };

// Product of all elements
const product = blitz.iter(i64, &data).reduce(1, struct {
    fn mul(a: i64, b: i64) i64 { return a * b; }
}.mul);  // 120

// Find element with maximum absolute value
const max_abs = blitz.iter(i64, &data).reduce(0, struct {
    fn maxAbs(a: i64, b: i64) i64 {
        return if (@abs(a) > @abs(b)) a else b;
    }
}.maxAbs);
```

**Parameters**:
- `identity`: Starting value (must be identity element: `combine(identity, x) == x`)
- `combine`: `fn(T, T) T` - Associative binary function

**Requirements**:
- `combine` must be **associative**: `combine(a, combine(b, c)) == combine(combine(a, b), c)`
- `identity` must be the **identity element**: `combine(identity, x) == x`

**Warning**: Non-associative operations give undefined results:
```zig
// BAD: subtraction is not associative
const wrong = blitz.iter(i64, &data).reduce(0, sub);  // Undefined!
```

#### `.count() usize`

Count the number of elements.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5 };
const n = blitz.iter(i64, &data).count();  // 5
```

---

### Search Methods

All search methods support **early exit** - they stop processing as soon as the result is determined.

#### `.findAny(predicate) ?T`

Find any element matching the predicate. **Fastest** search method but non-deterministic.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5, 6 };

const even = blitz.iter(i64, &data).findAny(struct {
    fn isEven(x: i64) bool { return @mod(x, 2) == 0; }
}.isEven);

if (even) |e| {
    std.debug.print("Found an even number: {}\n", .{e});
    // Could be 2, 4, or 6 - order not guaranteed
}
```

**Parameters**:
- `predicate`: `fn(T) bool` - Function returning true for matches

**Returns**: `?T` - Any matching element, or `null` if none found.

**Performance**: O(n/p) worst case, but typically much faster due to early exit.

**When to use**: When you need any match and don't care which one. ~2x faster than `findFirst`.

#### `.findFirst(predicate) ?FindResult(T)`

Find the **leftmost** element matching the predicate.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5, 6 };

if (blitz.iter(i64, &data).findFirst(isEven)) |result| {
    std.debug.print("First even: {} at index {}\n", .{ result.value, result.index });
    // First even: 2 at index 1
}
```

**Returns**: `?FindResult(T)` containing:
- `value: T` - The matched element
- `index: usize` - Index in the original slice

**Performance**: Must scan all chunks to guarantee leftmost, but uses early exit within chunks.

#### `.findLast(predicate) ?FindResult(T)`

Find the **rightmost** element matching the predicate.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5, 6 };

if (blitz.iter(i64, &data).findLast(isEven)) |result| {
    std.debug.print("Last even: {} at index {}\n", .{ result.value, result.index });
    // Last even: 6 at index 5
}
```

#### `.position(predicate) ?usize`

Find the index of the **first** element matching the predicate.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5 };
if (blitz.iter(i64, &data).position(isEven)) |idx| {
    std.debug.print("First even at index {}\n", .{idx});  // 1
}
```

#### `.positionAny(predicate) ?usize`

Find the index of **any** element matching the predicate. Faster but non-deterministic.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5, 6 };
if (blitz.iter(i64, &data).positionAny(isEven)) |idx| {
    // idx could be 1, 3, or 5
}
```

#### `.rposition(predicate) ?usize`

Find the index of the **last** element matching the predicate.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5, 6 };
if (blitz.iter(i64, &data).rposition(isEven)) |idx| {
    std.debug.print("Last even at index {}\n", .{idx});  // 5
}
```

---

### Predicate Methods

#### `.any(predicate) bool`

Check if **any** element matches the predicate. Supports early exit.

```zig
const data = [_]i64{ 1, 3, 5, 7, 8, 9 };

const has_even = blitz.iter(i64, &data).any(isEven);  // true (found 8)
```

**Performance**: Stops immediately when a match is found.

#### `.all(predicate) bool`

Check if **all** elements match the predicate. Supports early exit.

```zig
const data = [_]i64{ 2, 4, 6, 8, 10 };

const all_even = blitz.iter(i64, &data).all(isEven);  // true
```

**Performance**: Stops immediately when a non-match is found.

---

### Min/Max by Key

#### `.minBy(comparator) ?T`

Find minimum element using a custom comparator.

```zig
const Point = struct { x: i32, y: i32 };
const points = [_]Point{
    .{ .x = 3, .y = 4 },
    .{ .x = 1, .y = 1 },
    .{ .x = 2, .y = 3 },
};

const closest_to_origin = blitz.iter(Point, &points).minBy(struct {
    fn compare(a: Point, b: Point) bool {
        const dist_a = a.x * a.x + a.y * a.y;
        const dist_b = b.x * b.x + b.y * b.y;
        return dist_a < dist_b;
    }
}.compare);
// Returns Point{1, 1}
```

**Parameters**:
- `comparator`: `fn(T, T) bool` - Returns true if first arg is "less than" second

#### `.maxBy(comparator) ?T`

Find maximum element using a custom comparator.

#### `.minByKey(K, keyFn) ?T`

Find minimum element by extracting a comparable key.

```zig
const Person = struct { name: []const u8, age: u32 };
const people = [_]Person{
    .{ .name = "Alice", .age = 30 },
    .{ .name = "Bob", .age = 25 },
    .{ .name = "Carol", .age = 35 },
};

const youngest = blitz.iter(Person, &people).minByKey(u32, struct {
    fn getAge(p: Person) u32 { return p.age; }
}.getAge);
// Returns Person{"Bob", 25}
```

**Parameters**:
- `K`: Key type (must be comparable)
- `keyFn`: `fn(T) K` - Function to extract key from element

#### `.maxByKey(K, keyFn) ?T`

Find maximum element by extracting a comparable key.

---

### Mutation Methods

These methods require `iterMut` (mutable iterator).

#### `.mapInPlace(transform) void`

Transform each element in place.

```zig
var data = [_]i64{ 1, 2, 3, 4, 5 };

// Double all elements
blitz.iterMut(i64, &data).mapInPlace(struct {
    fn double(x: i64) i64 { return x * 2; }
}.double);
// data is now [2, 4, 6, 8, 10]

// Square all elements
blitz.iterMut(i64, &data).mapInPlace(struct {
    fn square(x: i64) i64 { return x * x; }
}.square);
```

**Parameters**:
- `transform`: `fn(T) T` - Function to transform each element

#### `.fill(value) void`

Set all elements to a value.

```zig
var data = [_]i64{ 1, 2, 3, 4, 5 };
blitz.iterMut(i64, &data).fill(0);
// data is now [0, 0, 0, 0, 0]
```

#### `.forEach(fn) void`

Execute a function for each element (with mutable access).

```zig
var data = [_]i64{ 1, 2, 3, 4, 5 };

// Increment each element
blitz.iterMut(i64, &data).forEach(struct {
    fn increment(x: *i64) void { x.* += 1; }
}.increment);
// data is now [2, 3, 4, 5, 6]
```

**Parameters**:
- `fn`: `fn(*T) void` - Function receiving pointer to each element

**Warning**: The function receives a pointer. Modifications are visible after the call completes.

---

### Iterator Combinators

#### `.chain(other) ChainIterator`

Concatenate two iterators.

```zig
const a = [_]i64{ 1, 2, 3 };
const b = [_]i64{ 4, 5, 6 };

const sum = blitz.iter(i64, &a)
    .chain(blitz.iter(i64, &b))
    .sum();  // 21
```

**Notes**: Both iterators must have the same element type.

#### `.zip(other) ZipIterator`

Pair elements from two iterators.

```zig
const keys = [_][]const u8{ "a", "b", "c" };
const values = [_]i64{ 1, 2, 3 };

blitz.iter([]const u8, &keys)
    .zip(blitz.iter(i64, &values))
    .forEach(struct {
        fn process(pair: struct { []const u8, i64 }) void {
            std.debug.print("{s} = {}\n", .{ pair[0], pair[1] });
        }
    }.process);
```

**Notes**: Stops at the shorter iterator's length.

#### `.chunks(size) ChunksIterator`

Process elements in fixed-size chunks.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8 };

blitz.iter(i64, &data).chunks(3).forEach(struct {
    fn processChunk(chunk: []const i64) void {
        // chunk is [1,2,3], then [4,5,6], then [7,8]
    }
}.processChunk);
```

#### `.enumerate() EnumerateIterator`

Add indices to elements.

```zig
const data = [_][]const u8{ "apple", "banana", "cherry" };

blitz.iter([]const u8, &data).enumerate().forEach(struct {
    fn print(item: struct { usize, []const u8 }) void {
        std.debug.print("{}: {s}\n", .{ item[0], item[1] });
    }
}.print);
// 0: apple
// 1: banana
// 2: cherry
```

#### `flatten(T, slices) FlattenIterator`

Flatten nested slices into a single parallel iterator.

```zig
const a = [_]i64{ 1, 2, 3 };
const b = [_]i64{ 4, 5 };
const c = [_]i64{ 6, 7, 8, 9 };

const nested = [_][]const i64{ &a, &b, &c };

const sum = blitz.flatten([]const i64, &nested).sum();  // 45
```

---

## Fork-Join API

For divide-and-conquer algorithms and parallel task execution.

### `join(tasks) Result`

Execute multiple tasks in parallel and collect results.

```zig
// Function pointers (no arguments)
const result = blitz.join(.{
    .user = fetchUser,
    .posts = fetchPosts,
});
// result.user, result.posts

// With arguments: tuple of (function, arg)
const result = blitz.join(.{
    .user = .{ fetchUserById, user_id },
    .posts = .{ fetchPostsByUser, user_id },
});
```

**Parameters**: Anonymous struct where each field is either:
- A function pointer (no arguments)
- A tuple `.{ function, argument }`

**Returns**: Struct with same field names, containing each task's return value.

**Example - Parallel data fetching**:
```zig
fn loadDashboard(user_id: u64) Dashboard {
    const data = blitz.join(.{
        .profile = .{ fetchProfile, user_id },
        .notifications = .{ fetchNotifications, user_id },
        .recommendations = .{ fetchRecommendations, user_id },
        .settings = loadUserSettings,
    });

    return Dashboard{
        .profile = data.profile,
        .notifications = data.notifications,
        .recommendations = data.recommendations,
        .settings = data.settings,
    };
}
```

**Example - Recursive divide and conquer**:
```zig
fn parallelSum(data: []const i64) i64 {
    if (data.len < 1000) {
        // Base case: sequential
        var sum: i64 = 0;
        for (data) |x| sum += x;
        return sum;
    }

    const mid = data.len / 2;
    const r = blitz.join(.{
        .left = .{ parallelSum, data[0..mid] },
        .right = .{ parallelSum, data[mid..] },
    });
    return r.left + r.right;
}
```

**Best Practices**:
- Always have a sequential base case for recursive algorithms
- Threshold should be large enough that parallel overhead is negligible (~1000+ elements)
- Tasks should have similar workloads for best load balancing

### `tryJoin(RetA, RetB, E, fnA, fnB, argA, argB) !struct { a: RetA, b: RetB }`

Error-safe binary join. Task B always completes even if A fails.

```zig
const MyError = error{ NetworkError, ParseError };

fn fetchData(url: []const u8) MyError!Data { ... }
fn fetchConfig(path: []const u8) MyError!Config { ... }

const result = try blitz.tryJoin(
    Data, Config, MyError,
    fetchData, fetchConfig,
    "https://api.example.com/data",
    "/etc/app/config.json",
);
// result.a is Data, result.b is Config
```

**Notes**:
- If A fails, B still runs to completion
- If B fails, A still runs to completion
- Returns first error encountered

### `scope(fn) void`

Execute a function that can spawn dynamic tasks.

```zig
blitz.scope(struct {
    fn run(s: *blitz.Scope) void {
        // Spawn tasks dynamically
        s.spawn(task1);
        s.spawn(.{ task2, arg });

        for (items) |item| {
            s.spawn(.{ processItem, item });
        }
    }
}.run);
// All spawned tasks complete before scope returns
```

**Limitations**:
- Maximum 64 concurrent spawns per scope
- Tasks cannot return values (use shared state or channels)

---

## Parallel Algorithms

### Sorting

All sort operations are in-place and use parallel PDQSort (Pattern-Defeating Quicksort).

#### `sortAsc(T, data) void`

Sort a slice in ascending order.

```zig
var data = [_]i64{ 5, 2, 8, 1, 9, 3 };
blitz.sortAsc(i64, &data);
// data is now [1, 2, 3, 5, 8, 9]
```

#### `sortDesc(T, data) void`

Sort a slice in descending order.

```zig
var data = [_]i64{ 5, 2, 8, 1, 9, 3 };
blitz.sortDesc(i64, &data);
// data is now [9, 8, 5, 3, 2, 1]
```

#### `sort(T, data, lessThan) void`

Sort with a custom comparator.

```zig
var data = [_]i64{ 5, -2, 8, -1, 9 };

// Sort by absolute value
blitz.sort(i64, &data, struct {
    fn byAbs(a: i64, b: i64) bool {
        return @abs(a) < @abs(b);
    }
}.byAbs);
```

#### `sortByKey(T, K, data, keyFn) void`

Sort by extracting a comparable key from each element.

```zig
const Person = struct { name: []const u8, age: u32 };
var people: []Person = ...;

// Sort by age
blitz.sortByKey(Person, u32, &people, struct {
    fn getAge(p: Person) u32 { return p.age; }
}.getAge);
```

#### `sortByCachedKey(T, K, allocator, data, keyFn) !void`

Two-phase sort: compute keys in parallel, then sort by cached keys. Use when key computation is expensive.

```zig
try blitz.sortByCachedKey(Person, u32, allocator, &people, struct {
    fn expensiveScore(p: Person) u32 {
        return computeComplexScore(p);  // Only called once per element
    }
}.expensiveScore);
```

**Algorithm**: Pattern-Defeating Quicksort (PDQSort)
- O(n log n) average case
- O(n) for sorted/reverse-sorted inputs (adaptive)
- O(n²) worst case (rare, requires adversarial input)

**Memory**:
- `sort`, `sortAsc`, `sortDesc`, `sortByKey`: O(log n) stack depth
- `sortByCachedKey`: O(n) for key cache

### Scan (Prefix Sum)

#### `parallelScan(T, input, output) void`

Compute inclusive prefix sum.

```zig
const input = [_]i64{ 1, 2, 3, 4, 5 };
var output: [5]i64 = undefined;

blitz.parallelScan(i64, &input, &output);
// output = [1, 3, 6, 10, 15]
// output[i] = sum of input[0..i+1]
```

#### `parallelScanExclusive(T, input, output) void`

Compute exclusive prefix sum.

```zig
const input = [_]i64{ 1, 2, 3, 4, 5 };
var output: [5]i64 = undefined;

blitz.parallelScanExclusive(i64, &input, &output);
// output = [0, 1, 3, 6, 10]
// output[i] = sum of input[0..i]
```

### Find and Partition

#### `parallelFind(T, data, predicate) ?usize`

Find the index of the first element matching the predicate.

```zig
const data = [_]i64{ 1, 3, 5, 6, 7, 9 };
if (blitz.parallelFind(i64, &data, isEven)) |idx| {
    std.debug.print("First even at index {}\n", .{idx});  // 3
}
```

#### `parallelFindValue(T, data, value) ?usize`

Find the index of a specific value.

```zig
const data = [_]i64{ 1, 2, 3, 4, 5 };
if (blitz.parallelFindValue(i64, &data, 3)) |idx| {
    std.debug.print("Found 3 at index {}\n", .{idx});  // 2
}
```

#### `parallelPartition(T, data, predicate) usize`

Partition data so matching elements come first.

```zig
var data = [_]i64{ 1, -2, 3, -4, 5, -6 };
const pivot = blitz.parallelPartition(i64, &data, isNegative);
// data[0..pivot] are negative
// data[pivot..] are non-negative
```

---

## Low-Level API

For fine-grained control over parallelism.

### `parallelFor(n, Context, ctx, body) void`

Execute a function in parallel over a range.

```zig
const Context = struct {
    data: []f64,
    multiplier: f64,
};

blitz.parallelFor(data.len, Context, .{
    .data = data,
    .multiplier = 2.0,
}, struct {
    fn body(ctx: Context, start: usize, end: usize) void {
        for (ctx.data[start..end]) |*x| {
            x.* *= ctx.multiplier;
        }
    }
}.body);
```

### `parallelForWithGrain(n, Context, ctx, body, grain) void`

Same as `parallelFor` but with explicit grain size.

```zig
// Use small grain for expensive operations
blitz.parallelForWithGrain(n, ctx, body, 100);

// Use large grain for cheap operations
blitz.parallelForWithGrain(n, ctx, body, 10000);
```

### `parallelReduce(T, n, identity, Context, ctx, map, reduce) T`

Parallel map-reduce with full control.

```zig
// Sum of squares
const sum_sq = blitz.parallelReduce(
    i64,                    // Result type
    data.len,               // Range size
    0,                      // Identity
    []const i64,            // Context type
    data,                   // Context value
    struct {
        fn map(d: []const i64, i: usize) i64 {
            return d[i] * d[i];
        }
    }.map,
    struct {
        fn add(a: i64, b: i64) i64 {
            return a + b;
        }
    }.add,
);
```

---

## Configuration

### Grain Size

The grain size controls the minimum work unit. Smaller = more parallelism but more overhead.

#### `setGrainSize(size: usize) void`

Set the global grain size.

```zig
blitz.setGrainSize(1024);
```

#### `getGrainSize() usize`

Get the current grain size.

```zig
const grain = blitz.getGrainSize();
```

#### `defaultGrainSize() usize`

Get the default grain size (4096).

**Guidelines**:
| Operation Cost | Recommended Grain |
|----------------|-------------------|
| Trivial (add, compare) | 4096-10000 |
| Light (simple math) | 1024-4096 |
| Medium (string ops) | 256-1024 |
| Heavy (I/O, allocation) | 64-256 |

---

## Error Handling

Most Blitz operations don't return errors directly. Exceptions:

| Function | Error Conditions |
|----------|------------------|
| `init()` | Thread creation failure |
| `initWithConfig()` | Thread creation failure |
| `sortByCachedKey()` | Memory allocation failure |
| `tryJoin()` | Task error propagation |

For operations that can fail inside parallel tasks, use `tryJoin` or handle errors within the task:

```zig
blitz.iterMut(T, &data).forEach(struct {
    fn process(item: *T) void {
        processItem(item) catch |err| {
            // Handle error locally
            std.log.err("Failed: {}", .{err});
        };
    }
}.process);
```

---

## Thread Safety

| Component | Thread Safety |
|-----------|---------------|
| `iter()`, `iterMut()` | Create from any thread |
| Iterator methods | Execute on worker threads |
| `join()` | Safe from any thread |
| Input slices | Must not be modified during operation |
| Output of `iterMut` | Safe after operation completes |

**Important**: Do not modify input data while a parallel operation is running.
