//! Range iterator for parallel index ranges.
//!
//! Provides parallel iteration over numeric ranges:
//! - `RangeIter`: Parallel iteration over [start, end)

const std = @import("std");
const api = @import("../api.zig");

/// Range iterator for parallel index ranges.
pub const RangeIter = struct {
    start: usize,
    end: usize,

    /// Execute a function for each index in the range.
    pub fn forEach(self: RangeIter, comptime func: fn (usize) void) void {
        const len = self.end - self.start;
        if (len == 0) return;

        const Context = struct { base: usize };
        const ctx = Context{ .base = self.start };

        api.parallelFor(len, Context, ctx, struct {
            fn body(c: Context, start_offset: usize, end_offset: usize) void {
                var i = c.base + start_offset;
                const limit = c.base + end_offset;
                while (i < limit) : (i += 1) {
                    func(i);
                }
            }
        }.body);
    }

    /// Reduce over a range.
    pub fn reduce(self: RangeIter, comptime T: type, identity: T, comptime mapper: fn (usize) T, comptime reducer: fn (T, T) T) T {
        const len = self.end - self.start;
        if (len == 0) return identity;

        const Context = struct { base: usize };
        const ctx = Context{ .base = self.start };

        return api.parallelReduce(
            T,
            len,
            identity,
            Context,
            ctx,
            struct {
                fn mapFn(c: Context, i: usize) T {
                    return mapper(c.base + i);
                }
            }.mapFn,
            reducer,
        );
    }

    /// Sum the range using a mapper function.
    pub fn sum(self: RangeIter, comptime T: type, comptime mapper: fn (usize) T) T {
        return self.reduce(T, 0, mapper, struct {
            fn add(a: T, b: T) T {
                return a + b;
            }
        }.add);
    }
};
