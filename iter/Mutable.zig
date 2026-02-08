//! Mutable parallel iterators and mapped iterators.
//!
//! - `ParIterMut`: Mutable parallel iterator for in-place operations
//! - `MappedIter`: Lazy mapped parallel iterator

const std = @import("std");
const api = @import("../api.zig");
const chunks = @import("Chunks.zig");
const enumerate = @import("Enumerate.zig");

pub const ChunksMutIter = chunks.ChunksMutIter;
pub const EnumerateMutIter = enumerate.EnumerateMutIter;

/// Mapped parallel iterator.
pub fn MappedIter(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []const T,
        mapFn: *const fn (T) T,

        pub fn init(data: []const T, comptime func: fn (T) T) Self {
            return Self{ .data = data, .mapFn = func };
        }

        /// Collect mapped results into a new array.
        pub fn collect(self: Self, allocator: std.mem.Allocator) ![]T {
            const result = try allocator.alloc(T, self.data.len);
            errdefer allocator.free(result);

            const Context = struct {
                src: []const T,
                dst: []T,
                func: *const fn (T) T,
            };
            const ctx = Context{ .src = self.data, .dst = result, .func = self.mapFn };

            api.parallelFor(self.data.len, Context, ctx, struct {
                fn body(c: Context, start: usize, end: usize) void {
                    for (start..end) |i| {
                        c.dst[i] = c.func(c.src[i]);
                    }
                }
            }.body);

            return result;
        }

        /// Reduce mapped elements.
        pub fn reduce(self: Self, identity: T, comptime reducer: fn (T, T) T) T {
            const Context = struct {
                slice: []const T,
                func: *const fn (T) T,
            };
            const ctx = Context{ .slice = self.data, .func = self.mapFn };

            return api.parallelReduce(
                T,
                self.data.len,
                identity,
                Context,
                ctx,
                struct {
                    fn mapFn(c: Context, i: usize) T {
                        return c.func(c.slice[i]);
                    }
                }.mapFn,
                reducer,
            );
        }

        /// Sum mapped elements.
        pub fn sum(self: Self) T {
            return self.reduce(0, struct {
                fn add(a: T, b: T) T {
                    return a + b;
                }
            }.add);
        }
    };
}

/// Mutable parallel iterator for in-place operations.
pub fn ParIterMut(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []T,

        pub fn init(data: []T) Self {
            return Self{ .data = data };
        }

        /// Apply a function to each element in-place.
        pub fn mapInPlace(self: Self, comptime func: fn (T) T) void {
            const Context = struct { slice: []T };
            const ctx = Context{ .slice = self.data };

            api.parallelFor(self.data.len, Context, ctx, struct {
                fn body(c: Context, start: usize, end: usize) void {
                    for (c.slice[start..end]) |*val| {
                        val.* = func(val.*);
                    }
                }
            }.body);
        }

        /// Fill all elements with a value.
        pub fn fill(self: Self, value: T) void {
            const Context = struct { slice: []T, val: T };
            const ctx = Context{ .slice = self.data, .val = value };

            api.parallelFor(self.data.len, Context, ctx, struct {
                fn body(c: Context, start: usize, end: usize) void {
                    for (c.slice[start..end]) |*v| {
                        v.* = c.val;
                    }
                }
            }.body);
        }

        /// Create a mutable parallel iterator over fixed-size chunks.
        pub fn chunksMut(self: Self, chunk_size: usize) ChunksMutIter(T) {
            return ChunksMutIter(T).init(self.data, chunk_size);
        }

        /// Create an enumerated mutable parallel iterator.
        pub fn enumerate_iter(self: Self) EnumerateMutIter(T) {
            return EnumerateMutIter(T).init(self.data, 0);
        }

        /// Create an enumerated mutable parallel iterator with a custom starting offset.
        pub fn enumerateFrom(self: Self, offset: usize) EnumerateMutIter(T) {
            return EnumerateMutIter(T).init(self.data, offset);
        }
    };
}
