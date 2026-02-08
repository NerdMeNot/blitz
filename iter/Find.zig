//! Find operations for parallel iterators.
//!
//! Provides parallel search with early termination:
//! - `findAny`: Returns any matching element (non-deterministic)
//! - `findFirst`: Returns the first (leftmost) match (deterministic)
//! - `findLast`: Returns the last (rightmost) match (deterministic)
//! - `position`: Returns index of first match
//! - `rposition`: Returns index of last match

const std = @import("std");
const api = @import("../api.zig");

/// Result type for findFirst/findLast operations.
pub fn FindResult(comptime T: type) type {
    return struct {
        index: usize,
        value: T,
    };
}

/// Find any element satisfying a predicate (parallel with early exit).
/// Returns any matching element (non-deterministic order for parallel execution).
/// This is equivalent to Rayon's `find_any`.
///
/// Uses parallelForWithEarlyExit to prune entire subtrees when a match is found,
/// matching Rayon's consumer.full() pattern for efficient short-circuiting.
pub fn findAny(comptime T: type, data: []const T, comptime pred: fn (T) bool) ?T {
    if (data.len == 0) return null;

    // For small data, use sequential scan
    if (data.len <= 1024) {
        for (data) |item| {
            if (pred(item)) return item;
        }
        return null;
    }

    // Quick sequential check at start to handle early-exit cases efficiently
    // This avoids parallel overhead when the target is near the beginning
    const quick_check_len = @min(data.len, 4096);
    for (data[0..quick_check_len]) |item| {
        if (pred(item)) return item;
    }
    if (quick_check_len == data.len) return null;

    // Parallel scan of remaining data (after quick check)
    // Uses lock-free pattern: only CAS winner writes to result
    const remaining = data[quick_check_len..];
    var found = std.atomic.Value(bool).init(false);
    var result: T = undefined;

    const Context = struct {
        slice: []const T,
        found: *std.atomic.Value(bool),
        result: *T,
    };

    // Use parallelForWithEarlyExit to prune subtrees when found
    api.parallelForWithEarlyExit(remaining.len, Context, .{
        .slice = remaining,
        .found = &found,
        .result = &result,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            // Early exit check at start of each chunk
            if (ctx.found.load(.monotonic)) return;

            for (ctx.slice[start..end]) |item| {
                // Check periodically within chunk for faster response
                if (ctx.found.load(.monotonic)) return;

                if (pred(item)) {
                    // Lock-free: only CAS winner writes result
                    if (ctx.found.cmpxchgStrong(false, true, .release, .monotonic) == null) {
                        ctx.result.* = item;
                    }
                    return;
                }
            }
        }
    }.body, &found);

    return if (found.load(.acquire)) result else null;
}

/// Find the first (leftmost) element satisfying a predicate (deterministic).
/// Returns the index and value of the first matching element.
/// This is equivalent to Rayon's `find_first`.
///
/// Note: This uses position-aware early termination. Unlike findAny, threads
/// processing ranges AFTER a found match are pruned, but threads processing
/// ranges BEFORE must continue (they might find an earlier match).
pub fn findFirst(comptime T: type, data: []const T, comptime pred: fn (T) bool) ?FindResult(T) {
    if (data.len == 0) return null;

    // For small data, use sequential scan
    if (data.len <= 1024) {
        for (data, 0..) |item, i| {
            if (pred(item)) return FindResult(T){ .index = i, .value = item };
        }
        return null;
    }

    // Quick sequential check at start to handle early-exit cases efficiently
    // Since we're finding the FIRST match, if we find it early, we're done
    const quick_check_len = @min(data.len, 4096);
    for (data[0..quick_check_len], 0..) |item, i| {
        if (pred(item)) return FindResult(T){ .index = i, .value = item };
    }
    if (quick_check_len == data.len) return null;

    // Parallel scan of remaining data: track best (lowest) position found
    // Lock-free: we only need to track the best position atomically.
    // The value can be retrieved from the slice once we know the position.
    const remaining = data[quick_check_len..];
    var best_pos = std.atomic.Value(usize).init(std.math.maxInt(usize));
    var dummy_exit = std.atomic.Value(bool).init(false);

    const Context = struct {
        slice: []const T,
        offset: usize, // Offset to add to get original index
        best_pos: *std.atomic.Value(usize),
    };

    api.parallelForWithEarlyExit(remaining.len, Context, .{
        .slice = remaining,
        .offset = quick_check_len,
        .best_pos = &best_pos,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            // Calculate actual indices in original array
            const actual_start = start + ctx.offset;

            // Early exit: our entire range is after best match
            const current_best = ctx.best_pos.load(.monotonic);
            if (actual_start >= current_best) return;

            for (start..end) |local_i| {
                const actual_i = local_i + ctx.offset;

                // Early exit: we're past the best known position
                if (actual_i >= ctx.best_pos.load(.monotonic)) return;

                if (pred(ctx.slice[local_i])) {
                    // Lock-free update: try to set best_pos if we're better
                    var expected = ctx.best_pos.load(.monotonic);
                    while (actual_i < expected) {
                        if (ctx.best_pos.cmpxchgWeak(expected, actual_i, .release, .monotonic)) |old| {
                            expected = old;
                        } else {
                            break; // Success
                        }
                    }
                    return; // Found in our range, done
                }
            }
        }
    }.body, &dummy_exit);

    const pos = best_pos.load(.acquire);
    return if (pos == std.math.maxInt(usize)) null else FindResult(T){ .index = pos, .value = data[pos] };
}

/// Find the last (rightmost) element satisfying a predicate (deterministic).
/// Returns the index and value of the last matching element.
/// This is equivalent to Rayon's `find_last`.
///
/// Note: This uses position-aware early termination. Threads processing ranges
/// BEFORE a found match are pruned, but threads processing ranges AFTER must
/// continue (they might find a later match).
pub fn findLast(comptime T: type, data: []const T, comptime pred: fn (T) bool) ?FindResult(T) {
    if (data.len == 0) return null;

    // For small data, use sequential scan
    if (data.len <= 1024) {
        var i = data.len;
        while (i > 0) {
            i -= 1;
            if (pred(data[i])) return FindResult(T){ .index = i, .value = data[i] };
        }
        return null;
    }

    // Parallel scan: track best (highest) position found
    // Lock-free: we only track position atomically, retrieve value at end
    // Use 0 as sentinel since valid positions are 0..len-1, but we also track has_match
    var best_pos = std.atomic.Value(usize).init(0);
    var has_match = std.atomic.Value(bool).init(false);
    var dummy_exit = std.atomic.Value(bool).init(false);

    const Context = struct {
        slice: []const T,
        best_pos: *std.atomic.Value(usize),
        has_match: *std.atomic.Value(bool),
    };

    api.parallelForWithEarlyExit(data.len, Context, .{
        .slice = data,
        .best_pos = &best_pos,
        .has_match = &has_match,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            // Early exit: our entire range is before best match
            if (ctx.has_match.load(.monotonic) and end <= ctx.best_pos.load(.monotonic)) return;

            // Iterate from end to start within this chunk
            var i = end;
            while (i > start) {
                i -= 1;
                // Early exit if our position is already worse
                if (ctx.has_match.load(.monotonic) and i <= ctx.best_pos.load(.monotonic)) return;

                if (pred(ctx.slice[i])) {
                    // Lock-free update: CAS loop to set best_pos if we're better (higher)
                    ctx.has_match.store(true, .release);
                    var expected = ctx.best_pos.load(.monotonic);
                    while (i > expected) {
                        if (ctx.best_pos.cmpxchgWeak(expected, i, .release, .monotonic)) |old| {
                            expected = old;
                        } else {
                            break; // Success
                        }
                    }
                    return; // Found in our range, done
                }
            }
        }
    }.body, &dummy_exit);

    return if (has_match.load(.acquire))
        FindResult(T){ .index = best_pos.load(.acquire), .value = data[best_pos.load(.acquire)] }
    else
        null;
}

/// Find the index of the first element satisfying a predicate.
/// This is equivalent to Rayon's `position`.
pub fn position(comptime T: type, data: []const T, comptime pred: fn (T) bool) ?usize {
    const result = findFirst(T, data, pred);
    return if (result) |r| r.index else null;
}

/// Find the index of any element satisfying a predicate (non-deterministic).
/// This is equivalent to Rayon's `position_any`.
///
/// Uses parallelForWithEarlyExit to prune entire subtrees when a match is found.
/// Returns the index of any matching element, not necessarily the first.
pub fn positionAny(comptime T: type, data: []const T, comptime pred: fn (T) bool) ?usize {
    if (data.len == 0) return null;

    // For small data, use sequential scan
    if (data.len <= 1024) {
        for (data, 0..) |item, i| {
            if (pred(item)) return i;
        }
        return null;
    }

    // Parallel scan with atomic early exit + result storage
    // Uses lock-free pattern: only CAS winner writes to result
    var found = std.atomic.Value(bool).init(false);
    var result_index: usize = undefined;

    const Context = struct {
        slice: []const T,
        found: *std.atomic.Value(bool),
        result_index: *usize,
    };

    // Use parallelForWithEarlyExit to prune subtrees when found
    api.parallelForWithEarlyExit(data.len, Context, .{
        .slice = data,
        .found = &found,
        .result_index = &result_index,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            // Early exit check at start of each chunk
            if (ctx.found.load(.monotonic)) return;

            for (start..end) |i| {
                // Check periodically within chunk for faster response
                if (ctx.found.load(.monotonic)) return;

                if (pred(ctx.slice[i])) {
                    // Lock-free: only CAS winner writes result
                    if (ctx.found.cmpxchgStrong(false, true, .release, .monotonic) == null) {
                        ctx.result_index.* = i;
                    }
                    return;
                }
            }
        }
    }.body, &found);

    return if (found.load(.acquire)) result_index else null;
}

/// Find the index of the last element satisfying a predicate.
/// This is equivalent to Rayon's `rposition`.
pub fn rposition(comptime T: type, data: []const T, comptime pred: fn (T) bool) ?usize {
    const result = findLast(T, data, pred);
    return if (result) |r| r.index else null;
}
