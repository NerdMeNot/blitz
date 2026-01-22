//! Predicate operations for parallel iterators.
//!
//! Provides parallel predicate evaluation with early termination:
//! - `any`: Check if any element satisfies a predicate
//! - `all`: Check if all elements satisfy a predicate
//!
//! Uses parallelForWithEarlyExit to prune entire subtrees when a result
//! is determined, matching Rayon's consumer.full() pattern.

const std = @import("std");
const api = @import("../api.zig");

/// Check if any element satisfies a predicate (parallel with early exit).
///
/// Uses parallelForWithEarlyExit to prune subtrees when a match is found.
/// This matches Rayon's approach of checking full() before splitting.
pub fn any(comptime T: type, data: []const T, comptime pred: fn (T) bool) bool {
    if (data.len == 0) return false;

    // For small data, use sequential scan
    if (data.len <= 1024) {
        for (data) |item| {
            if (pred(item)) return true;
        }
        return false;
    }

    // Parallel scan with early exit via atomic flag
    var found = std.atomic.Value(bool).init(false);

    const Context = struct {
        slice: []const T,
        found: *std.atomic.Value(bool),
    };

    // Use parallelForWithEarlyExit - subtrees are pruned when found becomes true
    api.parallelForWithEarlyExit(data.len, Context, .{
        .slice = data,
        .found = &found,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            // Early exit if already found
            if (ctx.found.load(.monotonic)) return;

            // Check atomic flag every CHUNK_SIZE elements instead of every element.
            // This reduces atomic operations from O(n) to O(n/CHUNK_SIZE).
            const CHUNK_SIZE = 64;
            const slice = ctx.slice[start..end];
            var i: usize = 0;

            while (i < slice.len) {
                // Process a chunk without atomic checks
                const chunk_end = @min(i + CHUNK_SIZE, slice.len);
                while (i < chunk_end) : (i += 1) {
                    if (pred(slice[i])) {
                        ctx.found.store(true, .release);
                        return;
                    }
                }
                // Check if another thread found a match (once per chunk)
                if (ctx.found.load(.monotonic)) return;
            }
        }
    }.body, &found);

    return found.load(.acquire);
}

/// Check if all elements satisfy a predicate (parallel with early exit).
///
/// Uses parallelForWithEarlyExit to prune subtrees when a counter-example is found.
/// This is equivalent to Rayon's approach: all(p) = !any(!p)
pub fn all(comptime T: type, data: []const T, comptime pred: fn (T) bool) bool {
    if (data.len == 0) return true;

    // For small data, use sequential scan
    if (data.len <= 1024) {
        for (data) |item| {
            if (!pred(item)) return false;
        }
        return true;
    }

    // Parallel scan with early exit via atomic flag
    // We're looking for a counter-example (an element that fails the predicate)
    var failed = std.atomic.Value(bool).init(false);

    const Context = struct {
        slice: []const T,
        failed: *std.atomic.Value(bool),
    };

    // Use parallelForWithEarlyExit - subtrees are pruned when failed becomes true
    api.parallelForWithEarlyExit(data.len, Context, .{
        .slice = data,
        .failed = &failed,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            // Early exit if already failed
            if (ctx.failed.load(.monotonic)) return;

            // Check atomic flag every CHUNK_SIZE elements instead of every element.
            // This reduces atomic operations from O(n) to O(n/CHUNK_SIZE).
            const CHUNK_SIZE = 64;
            const slice = ctx.slice[start..end];
            var i: usize = 0;

            while (i < slice.len) {
                // Process a chunk without atomic checks
                const chunk_end = @min(i + CHUNK_SIZE, slice.len);
                while (i < chunk_end) : (i += 1) {
                    if (!pred(slice[i])) {
                        ctx.failed.store(true, .release);
                        return;
                    }
                }
                // Check if another thread found a counter-example (once per chunk)
                if (ctx.failed.load(.monotonic)) return;
            }
        }
    }.body, &failed);

    return !failed.load(.acquire);
}
