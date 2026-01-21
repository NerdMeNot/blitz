//! Lock-Free Work-Stealing Deque (Chase-Lev Style)
//!
//! Implements a lock-free double-ended queue optimized for work-stealing:
//! - Owner pushes/pops from bottom (LIFO for cache locality)
//! - Thieves steal from top (FIFO for load balancing)
//!
//! This is the core data structure that enables Rayon-style instant stealing.
//! Multiple thieves can steal simultaneously without blocking.
//!
//! Reference: "Dynamic Circular Work-Stealing Deque" by Chase and Lev (2005)

const std = @import("std");

/// Result of a steal operation.
pub const StealResult = enum {
    /// Deque was empty.
    empty,
    /// Successfully stole an item.
    success,
    /// Lost race with owner or another thief, should retry.
    retry,
};

/// Cache line size for padding (typically 64 bytes on modern CPUs).
const CACHE_LINE = std.atomic.cache_line;

/// Lock-free work-stealing deque.
///
/// The deque is a circular buffer with atomic indices:
/// - `bottom`: Owner's end (push/pop here)
/// - `top`: Thieves' end (steal from here)
///
/// Critical optimization: head and tail are on separate cache lines
/// to prevent false sharing between owner and thief threads.
///
/// Invariant: top <= bottom (when top == bottom, deque is empty)
pub fn Deque(comptime T: type) type {
    return struct {
        const Self = @This();

        // === Cache line 1: Thief-contended data ===
        /// Thieves' index (top of deque). Thieves CAS this.
        /// Cache-line aligned to isolate thief contention from owner.
        top: std.atomic.Value(isize) align(CACHE_LINE),

        // Padding to prevent false sharing between top and bottom
        _padding: [CACHE_LINE - @sizeOf(std.atomic.Value(isize))]u8 = undefined,

        // === Cache line 2: Owner-exclusive data ===
        /// Owner's index (bottom of deque). Only owner writes this.
        /// Cache-line aligned, only modified by owner thread.
        bottom: std.atomic.Value(isize) align(CACHE_LINE),

        // Padding to separate bottom from buffer/mask metadata
        _padding2: [CACHE_LINE - @sizeOf(std.atomic.Value(isize))]u8 = undefined,

        // === Cache line 3: Read-only metadata (after init) ===
        /// Circular buffer of items.
        buffer: []T align(CACHE_LINE),

        /// Mask for wrapping indices (buffer.len - 1, assumes power of 2).
        mask: usize,

        /// Allocator for potential resize operations.
        allocator: std.mem.Allocator,

        /// Initialize a deque with the given capacity.
        /// Capacity must be a power of 2.
        pub fn init(alloc: std.mem.Allocator, capacity: usize) !Self {
            std.debug.assert(capacity > 0);
            std.debug.assert(std.math.isPowerOfTwo(capacity));

            const buffer = try alloc.alloc(T, capacity);

            return Self{
                .top = std.atomic.Value(isize).init(0),
                ._padding = undefined,
                .bottom = std.atomic.Value(isize).init(0),
                ._padding2 = undefined,
                .buffer = buffer,
                .mask = capacity - 1,
                .allocator = alloc,
            };
        }

        /// Deinitialize and free the buffer.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            _ = allocator; // Use stored allocator
            self.allocator.free(self.buffer);
            self.* = undefined;
        }

        /// Grow the deque capacity (called when overflow detected).
        /// This is called from push() when the deque is full.
        /// SAFETY: Only the owner thread calls this, no synchronization needed for buffer.
        fn grow(self: *Self) !void {
            const old_capacity = self.buffer.len;
            const new_capacity = old_capacity * 2;

            const new_buffer = try self.allocator.alloc(T, new_capacity);

            // Copy existing items to new buffer
            const t = self.top.load(.acquire);
            const b = self.bottom.load(.monotonic);

            var i = t;
            while (i < b) : (i += 1) {
                const old_idx = @as(usize, @intCast(i)) & self.mask;
                const new_idx = @as(usize, @intCast(i)) & (new_capacity - 1);
                new_buffer[new_idx] = self.buffer[old_idx];
            }

            self.allocator.free(self.buffer);
            self.buffer = new_buffer;
            self.mask = new_capacity - 1;
        }

        /// Get the current number of items (approximate, may race with steal).
        pub inline fn len(self: *const Self) usize {
            const b = self.bottom.load(.acquire);
            const t = self.top.load(.acquire);
            if (b >= t) {
                return @intCast(b - t);
            }
            return 0;
        }

        /// Check if empty (approximate).
        pub inline fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        /// Push an item onto the bottom (owner only).
        ///
        /// This is the fast path - no synchronization with other pushes/pops
        /// since only the owner calls this.
        pub inline fn push(self: *Self, item: T) void {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.acquire);

            // Check for overflow (deque full) - grow dynamically
            const size = b - t;
            if (size >= @as(isize, @intCast(self.buffer.len))) {
                self.grow() catch @panic("Deque grow failed - out of memory");
            }

            // Store the item (use mask for fast modulo)
            const idx = @as(usize, @intCast(b)) & self.mask;
            self.buffer[idx] = item;

            // Publish the new bottom with release ordering
            // This ensures the item write is visible before the bottom update
            self.bottom.store(b + 1, .release);
        }

        /// Pop an item from the bottom (owner only).
        ///
        /// Returns null if the deque is empty.
        pub inline fn pop(self: *Self) ?T {
            // Decrement bottom first with seq_cst to ensure visibility to stealers
            const b = self.bottom.load(.monotonic) - 1;
            self.bottom.store(b, .seq_cst);

            const t = self.top.load(.seq_cst);

            if (t <= b) {
                // Non-empty: at least one item
                const idx = @as(usize, @intCast(b)) & self.mask;
                const item = self.buffer[idx];

                if (t == b) {
                    // Last item - race with stealers
                    // Try to claim it by incrementing top
                    if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic)) |_| {
                        // Lost the race - someone stole it
                        self.bottom.store(t + 1, .monotonic);
                        return null;
                    }
                    // Won the race
                    self.bottom.store(t + 1, .monotonic);
                }
                return item;
            } else {
                // Empty
                self.bottom.store(t, .monotonic);
                return null;
            }
        }

        /// Steal an item from the top (thieves).
        ///
        /// Returns a result indicating success, empty, or retry.
        /// On success, also returns the stolen item.
        ///
        /// Memory ordering (from "Correct and Efficient Work-Stealing"):
        /// - top load: .acquire (synchronize with owner's pushes)
        /// - bottom load: .acquire (see owner's decrements)
        /// - CAS: .seq_cst (correctness for multi-party race)
        pub fn steal(self: *Self) struct { result: StealResult, item: ?T } {
            // 1. Read top first with acquire ordering
            const t = self.top.load(.acquire);

            // 2. Read bottom with acquire to see owner's operations
            const b = self.bottom.load(.acquire);

            if (t >= b) {
                // Empty
                return .{ .result = .empty, .item = null };
            }

            // 3. Speculatively read the item
            const idx = @as(usize, @intCast(t)) & self.mask;
            const item = self.buffer[idx];

            // 4. Try to claim by incrementing top with CAS
            if (self.top.cmpxchgWeak(t, t + 1, .seq_cst, .monotonic)) |_| {
                // Lost the race - another thief got it or owner popped
                return .{ .result = .retry, .item = null };
            }

            // Success!
            return .{ .result = .success, .item = item };
        }

        /// Steal with retry loop and exponential backoff.
        /// Uses adaptive backoff to reduce cache coherency traffic under contention.
        pub fn stealLoop(self: *Self) ?T {
            var backoff: u32 = 0;
            const SPIN_LIMIT: u32 = 6; // ~64 spins max

            while (true) {
                const result = self.steal();
                switch (result.result) {
                    .success => return result.item,
                    .empty => return null,
                    .retry => {
                        // Exponential backoff on contention
                        if (backoff < SPIN_LIMIT) {
                            const spins = @as(u32, 1) << @intCast(backoff);
                            var i: u32 = 0;
                            while (i < spins) : (i += 1) {
                                std.atomic.spinLoopHint();
                            }
                            backoff += 1;
                        } else {
                            // Heavy contention - yield to OS
                            std.Thread.yield() catch {};
                        }
                    },
                }
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Deque - basic push and pop" {
    var deque = try Deque(u32).init(std.testing.allocator, 16);
    defer deque.deinit(std.testing.allocator);

    // Push some items
    deque.push(1);
    deque.push(2);
    deque.push(3);

    try std.testing.expectEqual(@as(usize, 3), deque.len());

    // Pop in LIFO order
    try std.testing.expectEqual(@as(?u32, 3), deque.pop());
    try std.testing.expectEqual(@as(?u32, 2), deque.pop());
    try std.testing.expectEqual(@as(?u32, 1), deque.pop());
    try std.testing.expectEqual(@as(?u32, null), deque.pop());
}

test "Deque - steal from empty" {
    var deque = try Deque(u32).init(std.testing.allocator, 16);
    defer deque.deinit(std.testing.allocator);

    const result = deque.steal();
    try std.testing.expectEqual(StealResult.empty, result.result);
    try std.testing.expectEqual(@as(?u32, null), result.item);
}

test "Deque - steal FIFO order" {
    var deque = try Deque(u32).init(std.testing.allocator, 16);
    defer deque.deinit(std.testing.allocator);

    // Push items
    deque.push(1);
    deque.push(2);
    deque.push(3);

    // Steal from top (FIFO order)
    const r1 = deque.steal();
    try std.testing.expectEqual(StealResult.success, r1.result);
    try std.testing.expectEqual(@as(?u32, 1), r1.item);

    const r2 = deque.steal();
    try std.testing.expectEqual(StealResult.success, r2.result);
    try std.testing.expectEqual(@as(?u32, 2), r2.item);

    // Pop from bottom (owner gets 3)
    try std.testing.expectEqual(@as(?u32, 3), deque.pop());

    // Now empty
    try std.testing.expectEqual(StealResult.empty, deque.steal().result);
}

test "Deque - single item race" {
    var deque = try Deque(u32).init(std.testing.allocator, 16);
    defer deque.deinit(std.testing.allocator);

    // Push one item
    deque.push(42);

    // Owner pops - should get the item
    try std.testing.expectEqual(@as(?u32, 42), deque.pop());

    // Now empty
    try std.testing.expect(deque.isEmpty());
}

test "Deque - stealLoop" {
    var deque = try Deque(u32).init(std.testing.allocator, 16);
    defer deque.deinit(std.testing.allocator);

    deque.push(100);
    deque.push(200);

    // stealLoop should get 100 (FIFO)
    try std.testing.expectEqual(@as(?u32, 100), deque.stealLoop());
    try std.testing.expectEqual(@as(?u32, 200), deque.stealLoop());
    try std.testing.expectEqual(@as(?u32, null), deque.stealLoop());
}

test "Deque - wrap around" {
    var deque = try Deque(u32).init(std.testing.allocator, 4);
    defer deque.deinit(std.testing.allocator);

    // Push and pop to advance indices
    for (0..10) |i| {
        deque.push(@intCast(i));
        _ = deque.pop();
    }

    // Now push more - should wrap around correctly
    deque.push(100);
    deque.push(200);

    try std.testing.expectEqual(@as(?u32, 200), deque.pop());
    try std.testing.expectEqual(@as(?u32, 100), deque.pop());
}
