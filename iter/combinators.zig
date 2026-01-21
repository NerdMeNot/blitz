//! Iterator Combinators
//!
//! Parallel iterator composition operations inspired by Rayon:
//! - chain: Concatenate two iterators
//! - zip: Pair up elements from two iterators
//! - flatten: Flatten nested slices
//!
//! These combinators enable expressive parallel data processing pipelines.

const std = @import("std");
const api = @import("../api.zig");

// ============================================================================
// ChainIter - Concatenate Two Slices
// ============================================================================

/// A parallel iterator that chains two slices together.
/// Processes elements from `first` followed by elements from `second`.
pub fn ChainIter(comptime T: type) type {
    return struct {
        const Self = @This();

        first: []const T,
        second: []const T,

        pub fn init(first: []const T, second: []const T) Self {
            return Self{ .first = first, .second = second };
        }

        /// Total number of elements.
        pub fn len(self: Self) usize {
            return self.first.len + self.second.len;
        }

        /// Execute a function for each element in parallel.
        pub fn forEach(self: Self, comptime func: fn (T) void) void {
            // Process both slices in parallel using join
            if (self.first.len == 0 and self.second.len == 0) return;

            if (self.first.len == 0) {
                processSlice(T, self.second, func);
                return;
            }

            if (self.second.len == 0) {
                processSlice(T, self.first, func);
                return;
            }

            const FirstArgs = struct { slice: []const T };
            const SecondArgs = struct { slice: []const T };

            api.joinVoid(
                struct {
                    fn processFirst(args: FirstArgs) void {
                        processSlice(T, args.slice, func);
                    }
                }.processFirst,
                struct {
                    fn processSecond(args: SecondArgs) void {
                        processSlice(T, args.slice, func);
                    }
                }.processSecond,
                FirstArgs{ .slice = self.first },
                SecondArgs{ .slice = self.second },
            );
        }

        /// Reduce all elements using a combining function.
        pub fn reduce(self: Self, identity: T, comptime reducer: fn (T, T) T) T {
            if (self.first.len == 0 and self.second.len == 0) return identity;

            if (self.first.len == 0) {
                return reduceSlice(T, self.second, identity, reducer);
            }

            if (self.second.len == 0) {
                return reduceSlice(T, self.first, identity, reducer);
            }

            const FirstArgs = struct { slice: []const T, identity: T };
            const SecondArgs = struct { slice: []const T, identity: T };

            const results = api.join(
                T,
                T,
                struct {
                    fn reduceFirst(args: FirstArgs) T {
                        return reduceSlice(T, args.slice, args.identity, reducer);
                    }
                }.reduceFirst,
                struct {
                    fn reduceSecond(args: SecondArgs) T {
                        return reduceSlice(T, args.slice, args.identity, reducer);
                    }
                }.reduceSecond,
                FirstArgs{ .slice = self.first, .identity = identity },
                SecondArgs{ .slice = self.second, .identity = identity },
            );

            return reducer(results[0], results[1]);
        }

        /// Sum all elements.
        pub fn sum(self: Self) T {
            return self.reduce(0, struct {
                fn add(a: T, b: T) T {
                    return a + b;
                }
            }.add);
        }

        /// Check if any element satisfies a predicate.
        pub fn any(self: Self, comptime pred: fn (T) bool) bool {
            var found = std.atomic.Value(bool).init(false);

            const Context = struct { slice: []const T, found: *std.atomic.Value(bool) };

            const first_ctx = Context{ .slice = self.first, .found = &found };
            const second_ctx = Context{ .slice = self.second, .found = &found };

            api.joinVoid(
                struct {
                    fn checkFirst(ctx: Context) void {
                        if (ctx.found.load(.monotonic)) return;
                        for (ctx.slice) |item| {
                            if (ctx.found.load(.monotonic)) return;
                            if (pred(item)) {
                                ctx.found.store(true, .release);
                                return;
                            }
                        }
                    }
                }.checkFirst,
                struct {
                    fn checkSecond(ctx: Context) void {
                        if (ctx.found.load(.monotonic)) return;
                        for (ctx.slice) |item| {
                            if (ctx.found.load(.monotonic)) return;
                            if (pred(item)) {
                                ctx.found.store(true, .release);
                                return;
                            }
                        }
                    }
                }.checkSecond,
                first_ctx,
                second_ctx,
            );

            return found.load(.acquire);
        }

        /// Check if all elements satisfy a predicate.
        pub fn all(self: Self, comptime pred: fn (T) bool) bool {
            // all(pred) is equivalent to !any(!pred)
            return !self.any(struct {
                fn notPred(x: T) bool {
                    return !pred(x);
                }
            }.notPred);
        }

        /// Collect into a new array.
        pub fn collect(self: Self, allocator: std.mem.Allocator) ![]T {
            const total = self.len();
            const result = try allocator.alloc(T, total);

            if (self.first.len > 0) {
                @memcpy(result[0..self.first.len], self.first);
            }
            if (self.second.len > 0) {
                @memcpy(result[self.first.len..], self.second);
            }

            return result;
        }
    };
}

/// Helper: process a slice with a function.
fn processSlice(comptime T: type, slice: []const T, comptime func: fn (T) void) void {
    const Context = struct { slice: []const T };
    const ctx = Context{ .slice = slice };

    api.parallelFor(slice.len, Context, ctx, struct {
        fn body(c: Context, start: usize, end: usize) void {
            for (c.slice[start..end]) |item| {
                func(item);
            }
        }
    }.body);
}

/// Helper: reduce a slice.
fn reduceSlice(comptime T: type, slice: []const T, identity: T, comptime reducer: fn (T, T) T) T {
    const Context = struct { slice: []const T };
    const ctx = Context{ .slice = slice };

    return api.parallelReduce(
        T,
        slice.len,
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

// ============================================================================
// ZipIter - Pair Elements from Two Slices
// ============================================================================

/// A parallel iterator that zips two slices together.
/// Pairs elements at the same index: (a[i], b[i]).
/// Length is the minimum of the two slices.
pub fn ZipIter(comptime A: type, comptime B: type) type {
    return struct {
        const Self = @This();
        pub const Item = struct { A, B };

        a: []const A,
        b: []const B,

        pub fn init(a: []const A, b: []const B) Self {
            return Self{ .a = a, .b = b };
        }

        /// Number of pairs (minimum of the two lengths).
        pub fn len(self: Self) usize {
            return @min(self.a.len, self.b.len);
        }

        /// Execute a function for each pair in parallel.
        pub fn forEach(self: Self, comptime func: fn (A, B) void) void {
            const n = self.len();
            if (n == 0) return;

            const Context = struct { a: []const A, b: []const B };
            const ctx = Context{ .a = self.a, .b = self.b };

            api.parallelFor(n, Context, ctx, struct {
                fn body(c: Context, start: usize, end: usize) void {
                    for (start..end) |i| {
                        func(c.a[i], c.b[i]);
                    }
                }
            }.body);
        }

        /// Map each pair through a function and reduce.
        pub fn mapReduce(
            self: Self,
            comptime R: type,
            identity: R,
            comptime mapper: fn (A, B) R,
            comptime reducer: fn (R, R) R,
        ) R {
            const n = self.len();
            if (n == 0) return identity;

            const Context = struct { a: []const A, b: []const B };
            const ctx = Context{ .a = self.a, .b = self.b };

            return api.parallelReduce(
                R,
                n,
                identity,
                Context,
                ctx,
                struct {
                    fn mapFn(c: Context, i: usize) R {
                        return mapper(c.a[i], c.b[i]);
                    }
                }.mapFn,
                reducer,
            );
        }

        /// Compute dot product (sum of products).
        pub fn dotProduct(self: Self) A {
            return self.mapReduce(
                A,
                0,
                struct {
                    fn mul(a: A, b: B) A {
                        return a * @as(A, @intCast(b));
                    }
                }.mul,
                struct {
                    fn add(x: A, y: A) A {
                        return x + y;
                    }
                }.add,
            );
        }

        /// Check if any pair satisfies a predicate.
        pub fn any(self: Self, comptime pred: fn (A, B) bool) bool {
            const n = self.len();
            if (n == 0) return false;

            var found = std.atomic.Value(bool).init(false);

            const Context = struct { a: []const A, b: []const B, found: *std.atomic.Value(bool) };
            const ctx = Context{ .a = self.a, .b = self.b, .found = &found };

            api.parallelFor(n, Context, ctx, struct {
                fn body(c: Context, start: usize, end: usize) void {
                    if (c.found.load(.monotonic)) return;
                    for (start..end) |i| {
                        if (c.found.load(.monotonic)) return;
                        if (pred(c.a[i], c.b[i])) {
                            c.found.store(true, .release);
                            return;
                        }
                    }
                }
            }.body);

            return found.load(.acquire);
        }

        /// Check if all pairs satisfy a predicate.
        pub fn all(self: Self, comptime pred: fn (A, B) bool) bool {
            const n = self.len();
            if (n == 0) return true;

            var failed = std.atomic.Value(bool).init(false);

            const Context = struct { a: []const A, b: []const B, failed: *std.atomic.Value(bool) };
            const ctx = Context{ .a = self.a, .b = self.b, .failed = &failed };

            api.parallelFor(n, Context, ctx, struct {
                fn body(c: Context, start: usize, end: usize) void {
                    if (c.failed.load(.monotonic)) return;
                    for (start..end) |i| {
                        if (c.failed.load(.monotonic)) return;
                        if (!pred(c.a[i], c.b[i])) {
                            c.failed.store(true, .release);
                            return;
                        }
                    }
                }
            }.body);

            return !failed.load(.acquire);
        }

        /// Collect pairs into a new array.
        pub fn collect(self: Self, allocator: std.mem.Allocator) ![]Item {
            const n = self.len();
            const result = try allocator.alloc(Item, n);

            const Context = struct { a: []const A, b: []const B, out: []Item };
            const ctx = Context{ .a = self.a, .b = self.b, .out = result };

            api.parallelFor(n, Context, ctx, struct {
                fn body(c: Context, start: usize, end: usize) void {
                    for (start..end) |i| {
                        c.out[i] = .{ c.a[i], c.b[i] };
                    }
                }
            }.body);

            return result;
        }

        /// Unzip into two separate arrays.
        pub fn unzip(self: Self, allocator: std.mem.Allocator) !struct { []A, []B } {
            const n = self.len();
            const a_out = try allocator.alloc(A, n);
            errdefer allocator.free(a_out);
            const b_out = try allocator.alloc(B, n);

            @memcpy(a_out, self.a[0..n]);
            @memcpy(b_out, self.b[0..n]);

            return .{ a_out, b_out };
        }
    };
}

// ============================================================================
// FlattenIter - Flatten Nested Slices
// ============================================================================

/// A parallel iterator that flattens a slice of slices.
pub fn FlattenIter(comptime T: type) type {
    return struct {
        const Self = @This();

        slices: []const []const T,

        pub fn init(slices: []const []const T) Self {
            return Self{ .slices = slices };
        }

        /// Total number of elements across all slices.
        pub fn len(self: Self) usize {
            var total: usize = 0;
            for (self.slices) |slice| {
                total += slice.len;
            }
            return total;
        }

        /// Execute a function for each element in parallel.
        pub fn forEach(self: Self, comptime func: fn (T) void) void {
            const Context = struct { slices: []const []const T };
            const ctx = Context{ .slices = self.slices };

            api.parallelFor(self.slices.len, Context, ctx, struct {
                fn body(c: Context, start: usize, end: usize) void {
                    for (c.slices[start..end]) |slice| {
                        for (slice) |item| {
                            func(item);
                        }
                    }
                }
            }.body);
        }

        /// Reduce all elements using a combining function.
        pub fn reduce(self: Self, identity: T, comptime reducer: fn (T, T) T) T {
            if (self.slices.len == 0) return identity;

            const Context = struct { slices: []const []const T, identity: T };
            const ctx = Context{ .slices = self.slices, .identity = identity };

            return api.parallelReduce(
                T,
                self.slices.len,
                identity,
                Context,
                ctx,
                struct {
                    fn mapFn(c: Context, i: usize) T {
                        var acc = c.identity;
                        for (c.slices[i]) |item| {
                            acc = reducer(acc, item);
                        }
                        return acc;
                    }
                }.mapFn,
                reducer,
            );
        }

        /// Sum all elements.
        pub fn sum(self: Self) T {
            return self.reduce(0, struct {
                fn add(a: T, b: T) T {
                    return a + b;
                }
            }.add);
        }

        /// Collect all elements into a flat array.
        pub fn collect(self: Self, allocator: std.mem.Allocator) ![]T {
            const total = self.len();
            if (total == 0) return &.{};

            const result = try allocator.alloc(T, total);
            api.parallelFlatten(T, self.slices, result);
            return result;
        }
    };
}

// ============================================================================
// Convenience Functions
// ============================================================================

/// Create a chain iterator from two slices.
pub fn chain(comptime T: type, first: []const T, second: []const T) ChainIter(T) {
    return ChainIter(T).init(first, second);
}

/// Create a zip iterator from two slices.
pub fn zip(comptime A: type, comptime B: type, a: []const A, b: []const B) ZipIter(A, B) {
    return ZipIter(A, B).init(a, b);
}

/// Create a flatten iterator from a slice of slices.
pub fn flatten(comptime T: type, slices: []const []const T) FlattenIter(T) {
    return FlattenIter(T).init(slices);
}

// ============================================================================
// Tests
// ============================================================================

test "ChainIter - basic" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5, 6 };

    const it = chain(i32, &a, &b);
    try std.testing.expectEqual(@as(usize, 6), it.len());
}

test "ChainIter - sum" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5, 6 };

    const result = chain(i32, &a, &b).sum();
    try std.testing.expectEqual(@as(i32, 21), result);
}

test "ChainIter - any" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5, 6 };

    const has_five = chain(i32, &a, &b).any(struct {
        fn pred(x: i32) bool {
            return x == 5;
        }
    }.pred);
    try std.testing.expect(has_five);

    const has_ten = chain(i32, &a, &b).any(struct {
        fn pred(x: i32) bool {
            return x == 10;
        }
    }.pred);
    try std.testing.expect(!has_ten);
}

test "ChainIter - all" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5, 6 };

    const all_positive = chain(i32, &a, &b).all(struct {
        fn pred(x: i32) bool {
            return x > 0;
        }
    }.pred);
    try std.testing.expect(all_positive);

    const all_even = chain(i32, &a, &b).all(struct {
        fn pred(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.pred);
    try std.testing.expect(!all_even);
}

test "ChainIter - collect" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5, 6 };

    const result = try chain(i32, &a, &b).collect(std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 6), result.len);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 4, 5, 6 }, result);
}

test "ChainIter - empty" {
    const empty: []const i32 = &.{};
    const a = [_]i32{ 1, 2, 3 };

    try std.testing.expectEqual(@as(i32, 6), chain(i32, empty, &a).sum());
    try std.testing.expectEqual(@as(i32, 6), chain(i32, &a, empty).sum());
    try std.testing.expectEqual(@as(i32, 0), chain(i32, empty, empty).sum());
}

test "ZipIter - basic" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5, 6 };

    const it = zip(i32, i32, &a, &b);
    try std.testing.expectEqual(@as(usize, 3), it.len());
}

test "ZipIter - unequal lengths" {
    const a = [_]i32{ 1, 2, 3, 4, 5 };
    const b = [_]i32{ 10, 20, 30 };

    const it = zip(i32, i32, &a, &b);
    try std.testing.expectEqual(@as(usize, 3), it.len());
}

test "ZipIter - mapReduce" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5, 6 };

    // Sum of products: 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
    const result = zip(i32, i32, &a, &b).mapReduce(i32, 0, struct {
        fn mul(x: i32, y: i32) i32 {
            return x * y;
        }
    }.mul, struct {
        fn add(x: i32, y: i32) i32 {
            return x + y;
        }
    }.add);

    try std.testing.expectEqual(@as(i32, 32), result);
}

test "ZipIter - any" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5, 6 };

    const has_sum_7 = zip(i32, i32, &a, &b).any(struct {
        fn pred(x: i32, y: i32) bool {
            return x + y == 7;
        }
    }.pred);
    try std.testing.expect(has_sum_7); // 2 + 5 = 7

    const has_sum_100 = zip(i32, i32, &a, &b).any(struct {
        fn pred(x: i32, y: i32) bool {
            return x + y == 100;
        }
    }.pred);
    try std.testing.expect(!has_sum_100);
}

test "ZipIter - all" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5, 6 };

    const all_less = zip(i32, i32, &a, &b).all(struct {
        fn pred(x: i32, y: i32) bool {
            return x < y;
        }
    }.pred);
    try std.testing.expect(all_less);

    const all_equal = zip(i32, i32, &a, &b).all(struct {
        fn pred(x: i32, y: i32) bool {
            return x == y;
        }
    }.pred);
    try std.testing.expect(!all_equal);
}

test "ZipIter - collect" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5, 6 };

    const pairs = try zip(i32, i32, &a, &b).collect(std.testing.allocator);
    defer std.testing.allocator.free(pairs);

    try std.testing.expectEqual(@as(usize, 3), pairs.len);
    try std.testing.expectEqual(@as(i32, 1), pairs[0][0]);
    try std.testing.expectEqual(@as(i32, 4), pairs[0][1]);
    try std.testing.expectEqual(@as(i32, 3), pairs[2][0]);
    try std.testing.expectEqual(@as(i32, 6), pairs[2][1]);
}

test "FlattenIter - basic" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5 };
    const c = [_]i32{ 6, 7, 8, 9 };

    const slices = [_][]const i32{ &a, &b, &c };
    const it = flatten(i32, &slices);

    try std.testing.expectEqual(@as(usize, 9), it.len());
}

test "FlattenIter - sum" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5 };
    const c = [_]i32{ 6, 7, 8, 9 };

    const slices = [_][]const i32{ &a, &b, &c };
    const result = flatten(i32, &slices).sum();

    try std.testing.expectEqual(@as(i32, 45), result);
}

test "FlattenIter - collect" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5 };
    const c = [_]i32{ 6, 7, 8, 9 };

    const slices = [_][]const i32{ &a, &b, &c };
    const result = try flatten(i32, &slices).collect(std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 9), result.len);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, result);
}

test "FlattenIter - empty" {
    const empty_slices: []const []const i32 = &.{};
    const it = flatten(i32, empty_slices);

    try std.testing.expectEqual(@as(usize, 0), it.len());
    try std.testing.expectEqual(@as(i32, 0), it.sum());
}
