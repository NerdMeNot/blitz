//! Parallel Sort Module
//!
//! High-performance parallel sorting algorithms.
//!
//! Features:
//! - **Unstable Sort** (PDQSort): Fast, in-place, O(log n) space
//! - **Stable Sort** (TimSort-based): Maintains relative order of equal elements, O(n) space
//! - BlockQuicksort partitioning
//! - Pattern detection for nearly-sorted data
//! - Heapsort fallback for O(n log n) guarantee
//! - Sort by key with optional caching
//!
//! Reference: https://github.com/orlp/pdqsort
//! Reference: https://github.com/rayon-rs/rayon/blob/main/src/slice/sort.rs

const pdqsort = @import("pdqsort.zig");
const stablesort = @import("stablesort.zig");
const by_key = @import("by_key.zig");
pub const helpers = @import("helpers.zig");

// ============================================================================
// Core Sort Functions
// ============================================================================

/// Sorts `v` in-place using parallel pattern-defeating quicksort.
/// Uses work-stealing for automatic load balancing.
///
/// Unstable sort: equal elements may be reordered.
/// Time: O(n log n) worst-case (heapsort fallback)
/// Space: O(log n) stack space
pub const sort = pdqsort.sort;

/// Sorts `v` in ascending order using the default `<` comparison.
pub const sortAsc = pdqsort.sortAsc;

/// Sorts `v` in descending order using the default `>` comparison.
pub const sortDesc = pdqsort.sortDesc;

// ============================================================================
// Stable Sort Functions
// ============================================================================

/// Sorts `v` in-place using a stable, parallel merge sort.
///
/// This is a stable sort: equal elements maintain their relative order.
/// Based on TimSort with parallel chunk sorting and merging.
///
/// Time: O(n log n) worst-case
/// Space: O(n) temporary buffer
pub const stableSort = stablesort.stableSort;

/// Sorts `v` in ascending order using a stable sort.
pub const stableSortAsc = stablesort.stableSortAsc;

/// Sorts `v` in descending order using a stable sort.
pub const stableSortDesc = stablesort.stableSortDesc;

// ============================================================================
// Sort By Key Functions
// ============================================================================

/// Sort by a key extraction function.
/// Keys are computed on each comparison.
///
/// For expensive key functions, use `sortByCachedKey` instead.
pub const sortByKey = by_key.sortByKey;

/// Sort by key with parallel key caching.
/// Two-phase algorithm:
/// 1. Compute keys for all elements in parallel
/// 2. Sort by cached keys (no recomputation)
///
/// More efficient when key function is expensive.
pub const sortByCachedKey = by_key.sortByCachedKey;

/// Apply a permutation to a slice in-place.
pub const applyPermutation = by_key.applyPermutation;

// ============================================================================
// Tests
// ============================================================================

test {
    _ = @import("tests.zig");
    _ = @import("stablesort.zig");
}
