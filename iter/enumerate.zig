//! Enumerated iterators for parallel processing.
//!
//! Provides parallel iteration with index tracking:
//! - `EnumerateIter`: Immutable enumerated iteration
//! - `EnumerateMutIter`: Mutable enumerated iteration

const std = @import("std");
const api = @import("../api.zig");

/// Enumerated parallel iterator (immutable).
/// Pairs each element with its index during iteration.
pub fn EnumerateIter(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []const T,
        offset: usize,

        pub fn init(data: []const T, offset: usize) Self {
            return Self{ .data = data, .offset = offset };
        }

        /// Execute a function for each (index, element) pair in parallel.
        pub fn forEach(self: Self, comptime func: fn (usize, T) void) void {
            if (self.data.len == 0) return;

            const Context = struct {
                slice: []const T,
                base: usize,
            };

            api.parallelFor(self.data.len, Context, .{
                .slice = self.data,
                .base = self.offset,
            }, struct {
                fn body(ctx: Context, start: usize, end: usize) void {
                    for (start..end) |i| {
                        func(ctx.base + i, ctx.slice[i]);
                    }
                }
            }.body);
        }

        /// Reduce over enumerated pairs.
        pub fn reduce(self: Self, comptime R: type, identity: R, comptime map_fn: fn (usize, T) R, comptime combine_fn: fn (R, R) R) R {
            if (self.data.len == 0) return identity;

            const Context = struct {
                slice: []const T,
                base: usize,
            };

            return api.parallelReduce(
                R,
                self.data.len,
                identity,
                Context,
                .{ .slice = self.data, .base = self.offset },
                struct {
                    fn mapFn(ctx: Context, i: usize) R {
                        return map_fn(ctx.base + i, ctx.slice[i]);
                    }
                }.mapFn,
                combine_fn,
            );
        }

        /// Check if any (index, element) pair satisfies a predicate.
        pub fn any(self: Self, comptime pred: fn (usize, T) bool) bool {
            if (self.data.len == 0) return false;

            if (self.data.len <= 1024) {
                for (self.data, 0..) |item, i| {
                    if (pred(self.offset + i, item)) return true;
                }
                return false;
            }

            var found = std.atomic.Value(bool).init(false);

            const Context = struct {
                slice: []const T,
                base: usize,
                found: *std.atomic.Value(bool),
            };

            api.parallelFor(self.data.len, Context, .{
                .slice = self.data,
                .base = self.offset,
                .found = &found,
            }, struct {
                fn body(ctx: Context, start: usize, end: usize) void {
                    if (ctx.found.load(.monotonic)) return;
                    for (start..end) |i| {
                        if (pred(ctx.base + i, ctx.slice[i])) {
                            ctx.found.store(true, .release);
                            return;
                        }
                    }
                }
            }.body);

            return found.load(.acquire);
        }

        /// Check if all (index, element) pairs satisfy a predicate.
        pub fn all(self: Self, comptime pred: fn (usize, T) bool) bool {
            if (self.data.len == 0) return true;

            if (self.data.len <= 1024) {
                for (self.data, 0..) |item, i| {
                    if (!pred(self.offset + i, item)) return false;
                }
                return true;
            }

            var failed = std.atomic.Value(bool).init(false);

            const Context = struct {
                slice: []const T,
                base: usize,
                failed: *std.atomic.Value(bool),
            };

            api.parallelFor(self.data.len, Context, .{
                .slice = self.data,
                .base = self.offset,
                .failed = &failed,
            }, struct {
                fn body(ctx: Context, start: usize, end: usize) void {
                    if (ctx.failed.load(.monotonic)) return;
                    for (start..end) |i| {
                        if (!pred(ctx.base + i, ctx.slice[i])) {
                            ctx.failed.store(true, .release);
                            return;
                        }
                    }
                }
            }.body);

            return !failed.load(.acquire);
        }
    };
}

/// Enumerated mutable parallel iterator.
/// Pairs each element with its index during iteration, allowing mutation.
pub fn EnumerateMutIter(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []T,
        offset: usize,

        pub fn init(data: []T, offset: usize) Self {
            return Self{ .data = data, .offset = offset };
        }

        /// Execute a function for each (index, *element) pair in parallel.
        /// The element is passed as a pointer for mutation.
        pub fn forEach(self: Self, comptime func: fn (usize, *T) void) void {
            if (self.data.len == 0) return;

            const Context = struct {
                slice: []T,
                base: usize,
            };

            api.parallelFor(self.data.len, Context, .{
                .slice = self.data,
                .base = self.offset,
            }, struct {
                fn body(ctx: Context, start: usize, end: usize) void {
                    for (start..end) |i| {
                        func(ctx.base + i, &ctx.slice[i]);
                    }
                }
            }.body);
        }

        /// Map each element using its index.
        pub fn mapInPlace(self: Self, comptime func: fn (usize, T) T) void {
            if (self.data.len == 0) return;

            const Context = struct {
                slice: []T,
                base: usize,
            };

            api.parallelFor(self.data.len, Context, .{
                .slice = self.data,
                .base = self.offset,
            }, struct {
                fn body(ctx: Context, start: usize, end: usize) void {
                    for (start..end) |i| {
                        ctx.slice[i] = func(ctx.base + i, ctx.slice[i]);
                    }
                }
            }.body);
        }
    };
}
