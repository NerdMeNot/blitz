//! Chunk iterators for parallel processing.
//!
//! Provides parallel iteration over fixed-size chunks:
//! - `ChunksIter`: Immutable parallel chunk iteration
//! - `ChunksMutIter`: Mutable parallel chunk iteration

const std = @import("std");
const api = @import("../api.zig");

/// Parallel iterator over fixed-size chunks of a slice.
pub fn ChunksIter(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []const T,
        chunk_size: usize,

        pub fn init(data: []const T, chunk_size: usize) Self {
            std.debug.assert(chunk_size > 0);
            return Self{ .data = data, .chunk_size = chunk_size };
        }

        /// Number of chunks.
        pub fn count(self: Self) usize {
            if (self.data.len == 0) return 0;
            return (self.data.len + self.chunk_size - 1) / self.chunk_size;
        }

        /// Execute a function for each chunk in parallel.
        pub fn forEach(self: Self, comptime func: fn ([]const T) void) void {
            const num_chunks = self.count();
            if (num_chunks == 0) return;

            const Context = struct {
                data: []const T,
                chunk_size: usize,
            };

            api.parallelFor(num_chunks, Context, .{
                .data = self.data,
                .chunk_size = self.chunk_size,
            }, struct {
                fn body(ctx: Context, start: usize, end: usize) void {
                    for (start..end) |chunk_idx| {
                        const begin = chunk_idx * ctx.chunk_size;
                        const chunk_end = @min(begin + ctx.chunk_size, ctx.data.len);
                        func(ctx.data[begin..chunk_end]);
                    }
                }
            }.body);
        }

        /// Execute a function for each chunk with its index in parallel.
        pub fn forEachWithIndex(self: Self, comptime func: fn (usize, []const T) void) void {
            const num_chunks = self.count();
            if (num_chunks == 0) return;

            const Context = struct {
                data: []const T,
                chunk_size: usize,
            };

            api.parallelFor(num_chunks, Context, .{
                .data = self.data,
                .chunk_size = self.chunk_size,
            }, struct {
                fn body(ctx: Context, start: usize, end: usize) void {
                    for (start..end) |chunk_idx| {
                        const begin = chunk_idx * ctx.chunk_size;
                        const chunk_end = @min(begin + ctx.chunk_size, ctx.data.len);
                        func(chunk_idx, ctx.data[begin..chunk_end]);
                    }
                }
            }.body);
        }

        /// Reduce over chunks in parallel.
        pub fn reduce(self: Self, comptime R: type, identity: R, comptime chunk_fn: fn ([]const T) R, comptime combine_fn: fn (R, R) R) R {
            const num_chunks = self.count();
            if (num_chunks == 0) return identity;

            const Context = struct {
                data: []const T,
                chunk_size: usize,
            };

            return api.parallelReduce(
                R,
                num_chunks,
                identity,
                Context,
                .{ .data = self.data, .chunk_size = self.chunk_size },
                struct {
                    fn mapFn(ctx: Context, chunk_idx: usize) R {
                        const begin = chunk_idx * ctx.chunk_size;
                        const chunk_end = @min(begin + ctx.chunk_size, ctx.data.len);
                        return chunk_fn(ctx.data[begin..chunk_end]);
                    }
                }.mapFn,
                combine_fn,
            );
        }
    };
}

/// Mutable parallel iterator over fixed-size chunks of a slice.
pub fn ChunksMutIter(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []T,
        chunk_size: usize,

        pub fn init(data: []T, chunk_size: usize) Self {
            std.debug.assert(chunk_size > 0);
            return Self{ .data = data, .chunk_size = chunk_size };
        }

        /// Number of chunks.
        pub fn count(self: Self) usize {
            if (self.data.len == 0) return 0;
            return (self.data.len + self.chunk_size - 1) / self.chunk_size;
        }

        /// Execute a function for each chunk in parallel (mutable access).
        pub fn forEach(self: Self, comptime func: fn ([]T) void) void {
            const num_chunks = self.count();
            if (num_chunks == 0) return;

            const Context = struct {
                data: []T,
                chunk_size: usize,
            };

            api.parallelFor(num_chunks, Context, .{
                .data = self.data,
                .chunk_size = self.chunk_size,
            }, struct {
                fn body(ctx: Context, start: usize, end: usize) void {
                    for (start..end) |chunk_idx| {
                        const begin = chunk_idx * ctx.chunk_size;
                        const chunk_end = @min(begin + ctx.chunk_size, ctx.data.len);
                        func(ctx.data[begin..chunk_end]);
                    }
                }
            }.body);
        }

        /// Execute a function for each chunk with its index in parallel (mutable access).
        pub fn forEachWithIndex(self: Self, comptime func: fn (usize, []T) void) void {
            const num_chunks = self.count();
            if (num_chunks == 0) return;

            const Context = struct {
                data: []T,
                chunk_size: usize,
            };

            api.parallelFor(num_chunks, Context, .{
                .data = self.data,
                .chunk_size = self.chunk_size,
            }, struct {
                fn body(ctx: Context, start: usize, end: usize) void {
                    for (start..end) |chunk_idx| {
                        const begin = chunk_idx * ctx.chunk_size;
                        const chunk_end = @min(begin + ctx.chunk_size, ctx.data.len);
                        func(chunk_idx, ctx.data[begin..chunk_end]);
                    }
                }
            }.body);
        }
    };
}
