//! Parallel Iterators for Blitz
//!
//! Provides Rayon-style parallel iterators with composable operations.
//! Unlike Rayon's trait-based approach, we use Zig's comptime for zero-cost abstractions.
//!
//! Usage:
//! ```zig
//! const blitz = @import("blitz");
//!
//! // Parallel sum
//! const sum = blitz.iter(i64, data).sum();
//!
//! // Parallel map and collect
//! var result = try blitz.iter(i64, data)
//!     .map(square)
//!     .collect(allocator);
//! ```

const std = @import("std");
const api = @import("../api.zig");

// Re-export sub-modules
pub const find = @import("find.zig");
pub const predicates = @import("predicates.zig");
pub const minmax = @import("minmax.zig");
pub const chunks = @import("chunks.zig");
pub const enumerate = @import("enumerate.zig");
pub const mutable = @import("mutable.zig");
pub const range_mod = @import("range.zig");
pub const combinators = @import("combinators.zig");

// Re-export types
pub const ChunksIter = chunks.ChunksIter;
pub const ChunksMutIter = chunks.ChunksMutIter;
pub const EnumerateIter = enumerate.EnumerateIter;
pub const EnumerateMutIter = enumerate.EnumerateMutIter;
pub const MappedIter = mutable.MappedIter;
pub const ParIterMut = mutable.ParIterMut;
pub const RangeIter = range_mod.RangeIter;

// Re-export combinators
pub const ChainIter = combinators.ChainIter;
pub const ZipIter = combinators.ZipIter;
pub const FlattenIter = combinators.FlattenIter;
pub const chain = combinators.chain;
pub const zip = combinators.zip;
pub const flatten = combinators.flatten;

/// Create a parallel iterator from a slice.
pub fn iter(comptime T: type, data: []const T) ParIter(T) {
    return ParIter(T).init(data);
}

/// Create a mutable parallel iterator from a slice.
pub fn iterMut(comptime T: type, data: []T) ParIterMut(T) {
    return ParIterMut(T).init(data);
}

/// Create a parallel iterator over a range [start, end).
pub fn range(start: usize, end: usize) RangeIter {
    return RangeIter{ .start = start, .end = end };
}

/// Parallel iterator over a slice.
pub fn ParIter(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []const T,

        pub fn init(data: []const T) Self {
            return Self{ .data = data };
        }

        // ====================================================================
        // Core Reductions
        // ====================================================================

        /// Reduce all elements to a single value using parallel reduction.
        pub fn reduce(self: Self, identity: T, comptime reducer: fn (T, T) T) T {
            const Context = struct { slice: []const T };
            const ctx = Context{ .slice = self.data };

            return api.parallelReduce(
                T,
                self.data.len,
                identity,
                Context,
                ctx,
                struct {
                    fn mapFn(c: Context, i: usize) T {
                        return c.slice[i];
                    }
                }.mapFn,
                reducer,
            );
        }

        /// Sum all elements using parallel reduction.
        pub fn sum(self: Self) T {
            if (self.data.len == 0) return 0;
            return self.reduce(0, struct {
                fn add(a: T, b: T) T {
                    return a + b;
                }
            }.add);
        }

        /// Find the minimum element using parallel reduction.
        pub fn min(self: Self) ?T {
            if (self.data.len == 0) return null;
            return minmax.minBy(T, self.data, struct {
                fn cmp(a: T, b: T) std.math.Order {
                    return std.math.order(a, b);
                }
            }.cmp);
        }

        /// Find the maximum element using parallel reduction.
        pub fn max(self: Self) ?T {
            if (self.data.len == 0) return null;
            return minmax.maxBy(T, self.data, struct {
                fn cmp(a: T, b: T) std.math.Order {
                    return std.math.order(a, b);
                }
            }.cmp);
        }

        /// Count elements.
        pub fn count(self: Self) usize {
            return self.data.len;
        }

        // ====================================================================
        // Min/Max by comparator/key (delegated to minmax module)
        // ====================================================================

        /// Find the minimum element using a custom comparator.
        pub fn minBy(self: Self, comptime cmp: fn (T, T) std.math.Order) ?T {
            return minmax.minBy(T, self.data, cmp);
        }

        /// Find the maximum element using a custom comparator.
        pub fn maxBy(self: Self, comptime cmp: fn (T, T) std.math.Order) ?T {
            return minmax.maxBy(T, self.data, cmp);
        }

        /// Find the minimum element by a key function.
        pub fn minByKey(self: Self, comptime K: type, comptime key_fn: fn (T) K) ?T {
            return minmax.minByKey(T, K, self.data, key_fn);
        }

        /// Find the maximum element by a key function.
        pub fn maxByKey(self: Self, comptime K: type, comptime key_fn: fn (T) K) ?T {
            return minmax.maxByKey(T, K, self.data, key_fn);
        }

        // ====================================================================
        // Find operations (delegated to find module)
        // ====================================================================

        /// Find any element satisfying a predicate (parallel with early exit).
        pub fn findAny(self: Self, comptime pred: fn (T) bool) ?T {
            return find.findAny(T, self.data, pred);
        }

        /// Find the first (leftmost) element satisfying a predicate (deterministic).
        pub fn findFirst(self: Self, comptime pred: fn (T) bool) ?find.FindResult(T) {
            return find.findFirst(T, self.data, pred);
        }

        /// Find the last (rightmost) element satisfying a predicate (deterministic).
        pub fn findLast(self: Self, comptime pred: fn (T) bool) ?find.FindResult(T) {
            return find.findLast(T, self.data, pred);
        }

        /// Find the index of the first element satisfying a predicate.
        pub fn position(self: Self, comptime pred: fn (T) bool) ?usize {
            return find.position(T, self.data, pred);
        }

        /// Find the index of any element satisfying a predicate (non-deterministic).
        /// This is equivalent to Rayon's `position_any`.
        pub fn positionAny(self: Self, comptime pred: fn (T) bool) ?usize {
            return find.positionAny(T, self.data, pred);
        }

        /// Find the index of the last element satisfying a predicate.
        pub fn rposition(self: Self, comptime pred: fn (T) bool) ?usize {
            return find.rposition(T, self.data, pred);
        }

        // ====================================================================
        // Predicates (delegated to predicates module)
        // ====================================================================

        /// Check if any element satisfies a predicate (parallel with early exit).
        pub fn any(self: Self, comptime pred: fn (T) bool) bool {
            return predicates.any(T, self.data, pred);
        }

        /// Check if all elements satisfy a predicate (parallel with early exit).
        pub fn all(self: Self, comptime pred: fn (T) bool) bool {
            return predicates.all(T, self.data, pred);
        }

        // ====================================================================
        // Transformations
        // ====================================================================

        /// Map each element through a function.
        pub fn map(self: Self, comptime func: fn (T) T) MappedIter(T) {
            return MappedIter(T).init(self.data, func);
        }

        /// Execute a function for each element (parallel for-each).
        pub fn forEach(self: Self, comptime func: fn (T) void) void {
            const Context = struct { slice: []const T };
            const ctx = Context{ .slice = self.data };

            api.parallelFor(self.data.len, Context, ctx, struct {
                fn body(c: Context, start: usize, end: usize) void {
                    for (c.slice[start..end]) |item| {
                        func(item);
                    }
                }
            }.body);
        }

        /// Collect into a new array (identity map).
        pub fn collect(self: Self, allocator: std.mem.Allocator) ![]T {
            const result = try allocator.alloc(T, self.data.len);
            @memcpy(result, self.data);
            return result;
        }

        // ====================================================================
        // Iterators
        // ====================================================================

        /// Create a parallel iterator over fixed-size chunks.
        pub fn chunks_iter(self: Self, chunk_size: usize) ChunksIter(T) {
            return ChunksIter(T).init(self.data, chunk_size);
        }

        /// Create an enumerated parallel iterator.
        pub fn enumerate_iter(self: Self) EnumerateIter(T) {
            return EnumerateIter(T).init(self.data, 0);
        }

        /// Create an enumerated parallel iterator with a custom starting offset.
        pub fn enumerateFrom(self: Self, offset: usize) EnumerateIter(T) {
            return EnumerateIter(T).init(self.data, offset);
        }
    };
}

// Tests
test {
    _ = @import("tests.zig");
    _ = @import("combinators.zig");
}
