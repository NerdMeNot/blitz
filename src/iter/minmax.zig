//! Min/Max operations for parallel iterators.
//!
//! Provides parallel min/max with custom comparators and key functions:
//! - `minBy`/`maxBy`: Min/max by custom comparator
//! - `minByKey`/`maxByKey`: Min/max by key function (parallel map-reduce)

const std = @import("std");
const api = @import("../api.zig");

/// Find the minimum element using a custom comparator.
/// Returns the element `a` where `cmp(a, b) == .lt` for all other elements.
pub fn minBy(comptime T: type, data: []const T, comptime cmp: fn (T, T) std.math.Order) ?T {
    if (data.len == 0) return null;
    if (data.len == 1) return data[0];

    // For small data, use sequential
    if (data.len <= 1024) {
        var best = data[0];
        for (data[1..]) |item| {
            if (cmp(item, best) == .lt) best = item;
        }
        return best;
    }

    // Use parallel reduce - start with first element as identity
    const Context = struct { slice: []const T };
    const ctx = Context{ .slice = data };

    return api.parallelReduce(
        T,
        data.len,
        data[0],
        Context,
        ctx,
        struct {
            fn mapFn(c: Context, i: usize) T {
                return c.slice[i];
            }
        }.mapFn,
        struct {
            fn reducer(a: T, b: T) T {
                return if (cmp(b, a) == .lt) b else a;
            }
        }.reducer,
    );
}

/// Find the maximum element using a custom comparator.
/// Returns the element `a` where `cmp(a, b) == .gt` for all other elements.
pub fn maxBy(comptime T: type, data: []const T, comptime cmp: fn (T, T) std.math.Order) ?T {
    if (data.len == 0) return null;
    if (data.len == 1) return data[0];

    // For small data, use sequential
    if (data.len <= 1024) {
        var best = data[0];
        for (data[1..]) |item| {
            if (cmp(item, best) == .gt) best = item;
        }
        return best;
    }

    // Use parallel reduce - start with first element as identity
    const Context = struct { slice: []const T };
    const ctx = Context{ .slice = data };

    return api.parallelReduce(
        T,
        data.len,
        data[0],
        Context,
        ctx,
        struct {
            fn mapFn(c: Context, i: usize) T {
                return c.slice[i];
            }
        }.mapFn,
        struct {
            fn reducer(a: T, b: T) T {
                return if (cmp(b, a) == .gt) b else a;
            }
        }.reducer,
    );
}

/// Find the minimum element by a key function.
/// Returns the element with the smallest key value.
///
/// Uses a parallel map-reduce pattern: each chunk computes keys locally
/// and finds its local minimum, then results are combined.
/// Key is computed once per element (not twice per comparison).
pub fn minByKey(comptime T: type, comptime K: type, data: []const T, comptime key_fn: fn (T) K) ?T {
    if (data.len == 0) return null;

    // Sequential for small data - avoid parallel overhead
    if (data.len <= 4096) {
        var best = data[0];
        var best_key = key_fn(best);
        for (data[1..]) |item| {
            const key = key_fn(item);
            if (key < best_key) {
                best_key = key;
                best = item;
            }
        }
        return best;
    }

    // Parallel reduction using (key, value) pairs
    const KeyValue = struct { key: K, value: T };

    const Context = struct { slice: []const T };
    const ctx = Context{ .slice = data };

    const result = api.parallelReduceChunked(
        ?KeyValue,
        data.len,
        null, // Identity
        Context,
        ctx,
        struct {
            // Map: find local minimum in chunk, computing key once per element
            fn mapChunk(c: Context, start: usize, end: usize) ?KeyValue {
                if (start >= end) return null;

                var best = c.slice[start];
                var best_key = key_fn(best);

                for (c.slice[start + 1 .. end]) |item| {
                    const key = key_fn(item);
                    if (key < best_key) {
                        best_key = key;
                        best = item;
                    }
                }
                return .{ .key = best_key, .value = best };
            }
        }.mapChunk,
        struct {
            // Reduce: combine two results by comparing keys
            fn combine(a: ?KeyValue, b: ?KeyValue) ?KeyValue {
                if (a == null) return b;
                if (b == null) return a;
                return if (b.?.key < a.?.key) b else a;
            }
        }.combine,
        8192, // Grain size
    );

    return if (result) |r| r.value else null;
}

/// Find the maximum element by a key function.
/// Returns the element with the largest key value.
///
/// Uses a parallel map-reduce pattern: each chunk computes keys locally
/// and finds its local maximum, then results are combined.
pub fn maxByKey(comptime T: type, comptime K: type, data: []const T, comptime key_fn: fn (T) K) ?T {
    if (data.len == 0) return null;

    // Sequential for small data
    if (data.len <= 4096) {
        var best = data[0];
        var best_key = key_fn(best);
        for (data[1..]) |item| {
            const key = key_fn(item);
            if (key > best_key) {
                best_key = key;
                best = item;
            }
        }
        return best;
    }

    // Parallel reduction
    const KeyValue = struct { key: K, value: T };

    const Context = struct { slice: []const T };
    const ctx = Context{ .slice = data };

    const result = api.parallelReduceChunked(
        ?KeyValue,
        data.len,
        null,
        Context,
        ctx,
        struct {
            fn mapChunk(c: Context, start: usize, end: usize) ?KeyValue {
                if (start >= end) return null;

                var best = c.slice[start];
                var best_key = key_fn(best);

                for (c.slice[start + 1 .. end]) |item| {
                    const key = key_fn(item);
                    if (key > best_key) {
                        best_key = key;
                        best = item;
                    }
                }
                return .{ .key = best_key, .value = best };
            }
        }.mapChunk,
        struct {
            fn combine(a: ?KeyValue, b: ?KeyValue) ?KeyValue {
                if (a == null) return b;
                if (b == null) return a;
                return if (b.?.key > a.?.key) b else a;
            }
        }.combine,
        8192,
    );

    return if (result) |r| r.value else null;
}
