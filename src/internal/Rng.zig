//! Fast Per-Thread Random Number Generator for Blitz
//!
//! Uses XorShift64* - a high-quality, fast PRNG suitable for work-stealing
//! victim selection in parallel schedulers.
//!
//! Properties:
//! - Period: 2^64 - 1
//! - Passes BigCrush statistical tests
//! - ~3ns per random number
//! - No branching in the hot path

const std = @import("std");

/// XorShift64* random number generator.
///
/// Fast PRNG for randomized victim selection in work-stealing.
/// ~3ns per call with good statistical properties.
pub const XorShift64Star = struct {
    state: u64,

    /// Initialize with a seed. Zero is automatically replaced with a good seed.
    pub fn init(seed: u64) XorShift64Star {
        // Zero state would produce all zeros, so use a default seed
        return .{ .state = if (seed == 0) 0x853c49e6748fea9b else seed };
    }

    /// Initialize from thread ID and timestamp for per-thread uniqueness.
    pub fn initFromThread() XorShift64Star {
        const tid = std.Thread.getCurrentId();
        const time: u64 = @bitCast(std.time.nanoTimestamp());
        // Mix bits to get a good starting state
        return init(tid ^ time ^ 0x2545f4914f6cdd1d);
    }

    /// Initialize from an index (for deterministic per-worker seeds).
    pub fn initFromIndex(idx: usize) XorShift64Star {
        // Use a different multiplier for each worker to spread out sequences
        const seed = (@as(u64, idx) +% 1) *% 0x9e3779b97f4a7c15;
        return init(seed);
    }

    /// Generate the next random u64.
    pub fn next(self: *XorShift64Star) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545f4914f6cdd1d;
    }

    /// Generate a random number in [0, n).
    /// Uses Lemire's nearly-divisionless method for uniform distribution.
    /// Reference: "Fast Random Integer Generation in an Interval" (Lemire 2018)
    pub fn nextBounded(self: *XorShift64Star, n: usize) usize {
        if (n == 0) return 0;
        if (n == 1) return 0;

        // Fast path for powers of 2
        if (std.math.isPowerOfTwo(n)) {
            return @intCast(self.next() & (@as(u64, n) - 1));
        }

        // Lemire's nearly-divisionless method
        // This is O(1) in the common case (no rejection needed ~99.9% of time)
        const s = @as(u64, n);
        var x = self.next();
        var m: u128 = @as(u128, x) * @as(u128, s);
        var l: u64 = @truncate(m); // Low 64 bits

        if (l < s) {
            // Rare case: need to check for bias
            const t = (0 -% s) % s; // (2^64 - s) mod s
            while (l < t) {
                x = self.next();
                m = @as(u128, x) * @as(u128, s);
                l = @truncate(m);
            }
        }

        return @intCast(m >> 64); // High 64 bits
    }

    /// Generate a random index different from `exclude`.
    /// Useful for selecting a victim that isn't ourselves.
    pub fn nextExcluding(self: *XorShift64Star, n: usize, exclude: usize) usize {
        if (n <= 1) return 0;

        // Generate in [0, n-1) then skip over the excluded value
        var idx = self.nextBounded(n - 1);
        if (idx >= exclude) {
            idx += 1;
        }
        return idx;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "XorShift64Star - basic" {
    var rng = XorShift64Star.init(12345);

    // Generate some numbers and check they're different
    const a = rng.next();
    const b = rng.next();
    const c = rng.next();

    try std.testing.expect(a != b);
    try std.testing.expect(b != c);
    try std.testing.expect(a != c);
}

test "XorShift64Star - initFromIndex produces different sequences" {
    var rng0 = XorShift64Star.initFromIndex(0);
    var rng1 = XorShift64Star.initFromIndex(1);
    var rng2 = XorShift64Star.initFromIndex(2);

    try std.testing.expect(rng0.next() != rng1.next());
    try std.testing.expect(rng1.next() != rng2.next());
}

test "XorShift64Star - nextBounded" {
    var rng = XorShift64Star.init(42);

    // Generate bounded numbers and verify they're in range
    for (0..100) |_| {
        const val = rng.nextBounded(10);
        try std.testing.expect(val < 10);
    }
}

test "XorShift64Star - nextBounded power of 2" {
    var rng = XorShift64Star.init(42);

    for (0..100) |_| {
        const val = rng.nextBounded(16);
        try std.testing.expect(val < 16);
    }
}

test "XorShift64Star - nextExcluding" {
    var rng = XorShift64Star.init(42);

    // Verify excluded value is never returned
    for (0..100) |_| {
        const val = rng.nextExcluding(10, 5);
        try std.testing.expect(val < 10);
        try std.testing.expect(val != 5);
    }
}

test "XorShift64Star - nextExcluding edge cases" {
    var rng = XorShift64Star.init(42);

    // n=2, exclude=0 should always return 1
    for (0..10) |_| {
        try std.testing.expectEqual(@as(usize, 1), rng.nextExcluding(2, 0));
    }

    // n=2, exclude=1 should always return 0
    for (0..10) |_| {
        try std.testing.expectEqual(@as(usize, 0), rng.nextExcluding(2, 1));
    }
}

test "XorShift64Star - distribution" {
    var rng = XorShift64Star.init(12345);
    var counts: [4]u32 = .{ 0, 0, 0, 0 };

    // Generate many samples
    for (0..10000) |_| {
        const val = rng.nextBounded(4);
        counts[val] += 1;
    }

    // Each bucket should have roughly 2500 hits (within reasonable variance)
    for (counts) |count| {
        try std.testing.expect(count > 2000);
        try std.testing.expect(count < 3000);
    }
}
