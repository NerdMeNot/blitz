//! Sort By Key Operations
//!
//! Sort elements by a key extraction function.
//! Includes both simple sortByKey and cached key sorting.

const std = @import("std");
const blitz = @import("../api.zig");
const pdqsort = @import("pdqsort.zig");

// ============================================================================
// Sort By Key
// ============================================================================

/// Sort by a key extraction function.
/// Keys are computed on each comparison.
///
/// For expensive key functions, use `sortByCachedKey` instead which
/// pre-computes all keys in parallel.
pub fn sortByKey(
    comptime T: type,
    comptime K: type,
    v: []T,
    comptime key_fn: fn (T) K,
) void {
    if (@sizeOf(T) == 0) return;
    if (v.len <= 1) return;

    pdqsort.sort(T, v, struct {
        fn lessThan(a: T, b: T) bool {
            return key_fn(a) < key_fn(b);
        }
    }.lessThan);
}

// ============================================================================
// Sort By Cached Key
// ============================================================================

/// Sort by key with parallel key caching.
/// Two-phase algorithm matching Rayon's `par_sort_by_cached_key`:
/// 1. Compute keys for all elements in parallel
/// 2. Sort by cached keys (no recomputation during sort)
///
/// This is more efficient than `sortByKey` when:
/// - The key function is expensive to compute
/// - The data is large (benefits from parallel key computation)
///
/// Uses an index-based sort to avoid copying large elements during sorting.
pub fn sortByCachedKey(
    comptime T: type,
    comptime K: type,
    allocator: std.mem.Allocator,
    v: []T,
    comptime key_fn: fn (T) K,
) !void {
    if (@sizeOf(T) == 0) return;
    if (v.len <= 1) return;

    // KeyIndex struct for parallel sorting
    const KeyIndex = struct {
        key: K,
        index: usize,
    };

    // Phase 1: Parallel key computation into KeyIndex array
    const key_indices = try allocator.alloc(KeyIndex, v.len);
    defer allocator.free(key_indices);

    const KeyContext = struct { data: []const T, key_indices: []KeyIndex };
    blitz.parallelFor(v.len, KeyContext, .{ .data = v, .key_indices = key_indices }, struct {
        fn body(ctx: KeyContext, start: usize, end: usize) void {
            for (start..end) |i| {
                ctx.key_indices[i] = .{
                    .key = key_fn(ctx.data[i]),
                    .index = i,
                };
            }
        }
    }.body);

    // Phase 2: Parallel sort KeyIndex array by key using PDQSort
    pdqsort.sort(KeyIndex, key_indices, struct {
        fn lessThan(a: KeyIndex, b: KeyIndex) bool {
            return a.key < b.key;
        }
    }.lessThan);

    // Phase 3: Apply permutation using sorted indices
    // For large arrays, use parallel copy-based permutation (faster despite extra memory)
    // For small arrays, use in-place cycle detection (more cache efficient)
    const PARALLEL_PERMUTATION_THRESHOLD = 10000;

    if (v.len >= PARALLEL_PERMUTATION_THRESHOLD) {
        // Parallel copy-based permutation
        const tmp = try allocator.alloc(T, v.len);
        defer allocator.free(tmp);

        // Phase 3a: Parallel gather from original positions to sorted positions
        const GatherCtx = struct { src: []const T, dst: []T, key_indices: []const KeyIndex };
        blitz.parallelFor(v.len, GatherCtx, .{ .src = v, .dst = tmp, .key_indices = key_indices }, struct {
            fn body(ctx: GatherCtx, start: usize, end: usize) void {
                for (start..end) |i| {
                    ctx.dst[i] = ctx.src[ctx.key_indices[i].index];
                }
            }
        }.body);

        // Phase 3b: Parallel copy back
        const CopyCtx = struct { src: []const T, dst: []T };
        blitz.parallelFor(v.len, CopyCtx, .{ .src = tmp, .dst = v }, struct {
            fn body(ctx: CopyCtx, start: usize, end: usize) void {
                @memcpy(ctx.dst[start..end], ctx.src[start..end]);
            }
        }.body);
    } else {
        // In-place cycle-based permutation for smaller arrays
        const indices = try allocator.alloc(usize, v.len);
        defer allocator.free(indices);

        for (key_indices, 0..) |ki, i| {
            indices[i] = ki.index;
        }

        applyPermutation(T, v, indices, allocator) catch {
            // Fallback: simple copy-based permutation
            const tmp = try allocator.alloc(T, v.len);
            defer allocator.free(tmp);
            for (indices, 0..) |idx, i| {
                tmp[i] = v[idx];
            }
            @memcpy(v, tmp);
        };
    }
}

/// Apply a permutation to a slice in-place using cycle detection.
/// This is O(n) time and O(1) extra space (besides the indices array).
pub fn applyPermutation(comptime T: type, v: []T, indices: []usize, allocator: std.mem.Allocator) !void {
    _ = allocator;

    // Use a visited bitmap to track which elements have been placed
    var visited = std.bit_set.DynamicBitSet.initEmpty(std.heap.c_allocator, v.len) catch {
        return error.OutOfMemory;
    };
    defer visited.deinit();

    for (0..v.len) |i| {
        if (visited.isSet(i)) continue;
        if (indices[i] == i) {
            visited.set(i);
            continue;
        }

        // Follow the cycle
        var j = i;
        const tmp = v[i];
        while (indices[j] != i) {
            const next = indices[j];
            v[j] = v[next];
            visited.set(j);
            j = next;
        }
        v[j] = tmp;
        visited.set(j);
    }
}
