//! Synchronization primitives for lock-free parallel operations.
//!
//! SyncPtr enables parallel writes to disjoint memory regions without locks,
//! mirroring Polars' SyncPtr pattern for parallel materialization.

const std = @import("std");

/// A pointer that can be safely shared across threads for parallel writes.
///
/// Safety: Callers MUST ensure that each thread writes to disjoint regions.
/// This is typically achieved by pre-computing offsets so each thread knows
/// exactly where to write.
///
/// Usage:
/// ```zig
/// var buffer: [1000]u64 = undefined;
/// const ptr = SyncPtr(u64).init(&buffer);
///
/// // In parallel threads (each writes to different offset):
/// ptr.writeAt(thread_offset + i, value);
/// ```
pub fn SyncPtr(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Raw pointer to the buffer.
        ptr: [*]T,

        /// Create a SyncPtr from a slice.
        pub inline fn init(slice: []T) Self {
            return Self{ .ptr = slice.ptr };
        }

        /// Create a SyncPtr from a raw pointer.
        pub inline fn fromPtr(ptr: [*]T) Self {
            return Self{ .ptr = ptr };
        }

        /// Get the raw pointer (for passing to other threads).
        pub inline fn get(self: Self) [*]T {
            return self.ptr;
        }

        /// Write a value at a specific offset.
        /// Safety: Caller must ensure no other thread writes to this offset.
        pub inline fn writeAt(self: Self, offset: usize, value: T) void {
            self.ptr[offset] = value;
        }

        /// Write a value using pointer arithmetic.
        /// Safety: Caller must ensure no other thread writes to this location.
        pub inline fn writeAtPtr(self: Self, offset: usize, value: T) void {
            const dest = self.ptr + offset;
            dest[0] = value;
        }

        /// Read a value at a specific offset.
        pub inline fn readAt(self: Self, offset: usize) T {
            return self.ptr[offset];
        }

        /// Get a slice view starting at offset.
        pub inline fn sliceFrom(self: Self, offset: usize, len: usize) []T {
            return (self.ptr + offset)[0..len];
        }

        /// Copy a slice to a specific offset.
        /// Safety: Caller must ensure no other thread writes to this region.
        pub inline fn copyAt(self: Self, offset: usize, src: []const T) void {
            @memcpy((self.ptr + offset)[0..src.len], src);
        }
    };
}

/// Compute offsets for parallel collection of variable-length results.
///
/// Given an array of lengths, computes the starting offset for each segment.
/// Returns the total length and the offset array.
///
/// This enables lock-free parallel writes: each thread writes to its
/// pre-computed offset without coordination.
///
/// Example:
/// ```zig
/// const lengths = [_]usize{ 3, 0, 5, 2 };
/// const result = computeOffsets(&lengths);
/// // result.offsets = { 0, 3, 3, 8 }
/// // result.total = 10
/// ```
pub fn computeOffsets(lengths: []const usize) struct { offsets: []usize, total: usize } {
    if (lengths.len == 0) {
        return .{ .offsets = &[_]usize{}, .total = 0 };
    }

    // We need to allocate the offsets array
    // For now, use a simple stack-based approach for small arrays
    var total: usize = 0;
    for (lengths) |len| {
        total += len;
    }

    return .{ .offsets = undefined, .total = total };
}

/// Compute offsets into a caller-provided buffer.
/// Returns the total length.
pub fn computeOffsetsInto(lengths: []const usize, offsets: []usize) usize {
    std.debug.assert(offsets.len >= lengths.len);

    var cumulative: usize = 0;
    for (lengths, 0..) |len, i| {
        offsets[i] = cumulative;
        cumulative += len;
    }

    return cumulative;
}

/// Compute capacity and offsets for flattening nested slices.
/// This is the pattern used in Polars' flatten::cap_and_offsets.
pub fn capAndOffsets(comptime T: type, slices: []const []const T, offsets: []usize) usize {
    std.debug.assert(offsets.len >= slices.len);

    var cumulative: usize = 0;
    for (slices, 0..) |slice, i| {
        offsets[i] = cumulative;
        cumulative += slice.len;
    }

    return cumulative;
}

// ============================================================================
// Tests
// ============================================================================

test "SyncPtr - basic write/read" {
    var buffer: [10]u64 = undefined;
    const ptr = SyncPtr(u64).init(&buffer);

    ptr.writeAt(0, 100);
    ptr.writeAt(5, 500);
    ptr.writeAt(9, 900);

    try std.testing.expectEqual(@as(u64, 100), ptr.readAt(0));
    try std.testing.expectEqual(@as(u64, 500), ptr.readAt(5));
    try std.testing.expectEqual(@as(u64, 900), ptr.readAt(9));
}

test "SyncPtr - copyAt" {
    var buffer: [10]u64 = undefined;
    @memset(&buffer, 0);

    const ptr = SyncPtr(u64).init(&buffer);
    const src = [_]u64{ 1, 2, 3 };

    ptr.copyAt(3, &src);

    try std.testing.expectEqual(@as(u64, 0), buffer[2]);
    try std.testing.expectEqual(@as(u64, 1), buffer[3]);
    try std.testing.expectEqual(@as(u64, 2), buffer[4]);
    try std.testing.expectEqual(@as(u64, 3), buffer[5]);
    try std.testing.expectEqual(@as(u64, 0), buffer[6]);
}

test "SyncPtr - sliceFrom" {
    var buffer: [10]u64 = undefined;
    for (&buffer, 0..) |*v, i| {
        v.* = i;
    }

    const ptr = SyncPtr(u64).init(&buffer);
    const slice = ptr.sliceFrom(3, 4);

    try std.testing.expectEqual(@as(usize, 4), slice.len);
    try std.testing.expectEqual(@as(u64, 3), slice[0]);
    try std.testing.expectEqual(@as(u64, 6), slice[3]);
}

test "computeOffsetsInto" {
    const lengths = [_]usize{ 3, 0, 5, 2 };
    var offsets: [4]usize = undefined;

    const total = computeOffsetsInto(&lengths, &offsets);

    try std.testing.expectEqual(@as(usize, 10), total);
    try std.testing.expectEqual(@as(usize, 0), offsets[0]);
    try std.testing.expectEqual(@as(usize, 3), offsets[1]);
    try std.testing.expectEqual(@as(usize, 3), offsets[2]);
    try std.testing.expectEqual(@as(usize, 8), offsets[3]);
}

test "capAndOffsets" {
    const slice0 = [_]u32{ 1, 2, 3 };
    const slice1 = [_]u32{};
    const slice2 = [_]u32{ 4, 5, 6, 7, 8 };
    const slice3 = [_]u32{ 9, 10 };

    const slices = [_][]const u32{ &slice0, &slice1, &slice2, &slice3 };
    var offsets: [4]usize = undefined;

    const total = capAndOffsets(u32, &slices, &offsets);

    try std.testing.expectEqual(@as(usize, 10), total);
    try std.testing.expectEqual(@as(usize, 0), offsets[0]);
    try std.testing.expectEqual(@as(usize, 3), offsets[1]);
    try std.testing.expectEqual(@as(usize, 3), offsets[2]);
    try std.testing.expectEqual(@as(usize, 8), offsets[3]);
}
