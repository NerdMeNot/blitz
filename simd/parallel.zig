//! Parallel SIMD Operations
//!
//! Combines multi-threading with SIMD for maximum performance on large arrays.

const std = @import("std");
const api = @import("../api.zig");
const threshold_mod = @import("../internal/threshold.zig");
const aggregations = @import("aggregations.zig");
const argminmax = @import("argminmax.zig");

const ArgResult = argminmax.ArgResult;

// ============================================================================
// Threshold Calculation
// ============================================================================

/// SIMD efficiency factor - SIMD is ~100x faster than scalar
const SIMD_EFFICIENCY_FACTOR: usize = 100;

/// Calculate the parallel threshold for SIMD operations dynamically.
/// Returns the minimum array size where parallelism beats SIMD-only.
pub fn calculateParallelThreshold(op: threshold_mod.OpType) usize {
    const base_threshold = threshold_mod.getThreshold(op);

    // If the base returns maxInt (no workers), propagate that
    if (base_threshold == std.math.maxInt(usize)) {
        return base_threshold;
    }

    // SIMD is already vectorized, so we need more data to justify
    // the overhead of thread synchronization
    return base_threshold * SIMD_EFFICIENCY_FACTOR;
}

/// Get the parallel threshold for sum operations.
pub fn getParallelThreshold() usize {
    return calculateParallelThreshold(.sum);
}

/// Check if we should parallelize based on operation type and data size.
pub fn shouldParallelizeSimd(op: threshold_mod.OpType, len: usize) bool {
    // Memory-bound operations never benefit
    if (threshold_mod.isMemoryBound(op)) {
        return false;
    }

    // Check if pool is initialized
    if (!api.isInitialized()) {
        return false;
    }

    // Use dynamic threshold calculation
    return len >= calculateParallelThreshold(op);
}

// ============================================================================
// Parallel Sum/Min/Max
// ============================================================================

/// Parallel SIMD sum - divides work across threads, each using SIMD.
pub fn parallelSum(comptime T: type, data: []const T) T {
    if (data.len == 0) return 0;

    // For small/medium data, just use SIMD (no parallelism overhead)
    if (!shouldParallelizeSimd(.sum, data.len)) {
        return aggregations.sum(T, data);
    }

    const Context = struct { slice: []const T };
    const ctx = Context{ .slice = data };

    return api.parallelReduceChunked(
        T,
        data.len,
        0,
        Context,
        ctx,
        struct {
            fn mapChunk(c: Context, start: usize, end: usize) T {
                return aggregations.sum(T, c.slice[start..end]);
            }
        }.mapChunk,
        struct {
            fn combine(a: T, b: T) T {
                return a + b;
            }
        }.combine,
        8192,
    );
}

/// Parallel SIMD max - divides work across threads, each using SIMD.
pub fn parallelMax(comptime T: type, data: []const T) ?T {
    if (data.len == 0) return null;

    if (!shouldParallelizeSimd(.max, data.len)) {
        return aggregations.max(T, data);
    }

    const Context = struct { slice: []const T };
    const ctx = Context{ .slice = data };

    const min_val: T = if (@typeInfo(T) == .float) -std.math.inf(T) else std.math.minInt(T);

    const result = api.parallelReduceChunked(
        T,
        data.len,
        min_val,
        Context,
        ctx,
        struct {
            fn mapChunk(c: Context, start: usize, end: usize) T {
                const chunk_min: T = if (@typeInfo(T) == .float) -std.math.inf(T) else std.math.minInt(T);
                return aggregations.max(T, c.slice[start..end]) orelse chunk_min;
            }
        }.mapChunk,
        struct {
            fn combine(a: T, b: T) T {
                return @max(a, b);
            }
        }.combine,
        8192,
    );

    return if (result == min_val) null else result;
}

/// Parallel SIMD min - divides work across threads, each using SIMD.
pub fn parallelMin(comptime T: type, data: []const T) ?T {
    if (data.len == 0) return null;

    if (!shouldParallelizeSimd(.min, data.len)) {
        return aggregations.min(T, data);
    }

    const Context = struct { slice: []const T };
    const ctx = Context{ .slice = data };

    const max_val: T = if (@typeInfo(T) == .float) std.math.inf(T) else std.math.maxInt(T);

    const result = api.parallelReduceChunked(
        T,
        data.len,
        max_val,
        Context,
        ctx,
        struct {
            fn mapChunk(c: Context, start: usize, end: usize) T {
                const chunk_max: T = if (@typeInfo(T) == .float) std.math.inf(T) else std.math.maxInt(T);
                return aggregations.min(T, c.slice[start..end]) orelse chunk_max;
            }
        }.mapChunk,
        struct {
            fn combine(a: T, b: T) T {
                return @min(a, b);
            }
        }.combine,
        8192,
    );

    return if (result == max_val) null else result;
}

// ============================================================================
// Parallel Argmin/Argmax
// ============================================================================

/// Parallel SIMD argmin - returns minimum value and its index.
pub fn parallelArgmin(comptime T: type, data: []const T) ?ArgResult(T) {
    if (data.len == 0) return null;

    if (!shouldParallelizeSimd(.min, data.len)) {
        return argminmax.argmin(T, data);
    }

    const Context = struct { slice: []const T };
    const ctx = Context{ .slice = data };

    const ChunkResult = struct {
        value: T,
        index: usize,
        valid: bool,
    };

    const identity = ChunkResult{
        .value = if (@typeInfo(T) == .int) std.math.maxInt(T) else std.math.floatMax(T),
        .index = 0,
        .valid = false,
    };

    const result = api.parallelReduceChunked(
        ChunkResult,
        data.len,
        identity,
        Context,
        ctx,
        struct {
            fn mapChunk(c: Context, start: usize, end: usize) ChunkResult {
                const chunk = c.slice[start..end];
                if (argminmax.argmin(T, chunk)) |local_result| {
                    return .{
                        .value = local_result.value,
                        .index = start + local_result.index,
                        .valid = true,
                    };
                }
                return .{
                    .value = if (@typeInfo(T) == .int) std.math.maxInt(T) else std.math.floatMax(T),
                    .index = 0,
                    .valid = false,
                };
            }
        }.mapChunk,
        struct {
            fn combine(a: ChunkResult, b: ChunkResult) ChunkResult {
                if (!a.valid) return b;
                if (!b.valid) return a;
                if (b.value < a.value) return b;
                if (a.value < b.value) return a;
                return if (a.index <= b.index) a else b;
            }
        }.combine,
        8192,
    );

    return if (result.valid) .{ .value = result.value, .index = result.index } else null;
}

/// Parallel SIMD argmax - returns maximum value and its index.
pub fn parallelArgmax(comptime T: type, data: []const T) ?ArgResult(T) {
    if (data.len == 0) return null;

    if (!shouldParallelizeSimd(.max, data.len)) {
        return argminmax.argmax(T, data);
    }

    const Context = struct { slice: []const T };
    const ctx = Context{ .slice = data };

    const ChunkResult = struct {
        value: T,
        index: usize,
        valid: bool,
    };

    const identity = ChunkResult{
        .value = if (@typeInfo(T) == .int) std.math.minInt(T) else -std.math.floatMax(T),
        .index = 0,
        .valid = false,
    };

    const result = api.parallelReduceChunked(
        ChunkResult,
        data.len,
        identity,
        Context,
        ctx,
        struct {
            fn mapChunk(c: Context, start: usize, end: usize) ChunkResult {
                const chunk = c.slice[start..end];
                if (argminmax.argmax(T, chunk)) |local_result| {
                    return .{
                        .value = local_result.value,
                        .index = start + local_result.index,
                        .valid = true,
                    };
                }
                return .{
                    .value = if (@typeInfo(T) == .int) std.math.minInt(T) else -std.math.floatMax(T),
                    .index = 0,
                    .valid = false,
                };
            }
        }.mapChunk,
        struct {
            fn combine(a: ChunkResult, b: ChunkResult) ChunkResult {
                if (!a.valid) return b;
                if (!b.valid) return a;
                if (b.value > a.value) return b;
                if (a.value > b.value) return a;
                return if (a.index <= b.index) a else b;
            }
        }.combine,
        8192,
    );

    return if (result.valid) .{ .value = result.value, .index = result.index } else null;
}

// ============================================================================
// Parallel Argmin/Argmax By Key
// ============================================================================

/// Parallel SIMD argmin by key - extracts keys in parallel, then finds argmin.
pub fn parallelArgminByKey(
    comptime T: type,
    comptime K: type,
    allocator: std.mem.Allocator,
    data: []const T,
    comptime key_fn: fn (T) K,
) ?usize {
    if (data.len == 0) return null;
    if (data.len == 1) return 0;

    // For small arrays, use scalar
    if (data.len < 1024) {
        var best_idx: usize = 0;
        var best_key = key_fn(data[0]);
        for (data[1..], 1..) |item, i| {
            const key = key_fn(item);
            if (key < best_key) {
                best_key = key;
                best_idx = i;
            }
        }
        return best_idx;
    }

    // Phase 1: Extract keys in parallel
    const keys = allocator.alloc(K, data.len) catch {
        var best_idx: usize = 0;
        var best_key = key_fn(data[0]);
        for (data[1..], 1..) |item, i| {
            const key = key_fn(item);
            if (key < best_key) {
                best_key = key;
                best_idx = i;
            }
        }
        return best_idx;
    };
    defer allocator.free(keys);

    const KeyContext = struct { items: []const T, keys: []K };
    api.parallelFor(data.len, KeyContext, .{ .items = data, .keys = keys }, struct {
        fn body(ctx: KeyContext, start: usize, end: usize) void {
            for (start..end) |i| {
                ctx.keys[i] = key_fn(ctx.items[i]);
            }
        }
    }.body);

    // Phase 2: SIMD argmin on keys
    if (parallelArgmin(K, keys)) |result| {
        return result.index;
    }
    return null;
}

/// Parallel SIMD argmax by key - extracts keys in parallel, then finds argmax.
pub fn parallelArgmaxByKey(
    comptime T: type,
    comptime K: type,
    allocator: std.mem.Allocator,
    data: []const T,
    comptime key_fn: fn (T) K,
) ?usize {
    if (data.len == 0) return null;
    if (data.len == 1) return 0;

    // For small arrays, use scalar
    if (data.len < 1024) {
        var best_idx: usize = 0;
        var best_key = key_fn(data[0]);
        for (data[1..], 1..) |item, i| {
            const key = key_fn(item);
            if (key > best_key) {
                best_key = key;
                best_idx = i;
            }
        }
        return best_idx;
    }

    // Phase 1: Extract keys in parallel
    const keys = allocator.alloc(K, data.len) catch {
        var best_idx: usize = 0;
        var best_key = key_fn(data[0]);
        for (data[1..], 1..) |item, i| {
            const key = key_fn(item);
            if (key > best_key) {
                best_key = key;
                best_idx = i;
            }
        }
        return best_idx;
    };
    defer allocator.free(keys);

    const KeyContext = struct { items: []const T, keys: []K };
    api.parallelFor(data.len, KeyContext, .{ .items = data, .keys = keys }, struct {
        fn body(ctx: KeyContext, start: usize, end: usize) void {
            for (start..end) |i| {
                ctx.keys[i] = key_fn(ctx.items[i]);
            }
        }
    }.body);

    // Phase 2: SIMD argmax on keys
    if (parallelArgmax(K, keys)) |result| {
        return result.index;
    }
    return null;
}
