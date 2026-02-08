//! Runtime state and pool management for Blitz.
//!
//! This module contains the shared global state that all parallel operations depend on:
//! - Global thread pool management (init, deinit, getPool)
//! - Thread-local task context (current_task)
//! - Runtime-configurable grain size
//!
//! Other ops modules import this to access the shared state.

const std = @import("std");
pub const pool_mod = @import("../Pool.zig");
pub const Job = pool_mod.Job;
pub const Worker = pool_mod.Worker;
pub const Task = pool_mod.Task;
pub const ThreadPool = pool_mod.ThreadPool;
pub const ThreadPoolConfig = pool_mod.ThreadPoolConfig;
pub const Future = @import("../Future.zig").Future;

/// Default grain size - minimum work per task.
/// Below this, we don't parallelize to avoid overhead.
pub const DEFAULT_GRAIN_SIZE: usize = 65536;

// ============================================================================
// Runtime Configuration
// ============================================================================

/// Runtime-configurable grain size. Defaults to DEFAULT_GRAIN_SIZE.
var configured_grain_size: std.atomic.Value(usize) = std.atomic.Value(usize).init(DEFAULT_GRAIN_SIZE);

/// Get the current grain size (runtime-configurable).
pub fn getGrainSize() usize {
    return configured_grain_size.load(.monotonic);
}

/// Set the grain size for parallel operations.
/// Pass 0 to reset to the default value.
pub fn setGrainSize(size: usize) void {
    const value = if (size == 0) DEFAULT_GRAIN_SIZE else size;
    configured_grain_size.store(value, .monotonic);
}

/// Get the default grain size (compile-time constant).
pub fn defaultGrainSize() usize {
    return DEFAULT_GRAIN_SIZE;
}

// ============================================================================
// Global Pool Management
// ============================================================================

var global_pool: ?*ThreadPool = null;
var pool_mutex: std.Thread.Mutex = .{};
var pool_allocator: std.mem.Allocator = undefined;

/// Atomic flag for fast isInitialized() check.
var pool_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Cached worker count (set once at init, read without lock).
var cached_num_workers: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);

/// Thread-local task context for fast recursive calls.
/// When set, we're already inside a pool.call() and can use fork/join directly.
pub threadlocal var current_task: ?*Task = null;

/// Initialize the global thread pool with default configuration.
///
/// Must be called before using any parallel operations. Without this,
/// all parallel operations execute sequentially as a fallback.
///
/// Returns error.AlreadyInitialized if called more than once.
/// Call deinit() first if you need to re-initialize with different settings.
pub fn init() !void {
    return initWithConfig(.{});
}

/// Initialize with custom configuration.
///
/// Must be called before using any parallel operations. Without this,
/// all parallel operations execute sequentially as a fallback.
///
/// Returns error.AlreadyInitialized if called more than once.
/// Call deinit() first if you need to re-initialize with different settings.
pub fn initWithConfig(config: ThreadPoolConfig) !void {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool != null) return error.AlreadyInitialized;

    pool_allocator = std.heap.c_allocator;
    const pool = try pool_allocator.create(ThreadPool);
    pool.* = ThreadPool.init(pool_allocator);
    try pool.start(config);
    global_pool = pool;

    cached_num_workers.store(@intCast(pool.numWorkers()), .release);
    pool_initialized.store(true, .release);
}

/// Shutdown the global thread pool.
///
/// All worker threads are joined and resources freed.
/// After this call, parallel operations will execute sequentially
/// until init() is called again.
pub fn deinit() void {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool) |pool| {
        pool_initialized.store(false, .release);
        cached_num_workers.store(1, .release);

        pool.deinit();
        pool_allocator.destroy(pool);
        global_pool = null;
    }
}

/// Check if the pool is initialized.
pub inline fn isInitialized() bool {
    return pool_initialized.load(.acquire);
}

/// Get the number of worker threads (1 if pool not initialized).
pub inline fn numWorkers() u32 {
    return cached_num_workers.load(.monotonic);
}

/// Pool stats for debugging.
pub const PoolStats = struct { executed: u64, stolen: u64 };

/// Get pool stats (executed, stolen) for debugging.
/// Acquires the pool mutex; avoid calling in hot paths.
pub fn getStats() PoolStats {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool) |pool| {
        const s = pool.getStats();
        return .{ .executed = s.executed, .stolen = s.stolen };
    }
    return .{ .executed = 0, .stolen = 0 };
}

/// Reset pool stats.
/// Acquires the pool mutex; avoid calling in hot paths.
pub fn resetStats() void {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool) |pool| {
        pool.resetStats();
    }
}

/// Get the global pool if initialized, or null.
///
/// Returns null if init() has not been called. Parallel operations
/// that receive null fall back to sequential execution.
pub fn getPool() ?*ThreadPool {
    // Must go through the mutex to prevent a TOCTOU race with deinit().
    // The pool_initialized flag is still useful for the common isInitialized()
    // check in hot paths (where we don't need the pointer).
    pool_mutex.lock();
    defer pool_mutex.unlock();

    return global_pool;
}
