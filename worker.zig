//! Worker and Task for Blitz - Rayon-style Work Stealing
//!
//! Re-exports Worker and Task from pool.zig for backwards compatibility.
//! The actual implementation lives in pool.zig.

const pool = @import("pool.zig");

pub const Worker = pool.Worker;
pub const Task = pool.Task;
pub const WorkerStats = pool.WorkerStats;
pub const ThreadPool = pool.ThreadPool;
pub const Job = pool.Job;
