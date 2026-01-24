//! Job - re-exports from pool.zig for backwards compatibility
const pool = @import("pool.zig");
pub const Job = pool.Job;
pub const Task = pool.Task;
