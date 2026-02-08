---
title: Error Handling
description: Error-safe parallel operations with tryJoin, tryForEach, and tryReduce
slug: v2.0.0-zig0.15.3/1.0.0-zig0.15.2/usage/error-handling
---

Error-safe parallel operations that guarantee all tasks complete before any error propagates. This is critical for safety when parallel tasks reference the caller's stack frame.

## The Error Safety Guarantee

When parallel tasks return errors, Blitz ensures that **all tasks run to completion** before propagating the error. Without this guarantee, a task could still be running when its caller's stack frame is destroyed.

```
UNSAFE (not how Blitz works):
  tryJoin(A, B)
  A returns error → propagate immediately → B still running!
  Stack frame destroyed → B accesses invalid memory → crash

SAFE (how Blitz works):
  tryJoin(A, B)
  A returns error → wait for B to finish → then propagate error
  Both complete → stack frame valid throughout → safe
```

This mirrors Rayon's panic safety principle: "No matter what happens, both closures will always be executed."

**Note on Zig panics**: This safety applies only to recoverable errors (Zig error unions). If a function calls `@panic`, the program terminates immediately regardless.

## tryJoin

Execute multiple error-returning tasks in parallel. All tasks complete even if some return errors. The merged error set is returned.

```zig
const blitz = @import("blitz");

fn fetchUser(id: u64) !User {
    // May fail with network/parse errors
    return db.query("SELECT * FROM users WHERE id = ?", id);
}

fn fetchPosts(user_id: u64) ![]Post {
    return db.query("SELECT * FROM posts WHERE user_id = ?", user_id);
}

// Both queries run in parallel
const result = try blitz.tryJoin(.{
    .user = .{ fetchUser, @as(u64, 42) },
    .posts = .{ fetchPosts, @as(u64, 42) },
});

// result.user: User
// result.posts: []Post
```

### Error Merging

`tryJoin` merges the error sets of all tasks into a single error union:

```zig
fn taskA() error{NetworkError}!i32 { ... }
fn taskB() error{ParseError,IoError}![]u8 { ... }

// Return type: error{NetworkError,ParseError,IoError}!struct { a: i32, b: []u8 }
const result = try blitz.tryJoin(.{
    .a = taskA,
    .b = taskB,
});
```

### Without Arguments

```zig
const result = try blitz.tryJoin(.{
    .config = loadConfig,     // fn() !Config
    .cache = warmCache,       // fn() !CacheStats
});
```

### With Arguments

```zig
const result = try blitz.tryJoin(.{
    .user = .{ fetchUser, user_id },
    .posts = .{ fetchPostsByUser, user_id },
    .settings = .{ loadSettings, user_id, "default" },
});
```

### Multiple Tasks

```zig
const result = try blitz.tryJoin(.{
    .a = .{ validateInput, input_a },
    .b = .{ validateInput, input_b },
    .c = .{ validateInput, input_c },
    .d = .{ validateInput, input_d },
});
// All four validations run in parallel
// If any returns an error, all others still complete first
```

### Sequential Fallback

When one task fails, the remaining tasks still execute. In the two-task case, if the first task (which runs locally) returns an error, the second task is guaranteed to complete before the error propagates:

```zig
const result = blitz.tryJoin(.{
    .a = failingTask,    // Returns an error
    .b = slowButValid,   // Still runs to completion!
});
// Error from .a propagated only after .b finishes
```

If the second task was not stolen by another worker, it runs sequentially on the calling thread. This ensures correctness even when parallelism is limited.

## tryForEach

Parallel iteration where the body can return an error. All chunks complete before any error propagates.

```zig
const E = error{ InvalidData, Overflow };

const result = blitz.tryForEach(
    data.len,        // Element count
    E,               // Error type
    []const f64,     // Context type
    data,            // Context value
    struct {
        fn body(d: []const f64, start: usize, end: usize) E!void {
            for (d[start..end]) |val| {
                if (std.math.isNan(val)) return error.InvalidData;
                if (val > 1e308) return error.Overflow;
            }
        }
    }.body,
);

// Handle the result
result catch |err| switch (err) {
    error.InvalidData => std.debug.print("Found NaN in data\n", .{}),
    error.Overflow => std.debug.print("Value overflow detected\n", .{}),
};
```

### Contrast with parallelFor

```zig
// Non-error variant: body returns void, cannot fail
blitz.parallelFor(n, Context, ctx, struct {
    fn body(c: Context, start: usize, end: usize) void {
        for (c.data[start..end]) |*v| {
            v.* = transform(v.*);
        }
    }
}.body);

// Error variant: body returns E!void, first error propagated after all complete
blitz.tryForEach(n, E, Context, ctx, struct {
    fn body(c: Context, start: usize, end: usize) E!void {
        for (c.data[start..end]) |*v| {
            v.* = try fallibleTransform(v.*);
        }
    }
}.body) catch |err| {
    // Handle error — all parallel work has finished
};
```

### Error Priority

When multiple chunks fail, `tryForEach` returns the first error encountered in execution order (not index order). Since chunks execute in parallel, the "first" error depends on scheduling.

```zig
// If chunk [0..500) and [500..1000) both fail,
// the error from whichever finishes first is returned.
// Both chunks always run to completion regardless.
```

## tryReduce

Parallel map-reduce where the map function can fail. Combines error handling with reduction.

```zig
const E = error{ParseError};

const Context = struct {
    raw_data: []const []const u8,
};

const total = try blitz.tryReduce(
    i64,                 // Result type
    E,                   // Error type
    raw_data.len,        // Element count
    0,                   // Identity element
    Context,             // Context type
    .{ .raw_data = raw_data },  // Context value
    struct {
        fn map(ctx: Context, i: usize) E!i64 {
            return std.fmt.parseInt(i64, ctx.raw_data[i], 10) catch
                return error.ParseError;
        }
    }.map,
    struct {
        fn combine(a: i64, b: i64) i64 {
            return a + b;
        }
    }.combine,
);
// total: sum of all parsed values, or error.ParseError
```

### Key Differences from parallelReduce

| Feature | `parallelReduce` | `tryReduce` |
|---------|-----------------|-------------|
| Map signature | `fn(Context, usize) T` | `fn(Context, usize) E!T` |
| Return type | `T` | `E!T` |
| On error | N/A (cannot fail) | All work completes, then error propagates |
| Combine signature | `fn(T, T) T` | `fn(T, T) T` (same -- infallible) |

Note that the `combine` function is always infallible. Only the `map` function can return errors. If your combine operation can fail, handle it within the map step or restructure the computation.

## Error Handling Patterns

### Pattern 1: Validate Then Process

Separate validation (fallible) from processing (infallible):

```zig
// Step 1: Validate all data in parallel (may fail)
try blitz.tryForEach(data.len, ValidationError, Context, ctx, struct {
    fn validate(c: Context, start: usize, end: usize) ValidationError!void {
        for (c.data[start..end]) |val| {
            if (!isValid(val)) return error.InvalidInput;
        }
    }
}.validate);

// Step 2: Process (guaranteed valid, no error handling needed)
blitz.parallelFor(data.len, Context, ctx, struct {
    fn process(c: Context, start: usize, end: usize) void {
        for (c.data[start..end]) |*val| {
            val.* = transform(val.*);
        }
    }
}.process);
```

### Pattern 2: Collect Errors per Chunk

Accumulate errors instead of short-circuiting:

```zig
const ErrorLog = struct {
    errors: std.atomic.Value(usize),
};

var error_log = ErrorLog{
    .errors = std.atomic.Value(usize).init(0),
};

blitz.parallelFor(data.len, *ErrorLog, &error_log, struct {
    fn body(log: *ErrorLog, start: usize, end: usize) void {
        for (start..end) |i| {
            if (!processItem(i)) {
                _ = log.errors.fetchAdd(1, .monotonic);
            }
        }
    }
}.body);

const error_count = error_log.errors.load(.monotonic);
if (error_count > 0) {
    std.debug.print("Encountered {d} errors\n", .{error_count});
}
```

### Pattern 3: tryJoin with Fallback

```zig
const result = blitz.tryJoin(.{
    .primary = .{ fetchFromPrimary, key },
    .backup = .{ fetchFromBackup, key },
}) catch |err| {
    std.log.warn("Both sources failed: {}", .{err});
    return default_value;
};

// Use whichever result is preferred
const value = result.primary;
```

## When to Use Error Variants

| Scenario | Use | Why |
|----------|-----|-----|
| All operations are infallible | `join`, `parallelFor`, `parallelReduce` | No error overhead |
| Any operation can fail | `tryJoin`, `tryForEach`, `tryReduce` | Error safety guarantee |
| Errors are rare/exceptional | `tryForEach` | Short-circuits on failure |
| Need error counts, not early exit | `parallelFor` + atomic counter | More control |
| Validation pass | `tryForEach` | Fail fast with safety |
| Parsing/conversion | `tryReduce` | Combine results, propagate first error |

## Sequential Fallback Behavior

When the thread pool is not initialized (or for small inputs), all `try*` operations fall back to sequential execution:

```zig
// Without blitz.init(), this runs sequentially:
const result = try blitz.tryForEach(n, E, Context, ctx, bodyFn);
// Equivalent to:
//   for (0..n) |i| try bodyFn(ctx, i, i+1);
```

The error safety guarantee is maintained even in sequential mode -- but since there is only one thread, it is trivially satisfied.
