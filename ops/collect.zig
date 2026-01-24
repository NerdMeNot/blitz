//! Parallel Collection operations for Blitz.
//!
//! Provides parallel collection primitives:
//! - parallelCollect: Parallel map with result collection
//! - parallelMapInPlace: Transform elements in-place
//! - parallelFlatten: Flatten nested slices
//! - parallelScatter: Scatter values using pre-computed offsets

const std = @import("std");
const runtime = @import("runtime.zig");
const parallel_for = @import("parallel_for.zig");
const sync = @import("../sync.zig");
pub const SyncPtr = sync.SyncPtr;
pub const computeOffsetsInto = sync.computeOffsetsInto;
pub const capAndOffsets = sync.capAndOffsets;

// ============================================================================
// parallelCollect() - Parallel Map with Result Collection
// ============================================================================

/// Parallel map that collects results into an output slice.
///
/// Maps each element of `input` through `map_fn` and stores the result
/// in `output`. Work is divided and stolen using the standard fork-join pattern.
///
/// This is equivalent to Rayon's `.par_iter().map().collect()`.
///
/// Requirements:
/// - `output.len` must equal `input.len`
/// - `map_fn` signature: `fn(Context, T) U`
pub fn parallelCollect(
    comptime T: type,
    comptime U: type,
    input: []const T,
    output: []U,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, T) U,
) void {
    parallelCollectWithGrain(T, U, input, output, Context, context, map_fn, runtime.getGrainSize());
}

/// Parallel map with custom grain size.
///
/// Use this when you need fine-grained control over parallelization granularity.
/// For most cases, prefer parallelCollect() which auto-tunes based on data size.
pub fn parallelCollectWithGrain(
    comptime T: type,
    comptime U: type,
    input: []const T,
    output: []U,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, T) U,
    grain_size: usize,
) void {
    std.debug.assert(input.len == output.len);

    if (input.len == 0) return;

    if (input.len <= grain_size or !runtime.isInitialized()) {
        for (input, output) |in_val, *out_val| {
            out_val.* = map_fn(context, in_val);
        }
        return;
    }

    const CollectContext = struct {
        input: []const T,
        output: []U,
        ctx: Context,
    };

    const collect_ctx = CollectContext{
        .input = input,
        .output = output,
        .ctx = context,
    };

    parallel_for.parallelForWithGrain(input.len, CollectContext, collect_ctx, struct {
        fn body(c: CollectContext, start: usize, end: usize) void {
            for (start..end) |i| {
                c.output[i] = map_fn(c.ctx, c.input[i]);
            }
        }
    }.body, grain_size);
}

// ============================================================================
// parallelMapInPlace() - Transform Elements In-Place
// ============================================================================

/// Parallel map in-place: transform elements without allocating new storage.
pub fn parallelMapInPlace(
    comptime T: type,
    data: []T,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, T) T,
) void {
    parallelMapInPlaceWithGrain(T, data, Context, context, map_fn, runtime.getGrainSize());
}

/// Parallel map in-place with custom grain size.
///
/// Use this when you need fine-grained control over parallelization granularity.
/// For most cases, prefer parallelMapInPlace() which auto-tunes based on data size.
pub fn parallelMapInPlaceWithGrain(
    comptime T: type,
    data: []T,
    comptime Context: type,
    context: Context,
    comptime map_fn: fn (Context, T) T,
    grain_size: usize,
) void {
    if (data.len == 0) return;

    if (data.len <= grain_size or !runtime.isInitialized()) {
        for (data) |*val| {
            val.* = map_fn(context, val.*);
        }
        return;
    }

    const MapContext = struct { data: []T, ctx: Context };
    const map_ctx = MapContext{ .data = data, .ctx = context };

    parallel_for.parallelForWithGrain(data.len, MapContext, map_ctx, struct {
        fn body(c: MapContext, start: usize, end: usize) void {
            for (c.data[start..end]) |*val| {
                val.* = map_fn(c.ctx, val.*);
            }
        }
    }.body, grain_size);
}

// ============================================================================
// parallelFlatten() - Parallel Flatten Nested Slices
// ============================================================================

/// Flatten nested slices into a single output slice in parallel.
///
/// This is the pattern used in Polars' `flatten_par` for combining
/// thread-local results into a single output array.
///
/// The algorithm:
/// 1. Compute offsets for each input slice (where it starts in output)
/// 2. Copy each slice to its designated output region in parallel
///
/// Requirements:
/// - `output.len` must equal the sum of all input slice lengths
/// - Pre-compute total length using `capAndOffsets` if needed
pub fn parallelFlatten(
    comptime T: type,
    slices: []const []const T,
    output: []T,
) void {
    parallelFlattenWithGrain(T, slices, output, 1); // Grain=1 since each slice is independent work
}

/// Parallel flatten with custom grain size (number of slices per task).
///
/// Use this when you need fine-grained control over parallelization granularity.
/// For most cases, prefer parallelFlatten() which auto-tunes.
pub fn parallelFlattenWithGrain(
    comptime T: type,
    slices: []const []const T,
    output: []T,
    grain_size: usize,
) void {
    if (slices.len == 0) return;

    // Compute offsets
    var offsets_buf: [1024]usize = undefined;
    const offsets = if (slices.len <= 1024)
        offsets_buf[0..slices.len]
    else blk: {
        // For very large slice counts, allocate (rare case)
        const allocator = std.heap.c_allocator;
        break :blk allocator.alloc(usize, slices.len) catch @panic("OOM");
    };
    defer if (slices.len > 1024) std.heap.c_allocator.free(offsets);

    const total = capAndOffsets(T, slices, offsets);
    std.debug.assert(output.len == total);

    if (slices.len <= grain_size or !runtime.isInitialized()) {
        // Sequential path
        for (slices, offsets) |slice, offset| {
            @memcpy(output[offset..][0..slice.len], slice);
        }
        return;
    }

    // Parallel path: each task copies its assigned slices
    const out_ptr = SyncPtr(T).init(output);

    const FlattenContext = struct {
        slices: []const []const T,
        offsets: []const usize,
        out_ptr: SyncPtr(T),
    };

    const flatten_ctx = FlattenContext{
        .slices = slices,
        .offsets = offsets,
        .out_ptr = out_ptr,
    };

    parallel_for.parallelForWithGrain(slices.len, FlattenContext, flatten_ctx, struct {
        fn body(c: FlattenContext, start: usize, end: usize) void {
            for (start..end) |i| {
                const slice = c.slices[i];
                const offset = c.offsets[i];
                c.out_ptr.copyAt(offset, slice);
            }
        }
    }.body, grain_size);
}

/// Flatten with pre-computed offsets (avoids recomputing).
/// Use this when you've already called `capAndOffsets` to get the total size.
pub fn parallelFlattenWithOffsets(
    comptime T: type,
    slices: []const []const T,
    offsets: []const usize,
    output: []T,
) void {
    if (slices.len == 0) return;

    std.debug.assert(offsets.len >= slices.len);

    if (slices.len <= 1 or !runtime.isInitialized()) {
        for (slices, offsets[0..slices.len]) |slice, offset| {
            @memcpy(output[offset..][0..slice.len], slice);
        }
        return;
    }

    const out_ptr = SyncPtr(T).init(output);

    const FlattenContext = struct {
        slices: []const []const T,
        offsets: []const usize,
        out_ptr: SyncPtr(T),
    };

    const flatten_ctx = FlattenContext{
        .slices = slices,
        .offsets = offsets,
        .out_ptr = out_ptr,
    };

    // Use grain size of 1 - each slice is independent
    parallel_for.parallelForWithGrain(slices.len, FlattenContext, flatten_ctx, struct {
        fn body(c: FlattenContext, start: usize, end: usize) void {
            for (start..end) |i| {
                const slice = c.slices[i];
                const offset = c.offsets[i];
                c.out_ptr.copyAt(offset, slice);
            }
        }
    }.body, 1);
}

// ============================================================================
// parallelScatter() - Parallel Scatter with Pre-computed Offsets
// ============================================================================

/// Scatter values to output using pre-computed offsets.
///
/// This is the pattern used in Polars' BUILD phase where each thread
/// scatters its partition to pre-computed locations in the output.
///
/// Each element `values[i]` is written to `output[offsets[i]]`.
/// After completion, `offsets[i]` is incremented by 1 (for multi-value scatter).
pub fn parallelScatter(
    comptime T: type,
    values: []const T,
    indices: []const usize,
    output: []T,
) void {
    std.debug.assert(values.len == indices.len);

    if (values.len == 0) return;

    if (values.len <= runtime.getGrainSize() or !runtime.isInitialized()) {
        for (values, indices) |val, idx| {
            output[idx] = val;
        }
        return;
    }

    const out_ptr = SyncPtr(T).init(output);

    const ScatterContext = struct {
        values: []const T,
        indices: []const usize,
        out_ptr: SyncPtr(T),
    };

    const scatter_ctx = ScatterContext{
        .values = values,
        .indices = indices,
        .out_ptr = out_ptr,
    };

    parallel_for.parallelFor(values.len, ScatterContext, scatter_ctx, struct {
        fn body(c: ScatterContext, start: usize, end: usize) void {
            for (start..end) |i| {
                c.out_ptr.writeAt(c.indices[i], c.values[i]);
            }
        }
    }.body);
}

// ============================================================================
// Tests
// ============================================================================

test "parallelCollect - basic" {
    var input: [100]i32 = undefined;
    var output: [100]i64 = undefined;

    for (&input, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    parallelCollect(i32, i64, &input, &output, void, {}, struct {
        fn map(_: void, x: i32) i64 {
            return @as(i64, x) * 2;
        }
    }.map);

    for (output, 0..) |v, i| {
        try std.testing.expectEqual(@as(i64, @intCast(i * 2)), v);
    }
}

test "parallelCollect - empty" {
    var input: [0]i32 = undefined;
    var output: [0]i64 = undefined;

    parallelCollect(i32, i64, &input, &output, void, {}, struct {
        fn map(_: void, x: i32) i64 {
            return x;
        }
    }.map);
}

test "parallelMapInPlace - basic" {
    var data: [100]i32 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    parallelMapInPlace(i32, &data, void, {}, struct {
        fn map(_: void, x: i32) i32 {
            return x * 3;
        }
    }.map);

    for (data, 0..) |v, i| {
        try std.testing.expectEqual(@as(i32, @intCast(i * 3)), v);
    }
}

test "parallelFlatten - basic" {
    const slice0 = [_]u32{ 1, 2, 3 };
    const slice1 = [_]u32{ 4, 5 };
    const slice2 = [_]u32{ 6, 7, 8, 9 };

    const slices = [_][]const u32{ &slice0, &slice1, &slice2 };
    var output: [9]u32 = undefined;

    parallelFlatten(u32, &slices, &output);

    const expected = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    try std.testing.expectEqualSlices(u32, &expected, &output);
}

test "parallelFlatten - empty slices" {
    const slice0 = [_]u32{ 1, 2 };
    const slice1 = [_]u32{};
    const slice2 = [_]u32{3};

    const slices = [_][]const u32{ &slice0, &slice1, &slice2 };
    var output: [3]u32 = undefined;

    parallelFlatten(u32, &slices, &output);

    const expected = [_]u32{ 1, 2, 3 };
    try std.testing.expectEqualSlices(u32, &expected, &output);
}

test "parallelFlattenWithOffsets - basic" {
    const slice0 = [_]u64{ 10, 20 };
    const slice1 = [_]u64{ 30, 40, 50 };

    const slices = [_][]const u64{ &slice0, &slice1 };
    var offsets: [2]usize = undefined;
    const total = capAndOffsets(u64, &slices, &offsets);

    try std.testing.expectEqual(@as(usize, 5), total);
    try std.testing.expectEqual(@as(usize, 0), offsets[0]);
    try std.testing.expectEqual(@as(usize, 2), offsets[1]);

    var output: [5]u64 = undefined;
    parallelFlattenWithOffsets(u64, &slices, &offsets, &output);

    const expected = [_]u64{ 10, 20, 30, 40, 50 };
    try std.testing.expectEqualSlices(u64, &expected, &output);
}

test "parallelScatter - basic" {
    const values = [_]u32{ 100, 200, 300, 400 };
    const indices = [_]usize{ 3, 0, 7, 1 };
    var output: [10]u32 = undefined;
    @memset(&output, 0);

    parallelScatter(u32, &values, &indices, &output);

    try std.testing.expectEqual(@as(u32, 200), output[0]);
    try std.testing.expectEqual(@as(u32, 400), output[1]);
    try std.testing.expectEqual(@as(u32, 0), output[2]);
    try std.testing.expectEqual(@as(u32, 100), output[3]);
    try std.testing.expectEqual(@as(u32, 300), output[7]);
}

test "SyncPtr - parallel write simulation" {
    var buffer: [100]u64 = undefined;
    @memset(&buffer, 0);

    const ptr = SyncPtr(u64).init(&buffer);

    // Simulate what parallel threads would do
    // Thread 0: write to [0..25)
    for (0..25) |i| {
        ptr.writeAt(i, @intCast(i * 10));
    }

    // Thread 1: write to [25..50)
    for (25..50) |i| {
        ptr.writeAt(i, @intCast(i * 10));
    }

    // Thread 2: write to [50..75)
    for (50..75) |i| {
        ptr.writeAt(i, @intCast(i * 10));
    }

    // Thread 3: write to [75..100)
    for (75..100) |i| {
        ptr.writeAt(i, @intCast(i * 10));
    }

    // Verify all writes
    for (buffer, 0..) |v, i| {
        try std.testing.expectEqual(@as(u64, i * 10), v);
    }
}
