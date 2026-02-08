# blitz-io: Async I/O Runtime for Zig

A high-performance, cross-platform async I/O runtime for Zig, designed to complement [Blitz](https://github.com/your-repo/blitz) (CPU parallelism) like Tokio complements Rayon in the Rust ecosystem.

---

## Table of Contents

1. [Vision & Philosophy](#vision--philosophy)
2. [Architecture Overview](#architecture-overview)
3. [Core Components](#core-components)
4. [Platform Backends](#platform-backends)
5. [Task Executor](#task-executor)
6. [Async Primitives](#async-primitives)
7. [Network I/O](#network-io)
8. [File I/O](#file-io)
9. [Timers & Scheduling](#timers--scheduling)
10. [Blitz Integration](#blitz-integration)
11. [API Reference](#api-reference)
12. [Implementation Roadmap](#implementation-roadmap)
13. [Performance Considerations](#performance-considerations)
14. [Testing Strategy](#testing-strategy)
15. [References & Prior Art](#references--prior-art)

---

## Vision & Philosophy

### Mission Statement

blitz-io provides Zig developers with a production-grade async I/O runtime that:

1. **Implements `std.Io`** - First-class citizen in Zig's ecosystem, forward-compatible with Zig 0.16+
2. **Spawns millions of tasks efficiently** - Stackless coroutines with ~100-256 bytes per task
3. **Adapts to the platform** - Automatically selects best backend (io_uring → kqueue → IOCP)
4. **Complements Blitz** - Seamless handoff between I/O-bound and CPU-bound work
5. **Just works** - Sensible adaptive defaults, minimal configuration required

### Design Principles

| Principle | Description |
|-----------|-------------|
| **Zig-native** | Implement `std.Io` interface, not a foreign paradigm |
| **Zero-cost abstractions** | Pay only for what you use |
| **Explicit over implicit** | Clear spawning points, predictable behavior |
| **Adaptive defaults** | Auto-tune based on platform, workload, and hardware |
| **Minimal allocations** | Pool buffers, reuse memory, avoid heap pressure |
| **Composable** | Small, focused components that combine well |

### Comparison with Alternatives

| Feature | blitz-io | Tokio (Rust) | Go Runtime | zig-aio |
|---------|----------|--------------|------------|---------|
| std.Io compatible | ✓ | N/A | N/A | ✓ |
| Stackless tasks | ✓ | ✓ | ✗ (stackful) | ✗ (stackful) |
| io_uring | ✓ | via tokio-uring | ✗ | ✓ |
| Work-stealing | ✓ (optional) | ✓ | ✓ | ✗ |
| Thread-per-core | ✓ | via tokio-uring | ✗ | ✗ |
| Blitz integration | ✓ | N/A | N/A | ✗ |
| WASM support | ✓ (limited) | ✗ | ✗ | ✗ |

---

## Architecture Overview

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         User Application                             │
│                    (uses std.Io interface)                          │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                           std.Io Interface                           │
│              (Zig standard library abstraction)                      │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         blitz-io Runtime                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────────┐ │
│  │   Executor  │  │  I/O Driver │  │   Timers    │  │   Sync     │ │
│  │             │  │             │  │             │  │ Primitives │ │
│  │ • Scheduler │  │ • Submit    │  │ • Wheel     │  │            │ │
│  │ • Task Pool │  │ • Complete  │  │ • Deadline  │  │ • Channel  │ │
│  │ • Work Steal│  │ • Poll      │  │ • Interval  │  │ • Mutex    │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └────────────┘ │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │                      Platform Backend                            ││
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        ││
│  │  │ io_uring │  │  kqueue  │  │   IOCP   │  │   epoll  │        ││
│  │  │ (Linux)  │  │ (macOS)  │  │ (Windows)│  │(fallback)│        ││
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘        ││
│  └─────────────────────────────────────────────────────────────────┘│
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                              Blitz                                   │
│                    (CPU-bound work handoff)                         │
└─────────────────────────────────────────────────────────────────────┘
```

### Component Interaction

```
User calls io.async(task)
         │
         ▼
┌─────────────────┐
│    Executor     │ ◄─── Manages task lifecycle
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Task created   │ ◄─── Stackless state machine (~100-256 bytes)
│  (Future<T>)    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Scheduled     │ ◄─── Added to run queue
└────────┬────────┘
         │
    ┌────┴────┐
    ▼         ▼
┌───────┐ ┌───────┐
│ Poll  │ │ I/O   │
│ task  │ │ wait  │
└───┬───┘ └───┬───┘
    │         │
    ▼         ▼
┌─────────────────┐
│   Completion    │ ◄─── Task continues or completes
└─────────────────┘
```

---

## Core Components

### 1. Runtime

The `Runtime` is the entry point and owns all resources.

```zig
// src/runtime.zig

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: Io,
    executor: Executor,
    driver: Driver,
    timers: TimerWheel,
    config: Config,

    // Lifecycle
    pub fn init(allocator: std.mem.Allocator, config: Config) !Runtime
    pub fn deinit(self: *Runtime) void

    // Execution
    pub fn block_on(self: *Runtime, comptime func: anytype, args: anytype) ReturnType(func)
    pub fn spawn(self: *Runtime, comptime func: anytype, args: anytype) TaskHandle
    pub fn shutdown(self: *Runtime) void

    // Access
    pub fn io(self: *Runtime) *Io
};
```

### 2. Configuration

Adaptive defaults with full configurability.

```zig
// src/config.zig

pub const Config = struct {
    /// Execution strategy
    strategy: Strategy = .auto,

    /// Thread configuration
    threads: ThreadConfig = .{},

    /// I/O driver settings
    io: IoConfig = .{},

    /// Timer settings
    timers: TimerConfig = .{},

    /// Memory settings
    memory: MemoryConfig = .{},

    pub const Strategy = enum {
        /// Auto-detect best strategy for platform
        /// Linux: thread_per_core with io_uring
        /// macOS: work_stealing with kqueue
        /// Windows: work_stealing with IOCP
        auto,

        /// Each thread owns its tasks (no migration)
        /// Best throughput, tasks are !Send
        /// Ideal for: high-throughput servers, io_uring
        thread_per_core,

        /// Tasks can migrate between threads
        /// Better latency distribution
        /// Ideal for: mixed workloads, latency-sensitive
        work_stealing,

        /// Single-threaded, blocking
        /// For testing, debugging, simple scripts
        single_threaded,
    };

    pub const ThreadConfig = struct {
        /// Number of worker threads
        /// null = auto-detect based on CPU topology
        count: ?u32 = null,

        /// Pin threads to cores (NUMA-aware)
        affinity: Affinity = .auto,

        /// Stack size for worker threads (OS threads, not tasks)
        stack_size: usize = 2 * 1024 * 1024, // 2MB

        pub const Affinity = enum {
            auto,      // Detect NUMA topology
            none,      // No pinning
            sequential,// Pin to cores 0, 1, 2, ...
        };
    };

    pub const IoConfig = struct {
        /// I/O backend selection
        backend: Backend = .auto,

        /// io_uring queue depth (Linux only)
        /// 0 = auto-tune based on expected concurrency
        ring_size: u32 = 0,

        /// Enable io_uring features
        uring_features: UringFeatures = .{},

        /// Buffer pool size for zero-copy I/O
        buffer_pool_size: usize = 64 * 1024 * 1024, // 64MB

        /// Individual buffer size
        buffer_size: usize = 16 * 1024, // 16KB

        pub const Backend = enum {
            auto,      // Best for platform
            io_uring,  // Linux 5.1+
            epoll,     // Linux fallback
            kqueue,    // macOS/BSD
            iocp,      // Windows
            poll,      // Universal fallback
        };

        pub const UringFeatures = struct {
            sqpoll: bool = false,        // Kernel-side polling
            iopoll: bool = false,        // Busy-wait for completions
            single_issuer: bool = true,  // Single thread submits
            defer_taskrun: bool = true,  // Defer task running
            registered_buffers: bool = true,
            registered_files: bool = true,
        };
    };

    pub const TimerConfig = struct {
        /// Timer wheel resolution
        tick_duration_ms: u32 = 1,

        /// Number of wheel slots
        wheel_size: u32 = 4096,

        /// Maximum timers (0 = unlimited)
        max_timers: u32 = 0,
    };

    pub const MemoryConfig = struct {
        /// Task object pool size
        task_pool_size: u32 = 10000,

        /// Enable memory pooling
        pooling: bool = true,

        /// Pre-allocate resources
        preallocate: bool = false,
    };
};
```

### 3. Io Interface

Implements Zig's `std.Io` interface.

```zig
// src/io.zig

pub const Io = struct {
    runtime: *Runtime,

    // ─────────────────────────────────────────────────────────
    // std.Io Interface Implementation
    // ─────────────────────────────────────────────────────────

    /// Create an async operation that may run concurrently
    pub fn @"async"(
        self: Io,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) Future(ReturnType(func)) {
        return self.runtime.executor.spawn(func, args);
    }

    /// Like async, but panics if runtime doesn't support concurrency
    pub fn asyncConcurrent(
        self: Io,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) Future(ReturnType(func)) {
        if (self.runtime.config.strategy == .single_threaded) {
            @panic("asyncConcurrent requires concurrent runtime");
        }
        return self.@"async"(func, args);
    }

    // ─────────────────────────────────────────────────────────
    // Filesystem Operations
    // ─────────────────────────────────────────────────────────

    pub const fs = struct {
        pub fn open(io: Io, path: []const u8, flags: OpenFlags) !File
        pub fn read(io: Io, file: File, buffer: []u8) !usize
        pub fn write(io: Io, file: File, data: []const u8) !usize
        pub fn close(io: Io, file: File) void
        pub fn stat(io: Io, path: []const u8) !Stat
        pub fn mkdir(io: Io, path: []const u8) !void
        pub fn readFile(io: Io, path: []const u8, allocator: Allocator) ![]u8
        pub fn writeFile(io: Io, path: []const u8, data: []const u8) !void
    };

    // ─────────────────────────────────────────────────────────
    // Network Operations
    // ─────────────────────────────────────────────────────────

    pub const net = struct {
        pub fn tcpConnect(io: Io, address: Address) !TcpStream
        pub fn tcpListen(io: Io, options: ListenOptions) !TcpListener
        pub fn udpBind(io: Io, address: Address) !UdpSocket
        pub fn resolve(io: Io, host: []const u8) ![]Address
    };

    // ─────────────────────────────────────────────────────────
    // Time Operations
    // ─────────────────────────────────────────────────────────

    pub fn sleep(self: Io, duration: Duration) void
    pub fn deadline(self: Io, timeout: Duration) Deadline
    pub fn interval(self: Io, period: Duration) Interval
    pub fn now(self: Io) Instant

    // ─────────────────────────────────────────────────────────
    // Process Operations
    // ─────────────────────────────────────────────────────────

    pub const process = struct {
        pub fn spawn(io: Io, config: SpawnConfig) !Child
        pub fn output(io: Io, config: SpawnConfig) !Output
    };

    // ─────────────────────────────────────────────────────────
    // Signal Handling
    // ─────────────────────────────────────────────────────────

    pub const signal = struct {
        pub fn wait(io: Io, sig: Signal) void
        pub fn stream(io: Io, sig: Signal) SignalStream
    };
};
```

### 4. Future

Represents an async operation's result.

```zig
// src/future.zig

pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        state: *TaskState,

        /// Wait for the operation to complete and return result
        pub fn await(self: Self, io: Io) T {
            return io.runtime.executor.await(self.state);
        }

        /// Cancel the operation
        /// Returns error.Canceled if operation was still running
        /// Idempotent - safe to call multiple times
        pub fn cancel(self: Self, io: Io) !void {
            return io.runtime.executor.cancel(self.state);
        }

        /// Check if operation is complete without blocking
        pub fn poll(self: Self) ?T {
            return self.state.tryGetResult();
        }

        /// Check if operation was canceled
        pub fn isCanceled(self: Self) bool {
            return self.state.status == .canceled;
        }
    };
}
```

---

## Platform Backends

### Backend Interface

All platform backends implement a common interface.

```zig
// src/backend/backend.zig

pub const Backend = union(enum) {
    io_uring: IoUringBackend,
    epoll: EpollBackend,
    kqueue: KqueueBackend,
    iocp: IocpBackend,
    poll: PollBackend,

    pub fn init(allocator: Allocator, config: Config.IoConfig) !Backend
    pub fn deinit(self: *Backend) void

    /// Submit an I/O operation
    pub fn submit(self: *Backend, op: Operation) !SubmissionId

    /// Wait for completions (blocking)
    pub fn wait(self: *Backend, completions: []Completion, timeout: ?Duration) !usize

    /// Poll for completions (non-blocking)
    pub fn poll(self: *Backend, completions: []Completion) !usize

    /// Cancel a pending operation
    pub fn cancel(self: *Backend, id: SubmissionId) !void

    /// Get file descriptor for integration with other event loops
    pub fn fd(self: Backend) ?std.posix.fd_t
};

pub const Operation = struct {
    op: OpType,
    user_data: usize,

    pub const OpType = union(enum) {
        // File operations
        read: struct { fd: fd_t, buffer: []u8, offset: ?u64 },
        write: struct { fd: fd_t, data: []const u8, offset: ?u64 },
        open: struct { path: [*:0]const u8, flags: u32, mode: u32 },
        close: struct { fd: fd_t },
        fsync: struct { fd: fd_t },

        // Network operations
        accept: struct { fd: fd_t, addr: *sockaddr, addr_len: *socklen_t },
        connect: struct { fd: fd_t, addr: *const sockaddr, addr_len: socklen_t },
        recv: struct { fd: fd_t, buffer: []u8, flags: u32 },
        send: struct { fd: fd_t, data: []const u8, flags: u32 },

        // Vectored I/O
        readv: struct { fd: fd_t, iovecs: []const iovec },
        writev: struct { fd: fd_t, iovecs: []const iovec },

        // Special
        timeout: struct { ts: *const timespec },
        cancel: struct { target_id: SubmissionId },
        nop: void,
    };
};

pub const Completion = struct {
    user_data: usize,
    result: i32,
    flags: u32,
};
```

### io_uring Backend (Linux)

The highest-performance backend for Linux 5.1+.

```zig
// src/backend/io_uring.zig

pub const IoUringBackend = struct {
    ring: std.os.linux.IoUring,
    pending: u32,
    config: Config.IoConfig,

    // Buffer management
    buffer_pool: ?BufferPool,
    registered_buffers: ?[]align(4096) u8,
    registered_fds: ?[]fd_t,

    pub fn init(allocator: Allocator, config: Config.IoConfig) !IoUringBackend {
        const ring_size = if (config.ring_size == 0)
            detectOptimalRingSize()
        else
            config.ring_size;

        var params = std.os.linux.io_uring_params{};

        // Apply feature flags
        if (config.uring_features.sqpoll) {
            params.flags |= std.os.linux.IORING_SETUP_SQPOLL;
        }
        if (config.uring_features.single_issuer) {
            params.flags |= std.os.linux.IORING_SETUP_SINGLE_ISSUER;
        }
        if (config.uring_features.defer_taskrun) {
            params.flags |= std.os.linux.IORING_SETUP_DEFER_TASKRUN;
        }

        const ring = try std.os.linux.IoUring.init(ring_size, params);

        var self = IoUringBackend{
            .ring = ring,
            .pending = 0,
            .config = config,
            .buffer_pool = null,
            .registered_buffers = null,
            .registered_fds = null,
        };

        // Register buffers for zero-copy I/O
        if (config.uring_features.registered_buffers) {
            try self.setupRegisteredBuffers(allocator, config);
        }

        return self;
    }

    pub fn submit(self: *IoUringBackend, op: Operation) !SubmissionId {
        const sqe = try self.ring.get_sqe();

        switch (op.op) {
            .read => |r| {
                sqe.prep_read(r.fd, r.buffer, r.offset orelse 0);
            },
            .write => |w| {
                sqe.prep_write(w.fd, w.data, w.offset orelse 0);
            },
            .accept => |a| {
                sqe.prep_accept(a.fd, a.addr, a.addr_len, 0);
            },
            .connect => |c| {
                sqe.prep_connect(c.fd, c.addr, c.addr_len);
            },
            .recv => |r| {
                sqe.prep_recv(r.fd, r.buffer, r.flags);
            },
            .send => |s| {
                sqe.prep_send(s.fd, s.data, s.flags);
            },
            // ... other operations
        }

        sqe.user_data = op.user_data;
        self.pending += 1;

        return SubmissionId{ .value = op.user_data };
    }

    pub fn wait(self: *IoUringBackend, completions: []Completion, timeout: ?Duration) !usize {
        const ts = if (timeout) |t| &timespecFromDuration(t) else null;

        _ = try self.ring.submit_and_wait(1);

        var count: usize = 0;
        while (self.ring.cq_ready() > 0 and count < completions.len) {
            const cqe = self.ring.peek_cqe() orelse break;

            completions[count] = .{
                .user_data = cqe.user_data,
                .result = cqe.res,
                .flags = cqe.flags,
            };

            self.ring.cqe_seen(cqe);
            self.pending -= 1;
            count += 1;
        }

        return count;
    }

    fn detectOptimalRingSize() u32 {
        // Heuristics based on system resources
        const mem_info = std.os.linux.sysinfo() catch return 256;
        const total_mem_gb = mem_info.totalram / (1024 * 1024 * 1024);

        return switch (total_mem_gb) {
            0...2 => 128,
            3...8 => 256,
            9...32 => 512,
            else => 1024,
        };
    }

    fn setupRegisteredBuffers(self: *IoUringBackend, allocator: Allocator, config: Config.IoConfig) !void {
        const num_buffers = config.buffer_pool_size / config.buffer_size;

        self.registered_buffers = try allocator.alignedAlloc(u8, 4096, config.buffer_pool_size);

        var iovecs: []std.posix.iovec = try allocator.alloc(std.posix.iovec, num_buffers);
        defer allocator.free(iovecs);

        for (0..num_buffers) |i| {
            const offset = i * config.buffer_size;
            iovecs[i] = .{
                .base = self.registered_buffers.?[offset..][0..config.buffer_size],
                .len = config.buffer_size,
            };
        }

        try self.ring.register_buffers(iovecs);
    }
};
```

### kqueue Backend (macOS/BSD)

```zig
// src/backend/kqueue.zig

pub const KqueueBackend = struct {
    kq: fd_t,
    pending: std.AutoHashMap(usize, PendingOp),
    change_list: std.ArrayList(Kevent),
    allocator: Allocator,

    const Kevent = std.posix.Kevent;

    const PendingOp = struct {
        op: Operation,
        state: enum { pending, ready, completed },
    };

    pub fn init(allocator: Allocator, config: Config.IoConfig) !KqueueBackend {
        const kq = try std.posix.kqueue();

        return .{
            .kq = kq,
            .pending = std.AutoHashMap(usize, PendingOp).init(allocator),
            .change_list = std.ArrayList(Kevent).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn submit(self: *KqueueBackend, op: Operation) !SubmissionId {
        // kqueue is readiness-based, not completion-based
        // We need to register interest and then perform the operation

        const kevent = switch (op.op) {
            .read => |r| Kevent{
                .ident = @intCast(r.fd),
                .filter = std.posix.system.EVFILT.READ,
                .flags = std.posix.system.EV.ADD | std.posix.system.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = op.user_data,
            },
            .write => |w| Kevent{
                .ident = @intCast(w.fd),
                .filter = std.posix.system.EVFILT.WRITE,
                .flags = std.posix.system.EV.ADD | std.posix.system.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = op.user_data,
            },
            .accept => |a| Kevent{
                .ident = @intCast(a.fd),
                .filter = std.posix.system.EVFILT.READ,
                .flags = std.posix.system.EV.ADD | std.posix.system.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = op.user_data,
            },
            // ... other operations
        };

        try self.change_list.append(kevent);
        try self.pending.put(op.user_data, .{ .op = op, .state = .pending });

        return SubmissionId{ .value = op.user_data };
    }

    pub fn wait(self: *KqueueBackend, completions: []Completion, timeout: ?Duration) !usize {
        var events: [64]Kevent = undefined;

        const ts = if (timeout) |t| &timespecFromDuration(t) else null;

        const n = try std.posix.kevent(
            self.kq,
            self.change_list.items,
            &events,
            ts,
        );

        self.change_list.clearRetainingCapacity();

        var count: usize = 0;
        for (events[0..n]) |event| {
            const pending = self.pending.get(event.udata) orelse continue;

            // Perform the actual operation now that we know it's ready
            const result = self.performOperation(pending.op);

            completions[count] = .{
                .user_data = event.udata,
                .result = result,
                .flags = 0,
            };

            _ = self.pending.remove(event.udata);
            count += 1;
        }

        return count;
    }

    fn performOperation(self: *KqueueBackend, op: Operation) i32 {
        return switch (op.op) {
            .read => |r| @intCast(std.posix.read(r.fd, r.buffer) catch |e| -@as(i32, @intFromError(e))),
            .write => |w| @intCast(std.posix.write(w.fd, w.data) catch |e| -@as(i32, @intFromError(e))),
            .accept => |a| @intCast(std.posix.accept(a.fd, a.addr, a.addr_len) catch |e| -@as(i32, @intFromError(e))),
            // ... other operations
        };
    }
};
```

### IOCP Backend (Windows)

```zig
// src/backend/iocp.zig

pub const IocpBackend = struct {
    iocp: windows.HANDLE,
    pending: std.AutoHashMap(usize, PendingOp),
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: Config.IoConfig) !IocpBackend {
        const iocp = windows.CreateIoCompletionPort(
            windows.INVALID_HANDLE_VALUE,
            null,
            0,
            0, // Use number of processors
        ) orelse return error.IocpCreationFailed;

        return .{
            .iocp = iocp,
            .pending = std.AutoHashMap(usize, PendingOp).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn submit(self: *IocpBackend, op: Operation) !SubmissionId {
        // Windows IOCP implementation
        // Associate file handle with IOCP, start overlapped operation
        // ...
    }

    pub fn wait(self: *IocpBackend, completions: []Completion, timeout: ?Duration) !usize {
        var entries: [64]windows.OVERLAPPED_ENTRY = undefined;
        var num_removed: u32 = 0;

        const timeout_ms: u32 = if (timeout) |t|
            @intCast(t.toMilliseconds())
        else
            windows.INFINITE;

        const success = windows.GetQueuedCompletionStatusEx(
            self.iocp,
            &entries,
            entries.len,
            &num_removed,
            timeout_ms,
            false,
        );

        if (!success) return error.IocpWaitFailed;

        // Convert to completions...
        return num_removed;
    }
};
```

### Backend Auto-Detection

```zig
// src/backend/detect.zig

pub fn detectBestBackend() Config.IoConfig.Backend {
    switch (builtin.os.tag) {
        .linux => {
            // Check kernel version for io_uring support
            const version = std.os.linux.uname().release;
            if (parseKernelVersion(version)) |v| {
                if (v.major > 5 or (v.major == 5 and v.minor >= 11)) {
                    return .io_uring; // Full features
                } else if (v.major == 5 and v.minor >= 1) {
                    return .io_uring; // Basic features
                }
            }
            return .epoll;
        },
        .macos, .freebsd, .openbsd, .netbsd => return .kqueue,
        .windows => return .iocp,
        else => return .poll,
    }
}

fn parseKernelVersion(release: []const u8) ?struct { major: u32, minor: u32 } {
    var parts = std.mem.splitScalar(u8, release, '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    return .{ .major = major, .minor = minor };
}
```

---

## Task Executor

### Task Representation

Tasks are stackless state machines with minimal overhead.

```zig
// src/executor/task.zig

pub const Task = struct {
    /// Function pointer to resume execution
    poll_fn: *const fn (*Task) PollResult,

    /// Waker to notify when task can make progress
    waker: Waker,

    /// Task state
    status: Status,

    /// Intrusive linked list for run queue
    next: ?*Task,

    /// Result storage (type-erased)
    result: ?*anyopaque,

    pub const Status = enum {
        pending,
        running,
        completed,
        canceled,
    };

    pub const PollResult = enum {
        pending,  // Task yielded, waiting for I/O
        ready,    // Task completed
    };
};

/// Type-erased task wrapper for a specific async function
pub fn TaskFor(comptime func: anytype) type {
    const Args = std.meta.ArgsTuple(@TypeOf(func));
    const Result = ReturnType(func);

    return struct {
        base: Task,
        args: Args,
        state: State,
        result: ?Result,

        const State = GenerateStateMachine(func);

        pub fn init(args: Args) @This() {
            return .{
                .base = .{
                    .poll_fn = poll,
                    .waker = undefined,
                    .status = .pending,
                    .next = null,
                    .result = null,
                },
                .args = args,
                .state = .initial,
                .result = null,
            };
        }

        fn poll(base: *Task) Task.PollResult {
            const self: *@This() = @fieldParentPtr("base", base);

            // Resume state machine
            return self.state.resume(&self.args, &self.result);
        }
    };
}
```

### State Machine Generation

For Zig 0.15, we manually structure state machines. With 0.16's async/await, this becomes automatic.

```zig
// src/executor/state_machine.zig

/// Example of how an async function becomes a state machine
///
/// Original:
/// ```
/// fn fetchData(io: Io, url: []const u8) !Data {
///     var conn = try io.net.tcpConnect(parseHost(url));
///     defer conn.close(io);
///
///     try conn.writeAll(io, buildRequest(url));
///     const response = try conn.readAll(io);
///
///     return parse(response);
/// }
/// ```
///
/// Becomes:
pub const FetchDataState = struct {
    phase: Phase,
    conn: ?TcpStream,
    response: ?[]u8,

    const Phase = enum {
        initial,
        connecting,
        writing,
        reading,
        done,
    };

    pub fn resume(self: *@This(), args: anytype, result: *?Data) Task.PollResult {
        const io = args[0];
        const url = args[1];

        switch (self.phase) {
            .initial => {
                // Start connection
                const connect_future = io.net.tcpConnectAsync(parseHost(url));
                self.phase = .connecting;
                return .pending;
            },
            .connecting => {
                // Check if connected
                if (self.pending_connect.poll()) |conn| {
                    self.conn = conn;
                    // Start write
                    conn.writeAllAsync(io, buildRequest(url));
                    self.phase = .writing;
                }
                return .pending;
            },
            .writing => {
                // Check if write complete
                if (self.pending_write.poll()) |_| {
                    // Start read
                    self.conn.?.readAllAsync(io);
                    self.phase = .reading;
                }
                return .pending;
            },
            .reading => {
                if (self.pending_read.poll()) |response| {
                    result.* = parse(response);
                    self.phase = .done;
                    return .ready;
                }
                return .pending;
            },
            .done => return .ready,
        }
    }
};
```

### Scheduler

```zig
// src/executor/scheduler.zig

pub const Scheduler = struct {
    /// Global run queue (work-stealing mode)
    global_queue: GlobalQueue,

    /// Per-worker local queues
    local_queues: []LocalQueue,

    /// Workers
    workers: []Worker,

    /// Configuration
    config: Config,

    /// Shutdown signal
    shutdown: std.atomic.Value(bool),

    pub fn init(allocator: Allocator, config: Config) !Scheduler {
        const num_workers = config.threads.count orelse detectCpuCount();

        var workers = try allocator.alloc(Worker, num_workers);
        var local_queues = try allocator.alloc(LocalQueue, num_workers);

        for (0..num_workers) |i| {
            local_queues[i] = LocalQueue.init(allocator);
            workers[i] = Worker.init(i, &local_queues[i], config);
        }

        return .{
            .global_queue = GlobalQueue.init(allocator),
            .local_queues = local_queues,
            .workers = workers,
            .config = config,
            .shutdown = std.atomic.Value(bool).init(false),
        };
    }

    pub fn spawn(self: *Scheduler, task: *Task) void {
        switch (self.config.strategy) {
            .thread_per_core => {
                // Task stays on current worker
                const worker_id = getCurrentWorkerId();
                self.local_queues[worker_id].push(task);
            },
            .work_stealing => {
                // Add to global queue for load balancing
                self.global_queue.push(task);
            },
            .single_threaded => {
                self.local_queues[0].push(task);
            },
        }

        // Wake a worker
        self.notifyWorker();
    }

    pub fn runWorker(self: *Scheduler, worker_id: usize) void {
        const local = &self.local_queues[worker_id];
        const worker = &self.workers[worker_id];

        while (!self.shutdown.load(.acquire)) {
            // Try local queue first
            if (local.pop()) |task| {
                self.executeTask(task);
                continue;
            }

            // Try global queue
            if (self.global_queue.pop()) |task| {
                self.executeTask(task);
                continue;
            }

            // Try stealing from other workers
            if (self.config.strategy == .work_stealing) {
                if (self.trySteal(worker_id)) |task| {
                    self.executeTask(task);
                    continue;
                }
            }

            // No work, park worker
            worker.park();
        }
    }

    fn trySteal(self: *Scheduler, worker_id: usize) ?*Task {
        const num_workers = self.workers.len;
        const start = (worker_id + 1) % num_workers;

        for (0..num_workers - 1) |i| {
            const target = (start + i) % num_workers;
            if (self.local_queues[target].steal()) |task| {
                return task;
            }
        }

        return null;
    }

    fn executeTask(self: *Scheduler, task: *Task) void {
        task.status = .running;

        const result = task.poll_fn(task);

        switch (result) {
            .pending => {
                // Task yielded, will be re-scheduled when I/O completes
                task.status = .pending;
            },
            .ready => {
                // Task completed
                task.status = .completed;
                task.waker.wake();
            },
        }
    }
};
```

### Worker Thread

```zig
// src/executor/worker.zig

pub const Worker = struct {
    id: usize,
    thread: ?std.Thread,
    local_queue: *LocalQueue,
    driver: *Driver,

    /// Parking mechanism
    parked: std.atomic.Value(bool),
    futex: std.atomic.Value(u32),

    pub fn init(id: usize, local_queue: *LocalQueue, config: Config) Worker {
        return .{
            .id = id,
            .thread = null,
            .local_queue = local_queue,
            .driver = undefined,
            .parked = std.atomic.Value(bool).init(false),
            .futex = std.atomic.Value(u32).init(0),
        };
    }

    pub fn start(self: *Worker, scheduler: *Scheduler) !void {
        self.thread = try std.Thread.spawn(.{}, workerMain, .{ self, scheduler });

        // Set thread affinity if configured
        if (scheduler.config.threads.affinity != .none) {
            try self.setAffinity(scheduler.config.threads.affinity);
        }
    }

    fn workerMain(self: *Worker, scheduler: *Scheduler) void {
        // Thread-local state
        current_worker_id = self.id;

        scheduler.runWorker(self.id);
    }

    pub fn park(self: *Worker) void {
        self.parked.store(true, .release);

        // Wait on futex
        std.Thread.Futex.wait(&self.futex, 0, null) catch {};

        self.parked.store(false, .release);
    }

    pub fn unpark(self: *Worker) void {
        if (self.parked.load(.acquire)) {
            self.futex.store(1, .release);
            std.Thread.Futex.wake(&self.futex, 1);
        }
    }

    fn setAffinity(self: *Worker, affinity: Config.ThreadConfig.Affinity) !void {
        switch (affinity) {
            .auto => {
                // Detect NUMA topology and pin to local core
                const core = detectLocalCore(self.id);
                try std.os.setCurrentThreadAffinity(core);
            },
            .sequential => {
                try std.os.setCurrentThreadAffinity(self.id);
            },
            .none => {},
        }
    }
};

threadlocal var current_worker_id: usize = 0;

pub fn getCurrentWorkerId() usize {
    return current_worker_id;
}
```

### Local Queue (Lock-free SPSC)

```zig
// src/executor/local_queue.zig

/// Single-producer, multi-consumer queue for local tasks
/// Producer: owning worker
/// Consumer: owning worker (pop) + other workers (steal)
pub const LocalQueue = struct {
    buffer: []std.atomic.Value(*Task),
    head: std.atomic.Value(u32),  // Consumer reads from here
    tail: std.atomic.Value(u32),  // Producer writes here

    const CAPACITY = 256;

    pub fn init(allocator: Allocator) LocalQueue {
        const buffer = allocator.alloc(std.atomic.Value(*Task), CAPACITY) catch unreachable;
        return .{
            .buffer = buffer,
            .head = std.atomic.Value(u32).init(0),
            .tail = std.atomic.Value(u32).init(0),
        };
    }

    /// Push a task (only called by owning worker)
    pub fn push(self: *LocalQueue, task: *Task) void {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);

        if (tail -% head >= CAPACITY) {
            // Queue full, push to global queue
            @panic("Local queue overflow - should push to global");
        }

        self.buffer[tail % CAPACITY].store(task, .relaxed);
        self.tail.store(tail +% 1, .release);
    }

    /// Pop a task (only called by owning worker)
    pub fn pop(self: *LocalQueue) ?*Task {
        const tail = self.tail.load(.monotonic);

        if (tail == 0) return null;

        const new_tail = tail -% 1;
        self.tail.store(new_tail, .monotonic);

        std.atomic.fence(.seq_cst);

        const head = self.head.load(.monotonic);

        if (head <= new_tail) {
            // Safe to take
            return self.buffer[new_tail % CAPACITY].load(.relaxed);
        }

        // Race with stealer
        if (head == tail) {
            // Queue is empty
            self.tail.store(tail, .monotonic);
            return null;
        }

        // Lost race, restore tail
        self.tail.store(tail, .monotonic);
        return null;
    }

    /// Steal half the tasks (called by other workers)
    pub fn steal(self: *LocalQueue) ?*Task {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);

        if (head >= tail) return null;

        const task = self.buffer[head % CAPACITY].load(.relaxed);

        if (self.head.cmpxchgWeak(head, head +% 1, .seq_cst, .monotonic)) |_| {
            // CAS failed, retry
            return null;
        }

        return task;
    }
};
```

---

## Async Primitives

### Channel

```zig
// src/sync/channel.zig

/// Multi-producer, multi-consumer async channel
pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: RingBuffer(T),
        mutex: std.Thread.Mutex,

        /// Waiters for recv
        recv_waiters: WaiterList,

        /// Waiters for send (bounded channels)
        send_waiters: WaiterList,

        closed: std.atomic.Value(bool),

        pub fn init(allocator: Allocator, capacity: usize) !Self {
            return .{
                .buffer = try RingBuffer(T).init(allocator, capacity),
                .mutex = .{},
                .recv_waiters = WaiterList.init(),
                .send_waiters = WaiterList.init(),
                .closed = std.atomic.Value(bool).init(false),
            };
        }

        /// Send a value (async)
        pub fn send(self: *Self, io: Io, value: T) !void {
            while (true) {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.closed.load(.acquire)) {
                    return error.ChannelClosed;
                }

                if (self.buffer.push(value)) {
                    // Wake a receiver
                    if (self.recv_waiters.pop()) |waiter| {
                        waiter.wake();
                    }
                    return;
                }

                // Buffer full, wait
                var waiter = Waiter.init();
                self.send_waiters.push(&waiter);

                self.mutex.unlock();
                waiter.wait(io);
                self.mutex.lock();
            }
        }

        /// Receive a value (async)
        pub fn recv(self: *Self, io: Io) !?T {
            while (true) {
                self.mutex.lock();

                if (self.buffer.pop()) |value| {
                    // Wake a sender
                    if (self.send_waiters.pop()) |waiter| {
                        waiter.wake();
                    }
                    self.mutex.unlock();
                    return value;
                }

                if (self.closed.load(.acquire)) {
                    self.mutex.unlock();
                    return null;
                }

                // Buffer empty, wait
                var waiter = Waiter.init();
                self.recv_waiters.push(&waiter);

                self.mutex.unlock();
                waiter.wait(io);
            }
        }

        /// Try to receive without blocking
        pub fn tryRecv(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.buffer.pop();
        }

        /// Close the channel
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.closed.store(true, .release);

            // Wake all waiters
            while (self.recv_waiters.pop()) |waiter| {
                waiter.wake();
            }
            while (self.send_waiters.pop()) |waiter| {
                waiter.wake();
            }
        }
    };
}

/// Oneshot channel - send exactly one value
pub fn Oneshot(comptime T: type) type {
    return struct {
        value: ?T,
        completed: std.atomic.Value(bool),
        waiter: ?*Waiter,

        pub fn init() @This() {
            return .{
                .value = null,
                .completed = std.atomic.Value(bool).init(false),
                .waiter = null,
            };
        }

        pub fn send(self: *@This(), value: T) void {
            self.value = value;
            self.completed.store(true, .release);

            if (self.waiter) |w| {
                w.wake();
            }
        }

        pub fn recv(self: *@This(), io: Io) T {
            if (self.completed.load(.acquire)) {
                return self.value.?;
            }

            var waiter = Waiter.init();
            self.waiter = &waiter;

            waiter.wait(io);

            return self.value.?;
        }
    };
}
```

### Async Mutex

```zig
// src/sync/mutex.zig

/// Async-aware mutex that yields instead of spinning
pub const Mutex = struct {
    state: std.atomic.Value(u32),
    waiters: WaiterList,

    const UNLOCKED = 0;
    const LOCKED = 1;

    pub fn init() Mutex {
        return .{
            .state = std.atomic.Value(u32).init(UNLOCKED),
            .waiters = WaiterList.init(),
        };
    }

    pub fn lock(self: *Mutex, io: Io) void {
        // Fast path: try to acquire immediately
        if (self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) == null) {
            return;
        }

        // Slow path: add to wait queue
        self.lockSlow(io);
    }

    fn lockSlow(self: *Mutex, io: Io) void {
        var waiter = Waiter.init();

        while (true) {
            // Try to acquire
            if (self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) == null) {
                return;
            }

            // Add to wait queue and yield
            self.waiters.push(&waiter);
            waiter.wait(io);
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.state.store(UNLOCKED, .release);

        // Wake one waiter
        if (self.waiters.pop()) |waiter| {
            waiter.wake();
        }
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) == null;
    }
};

/// RAII guard for Mutex
pub fn MutexGuard(comptime T: type) type {
    return struct {
        mutex: *Mutex,
        value: *T,

        pub fn release(self: @This()) void {
            self.mutex.unlock();
        }
    };
}
```

### Semaphore

```zig
// src/sync/semaphore.zig

pub const Semaphore = struct {
    permits: std.atomic.Value(u32),
    waiters: WaiterList,

    pub fn init(initial_permits: u32) Semaphore {
        return .{
            .permits = std.atomic.Value(u32).init(initial_permits),
            .waiters = WaiterList.init(),
        };
    }

    pub fn acquire(self: *Semaphore, io: Io) void {
        while (true) {
            const current = self.permits.load(.monotonic);

            if (current > 0) {
                if (self.permits.cmpxchgWeak(current, current - 1, .acquire, .monotonic) == null) {
                    return;
                }
                continue;
            }

            // No permits, wait
            var waiter = Waiter.init();
            self.waiters.push(&waiter);
            waiter.wait(io);
        }
    }

    pub fn release(self: *Semaphore) void {
        _ = self.permits.fetchAdd(1, .release);

        if (self.waiters.pop()) |waiter| {
            waiter.wake();
        }
    }

    pub fn tryAcquire(self: *Semaphore) bool {
        const current = self.permits.load(.monotonic);
        if (current == 0) return false;
        return self.permits.cmpxchgWeak(current, current - 1, .acquire, .monotonic) == null;
    }
};
```

### Waiter Infrastructure

```zig
// src/sync/waiter.zig

pub const Waiter = struct {
    task: ?*Task,
    next: ?*Waiter,
    woken: std.atomic.Value(bool),

    pub fn init() Waiter {
        return .{
            .task = null,
            .next = null,
            .woken = std.atomic.Value(bool).init(false),
        };
    }

    /// Yield the current task until woken
    pub fn wait(self: *Waiter, io: Io) void {
        self.task = getCurrentTask();

        while (!self.woken.load(.acquire)) {
            // Yield to scheduler
            io.runtime.executor.yieldTask(self.task.?);
        }
    }

    /// Wake the waiting task
    pub fn wake(self: *Waiter) void {
        self.woken.store(true, .release);

        if (self.task) |task| {
            // Re-schedule the task
            task.waker.wake();
        }
    }
};

pub const WaiterList = struct {
    head: ?*Waiter,
    tail: ?*Waiter,
    mutex: std.Thread.Mutex,

    pub fn init() WaiterList {
        return .{
            .head = null,
            .tail = null,
            .mutex = .{},
        };
    }

    pub fn push(self: *WaiterList, waiter: *Waiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        waiter.next = null;

        if (self.tail) |t| {
            t.next = waiter;
            self.tail = waiter;
        } else {
            self.head = waiter;
            self.tail = waiter;
        }
    }

    pub fn pop(self: *WaiterList) ?*Waiter {
        self.mutex.lock();
        defer self.mutex.unlock();

        const waiter = self.head orelse return null;
        self.head = waiter.next;

        if (self.head == null) {
            self.tail = null;
        }

        return waiter;
    }
};
```

---

## Network I/O

### TCP

```zig
// src/net/tcp.zig

pub const TcpStream = struct {
    fd: fd_t,
    io: *Io,

    /// Connect to a remote address
    pub fn connect(io: Io, address: Address) !TcpStream {
        const fd = try std.posix.socket(
            address.family(),
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
            0,
        );
        errdefer std.posix.close(fd);

        // Submit connect operation
        const op = Operation{
            .op = .{ .connect = .{
                .fd = fd,
                .addr = &address.sockaddr,
                .addr_len = address.len,
            }},
            .user_data = @intFromPtr(&current_task),
        };

        _ = try io.runtime.driver.submit(op);

        // Yield until connected
        io.runtime.executor.yieldCurrentTask();

        return .{ .fd = fd, .io = io.runtime.io };
    }

    /// Read data
    pub fn read(self: TcpStream, buffer: []u8) !usize {
        const op = Operation{
            .op = .{ .recv = .{
                .fd = self.fd,
                .buffer = buffer,
                .flags = 0,
            }},
            .user_data = @intFromPtr(getCurrentTask()),
        };

        _ = try self.io.runtime.driver.submit(op);
        self.io.runtime.executor.yieldCurrentTask();

        // Result is available after wake
        return getCurrentTask().io_result;
    }

    /// Write data
    pub fn write(self: TcpStream, data: []const u8) !usize {
        const op = Operation{
            .op = .{ .send = .{
                .fd = self.fd,
                .data = data,
                .flags = 0,
            }},
            .user_data = @intFromPtr(getCurrentTask()),
        };

        _ = try self.io.runtime.driver.submit(op);
        self.io.runtime.executor.yieldCurrentTask();

        return getCurrentTask().io_result;
    }

    /// Write all data
    pub fn writeAll(self: TcpStream, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            written += try self.write(data[written..]);
        }
    }

    /// Read until delimiter
    pub fn readUntilDelimiter(self: TcpStream, allocator: Allocator, delimiter: []const u8) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        var temp: [4096]u8 = undefined;

        while (true) {
            const n = try self.read(&temp);
            if (n == 0) break;

            try buffer.appendSlice(temp[0..n]);

            if (std.mem.indexOf(u8, buffer.items, delimiter)) |_| {
                break;
            }
        }

        return buffer.toOwnedSlice();
    }

    /// Close the connection
    pub fn close(self: TcpStream) void {
        std.posix.close(self.fd);
    }

    /// Get peer address
    pub fn getPeerAddress(self: TcpStream) !Address {
        var addr: std.posix.sockaddr = undefined;
        var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        try std.posix.getpeername(self.fd, &addr, &len);
        return Address.fromSockaddr(&addr, len);
    }

    /// Set TCP options
    pub fn setNoDelay(self: TcpStream, enabled: bool) !void {
        try std.posix.setsockopt(
            self.fd,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            &std.mem.toBytes(@as(c_int, if (enabled) 1 else 0)),
        );
    }
};

pub const TcpListener = struct {
    fd: fd_t,
    io: *Io,

    pub const ListenOptions = struct {
        address: ?Address = null,
        port: u16 = 0,
        backlog: u31 = 128,
        reuse_address: bool = true,
        reuse_port: bool = false,
    };

    pub fn bind(io: Io, options: ListenOptions) !TcpListener {
        const address = options.address orelse Address.initIpv4(.{ 0, 0, 0, 0 }, options.port);

        const fd = try std.posix.socket(
            address.family(),
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
            0,
        );
        errdefer std.posix.close(fd);

        if (options.reuse_address) {
            try std.posix.setsockopt(
                fd,
                std.posix.SOL.SOCKET,
                std.posix.SO.REUSEADDR,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        }

        if (options.reuse_port) {
            try std.posix.setsockopt(
                fd,
                std.posix.SOL.SOCKET,
                std.posix.SO.REUSEPORT,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        }

        try std.posix.bind(fd, &address.sockaddr, address.len);
        try std.posix.listen(fd, options.backlog);

        return .{ .fd = fd, .io = io.runtime.io };
    }

    /// Accept a connection
    pub fn accept(self: TcpListener) !TcpStream {
        var client_addr: std.posix.sockaddr = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const op = Operation{
            .op = .{ .accept = .{
                .fd = self.fd,
                .addr = &client_addr,
                .addr_len = &addr_len,
            }},
            .user_data = @intFromPtr(getCurrentTask()),
        };

        _ = try self.io.runtime.driver.submit(op);
        self.io.runtime.executor.yieldCurrentTask();

        const client_fd = getCurrentTask().io_result;
        return .{ .fd = @intCast(client_fd), .io = self.io };
    }

    /// Close the listener
    pub fn close(self: TcpListener) void {
        std.posix.close(self.fd);
    }

    /// Get local address
    pub fn getLocalAddress(self: TcpListener) !Address {
        var addr: std.posix.sockaddr = undefined;
        var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        try std.posix.getsockname(self.fd, &addr, &len);
        return Address.fromSockaddr(&addr, len);
    }
};
```

### UDP

```zig
// src/net/udp.zig

pub const UdpSocket = struct {
    fd: fd_t,
    io: *Io,

    pub fn bind(io: Io, address: Address) !UdpSocket {
        const fd = try std.posix.socket(
            address.family(),
            std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK,
            0,
        );
        errdefer std.posix.close(fd);

        try std.posix.bind(fd, &address.sockaddr, address.len);

        return .{ .fd = fd, .io = io.runtime.io };
    }

    pub fn sendTo(self: UdpSocket, data: []const u8, address: Address) !usize {
        // Submit sendto operation
        // ...
    }

    pub fn recvFrom(self: UdpSocket, buffer: []u8) !struct { usize, Address } {
        // Submit recvfrom operation
        // ...
    }

    pub fn close(self: UdpSocket) void {
        std.posix.close(self.fd);
    }
};
```

### Address

```zig
// src/net/address.zig

pub const Address = struct {
    storage: std.posix.sockaddr.storage,
    len: std.posix.socklen_t,

    pub fn initIpv4(addr: [4]u8, port: u16) Address {
        var result: Address = undefined;
        const sockaddr: *std.posix.sockaddr.in = @ptrCast(&result.storage);
        sockaddr.* = .{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(addr),
            .zero = [_]u8{0} ** 8,
        };
        result.len = @sizeOf(std.posix.sockaddr.in);
        return result;
    }

    pub fn initIpv6(addr: [16]u8, port: u16) Address {
        var result: Address = undefined;
        const sockaddr: *std.posix.sockaddr.in6 = @ptrCast(&result.storage);
        sockaddr.* = .{
            .family = std.posix.AF.INET6,
            .port = std.mem.nativeToBig(u16, port),
            .flowinfo = 0,
            .addr = addr,
            .scope_id = 0,
        };
        result.len = @sizeOf(std.posix.sockaddr.in6);
        return result;
    }

    pub fn parse(string: []const u8) !Address {
        // Parse "host:port" or "[ipv6]:port"
        // ...
    }

    pub fn family(self: Address) std.posix.sa_family_t {
        return @as(*const std.posix.sockaddr, @ptrCast(&self.storage)).family;
    }

    pub fn port(self: Address) u16 {
        return switch (self.family()) {
            std.posix.AF.INET => blk: {
                const sockaddr: *const std.posix.sockaddr.in = @ptrCast(&self.storage);
                break :blk std.mem.bigToNative(u16, sockaddr.port);
            },
            std.posix.AF.INET6 => blk: {
                const sockaddr: *const std.posix.sockaddr.in6 = @ptrCast(&self.storage);
                break :blk std.mem.bigToNative(u16, sockaddr.port);
            },
            else => unreachable,
        };
    }

    pub fn format(self: Address, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        // Format as "192.168.1.1:8080" or "[::1]:8080"
        // ...
    }
};
```

---

## File I/O

```zig
// src/fs/file.zig

pub const File = struct {
    fd: fd_t,
    io: *Io,

    pub const OpenFlags = struct {
        read: bool = true,
        write: bool = false,
        create: bool = false,
        truncate: bool = false,
        append: bool = false,
        mode: u32 = 0o644,
    };

    pub fn open(io: Io, path: []const u8, flags: OpenFlags) !File {
        var posix_flags: u32 = 0;

        if (flags.read and flags.write) {
            posix_flags |= std.posix.O.RDWR;
        } else if (flags.write) {
            posix_flags |= std.posix.O.WRONLY;
        } else {
            posix_flags |= std.posix.O.RDONLY;
        }

        if (flags.create) posix_flags |= std.posix.O.CREAT;
        if (flags.truncate) posix_flags |= std.posix.O.TRUNC;
        if (flags.append) posix_flags |= std.posix.O.APPEND;

        // For io_uring, we can use IORING_OP_OPENAT
        const op = Operation{
            .op = .{ .open = .{
                .path = path.ptr,
                .flags = posix_flags,
                .mode = flags.mode,
            }},
            .user_data = @intFromPtr(getCurrentTask()),
        };

        _ = try io.runtime.driver.submit(op);
        io.runtime.executor.yieldCurrentTask();

        const fd = getCurrentTask().io_result;
        return .{ .fd = @intCast(fd), .io = io.runtime.io };
    }

    pub fn read(self: File, buffer: []u8) !usize {
        const op = Operation{
            .op = .{ .read = .{
                .fd = self.fd,
                .buffer = buffer,
                .offset = null,
            }},
            .user_data = @intFromPtr(getCurrentTask()),
        };

        _ = try self.io.runtime.driver.submit(op);
        self.io.runtime.executor.yieldCurrentTask();

        const result = getCurrentTask().io_result;
        if (result < 0) return error.ReadFailed;
        return @intCast(result);
    }

    pub fn readAll(self: File, allocator: Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        var temp: [8192]u8 = undefined;

        while (true) {
            const n = try self.read(&temp);
            if (n == 0) break;
            try buffer.appendSlice(temp[0..n]);
        }

        return buffer.toOwnedSlice();
    }

    pub fn write(self: File, data: []const u8) !usize {
        const op = Operation{
            .op = .{ .write = .{
                .fd = self.fd,
                .data = data,
                .offset = null,
            }},
            .user_data = @intFromPtr(getCurrentTask()),
        };

        _ = try self.io.runtime.driver.submit(op);
        self.io.runtime.executor.yieldCurrentTask();

        const result = getCurrentTask().io_result;
        if (result < 0) return error.WriteFailed;
        return @intCast(result);
    }

    pub fn writeAll(self: File, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            written += try self.write(data[written..]);
        }
    }

    pub fn close(self: File) void {
        std.posix.close(self.fd);
    }

    pub fn sync(self: File) !void {
        const op = Operation{
            .op = .{ .fsync = .{ .fd = self.fd } },
            .user_data = @intFromPtr(getCurrentTask()),
        };

        _ = try self.io.runtime.driver.submit(op);
        self.io.runtime.executor.yieldCurrentTask();
    }
};

/// Convenience functions
pub fn readFile(io: Io, path: []const u8, allocator: Allocator) ![]u8 {
    var file = try File.open(io, path, .{});
    defer file.close();
    return file.readAll(allocator);
}

pub fn writeFile(io: Io, path: []const u8, data: []const u8) !void {
    var file = try File.open(io, path, .{ .write = true, .create = true, .truncate = true });
    defer file.close();
    try file.writeAll(data);
}
```

---

## Timers & Scheduling

### Timer Wheel

```zig
// src/timer/wheel.zig

pub const TimerWheel = struct {
    /// Hierarchical timing wheels
    wheels: [4]Wheel,

    /// Current tick
    current_tick: u64,

    /// Tick duration in nanoseconds
    tick_ns: u64,

    /// Pending timers
    pending: std.ArrayList(Timer),

    allocator: Allocator,

    const Wheel = struct {
        slots: []TimerList,
        current: usize,
    };

    pub fn init(allocator: Allocator, config: Config.TimerConfig) !TimerWheel {
        const tick_ns = @as(u64, config.tick_duration_ms) * 1_000_000;

        var wheels: [4]Wheel = undefined;
        const sizes = [_]usize{ 256, 64, 64, 64 }; // ~4 billion ticks range

        for (&wheels, sizes) |*wheel, size| {
            wheel.slots = try allocator.alloc(TimerList, size);
            for (wheel.slots) |*slot| {
                slot.* = TimerList.init();
            }
            wheel.current = 0;
        }

        return .{
            .wheels = wheels,
            .current_tick = 0,
            .tick_ns = tick_ns,
            .pending = std.ArrayList(Timer).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn schedule(self: *TimerWheel, deadline: u64, callback: *Task) void {
        const ticks = (deadline - self.now()) / self.tick_ns;

        if (ticks < 256) {
            // First wheel
            const slot = (self.wheels[0].current + ticks) % 256;
            self.wheels[0].slots[slot].push(callback);
        } else if (ticks < 256 * 64) {
            // Second wheel
            const slot = (self.wheels[1].current + ticks / 256) % 64;
            self.wheels[1].slots[slot].push(callback);
        }
        // ... higher wheels for longer durations
    }

    pub fn advance(self: *TimerWheel) []const *Task {
        self.current_tick += 1;

        var expired = std.ArrayList(*Task).init(self.allocator);

        // Check first wheel
        self.wheels[0].current = (self.wheels[0].current + 1) % 256;

        while (self.wheels[0].slots[self.wheels[0].current].pop()) |timer| {
            expired.append(timer) catch {};
        }

        // Cascade from higher wheels
        if (self.wheels[0].current == 0) {
            self.cascade(1);
        }

        return expired.items;
    }

    fn cascade(self: *TimerWheel, level: usize) void {
        if (level >= self.wheels.len) return;

        self.wheels[level].current = (self.wheels[level].current + 1) % self.wheels[level].slots.len;

        // Move timers to lower wheel
        while (self.wheels[level].slots[self.wheels[level].current].pop()) |timer| {
            // Recalculate slot in lower wheel
            self.schedule(timer.deadline, timer.callback);
        }

        if (self.wheels[level].current == 0) {
            self.cascade(level + 1);
        }
    }

    fn now(self: *TimerWheel) u64 {
        return self.current_tick * self.tick_ns;
    }
};
```

### Sleep and Timeout

```zig
// src/timer/sleep.zig

pub fn sleep(io: Io, duration: Duration) void {
    const deadline = io.now().add(duration);

    const task = getCurrentTask();
    io.runtime.timers.schedule(deadline.ns, task);

    io.runtime.executor.yieldCurrentTask();
}

pub const Deadline = struct {
    deadline: Instant,
    io: *Io,

    pub fn expired(self: Deadline) bool {
        return self.io.now().ns >= self.deadline.ns;
    }

    pub fn remaining(self: Deadline) ?Duration {
        const now = self.io.now();
        if (now.ns >= self.deadline.ns) return null;
        return Duration{ .ns = self.deadline.ns - now.ns };
    }
};

pub fn timeout(io: Io, duration: Duration, comptime func: anytype, args: anytype) !ReturnType(func) {
    const deadline = io.now().add(duration);

    var task_future = io.@"async"(func, args);
    var timeout_future = io.@"async"(sleepUntil, .{ io, deadline });

    // Race between task and timeout
    // First one to complete wins

    // ... implementation using select/race primitive
}
```

---

## Blitz Integration

### Bridge Module

```zig
// src/bridge/blitz.zig

const blitz = @import("blitz");

/// Execute a CPU-bound function on Blitz's thread pool
/// Returns result via async channel
pub fn computeOnBlitz(
    io: Io,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) !ReturnType(func) {
    const Result = ReturnType(func);

    // Create oneshot channel for result
    var channel = Oneshot(Result).init();

    // Spawn work on Blitz
    blitz.spawn(struct {
        fn work(a: @TypeOf(args), ch: *Oneshot(Result)) void {
            const result = @call(.auto, func, a);
            ch.send(result);
        }
    }.work, .{ args, &channel });

    // Yield until result is ready
    return channel.recv(io);
}

/// Parallel map using Blitz, results returned asynchronously
pub fn parallelMap(
    io: Io,
    comptime T: type,
    comptime R: type,
    items: []const T,
    comptime func: fn (T) R,
) ![]R {
    var channel = Channel(struct { index: usize, result: R }).init(io.runtime.allocator, items.len);
    defer channel.deinit();

    // Spawn parallel work on Blitz
    blitz.parallelFor(0, items.len, struct {
        fn work(i: usize, ctx: anytype) void {
            const result = func(ctx.items[i]);
            ctx.channel.trySend(.{ .index = i, .result = result });
        }
    }.work, .{ .items = items, .channel = &channel });

    // Collect results
    var results = try io.runtime.allocator.alloc(R, items.len);
    for (0..items.len) |_| {
        const item = (try channel.recv(io)).?;
        results[item.index] = item.result;
    }

    return results;
}

/// Execute blocking I/O on a dedicated thread pool
/// (for operations that don't support async, like some DNS lookups)
pub fn spawnBlocking(
    io: Io,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) !ReturnType(func) {
    // Similar to computeOnBlitz but uses a dedicated blocking thread pool
    // to avoid starving Blitz's compute pool
    return computeOnBlitz(io, func, args);
}
```

### Usage Example

```zig
const std = @import("std");
const blitz = @import("blitz");
const io = @import("blitz-io");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize I/O runtime
    var runtime = try io.Runtime.init(allocator, .{});
    defer runtime.deinit();

    // Run async main
    try runtime.block_on(asyncMain, .{ runtime.io, allocator });
}

fn asyncMain(ctx: io.Io, allocator: Allocator) !void {
    // Fetch data from multiple URLs concurrently
    const urls = [_][]const u8{
        "https://api.example.com/data1",
        "https://api.example.com/data2",
        "https://api.example.com/data3",
    };

    var futures: [urls.len]io.Future([]u8) = undefined;

    for (urls, 0..) |url, i| {
        futures[i] = ctx.@"async"(fetchUrl, .{ ctx, url, allocator });
    }

    // Process each response as it arrives
    for (&futures) |*future| {
        const data = try future.await(ctx);
        defer allocator.free(data);

        // CPU-heavy processing → offload to Blitz
        const processed = try io.computeOnBlitz(ctx, processData, .{data});

        // Write result
        try ctx.fs.writeFile("output.txt", processed);
    }
}

fn fetchUrl(ctx: io.Io, url: []const u8, allocator: Allocator) ![]u8 {
    var conn = try ctx.net.tcpConnect(try io.net.Address.parse(url));
    defer conn.close();

    try conn.writeAll(ctx, buildHttpRequest(url));
    return conn.readAll(ctx, allocator);
}

fn processData(data: []const u8) []u8 {
    // CPU-intensive processing
    // This runs on Blitz's thread pool
    return heavyComputation(data);
}
```

---

## API Reference

### Public API Surface

```zig
// Root module: src/lib.zig

pub const Runtime = @import("runtime.zig").Runtime;
pub const Config = @import("config.zig").Config;
pub const Io = @import("io.zig").Io;
pub const Future = @import("future.zig").Future;

// Time
pub const Duration = @import("time.zig").Duration;
pub const Instant = @import("time.zig").Instant;
pub const sleep = @import("timer/sleep.zig").sleep;
pub const timeout = @import("timer/sleep.zig").timeout;

// Network
pub const net = struct {
    pub const TcpStream = @import("net/tcp.zig").TcpStream;
    pub const TcpListener = @import("net/tcp.zig").TcpListener;
    pub const UdpSocket = @import("net/udp.zig").UdpSocket;
    pub const Address = @import("net/address.zig").Address;
};

// Filesystem
pub const fs = struct {
    pub const File = @import("fs/file.zig").File;
    pub const readFile = @import("fs/file.zig").readFile;
    pub const writeFile = @import("fs/file.zig").writeFile;
};

// Synchronization
pub const sync = struct {
    pub const Channel = @import("sync/channel.zig").Channel;
    pub const Oneshot = @import("sync/channel.zig").Oneshot;
    pub const Mutex = @import("sync/mutex.zig").Mutex;
    pub const Semaphore = @import("sync/semaphore.zig").Semaphore;
};

// Blitz integration
pub const computeOnBlitz = @import("bridge/blitz.zig").computeOnBlitz;
pub const parallelMap = @import("bridge/blitz.zig").parallelMap;
pub const spawnBlocking = @import("bridge/blitz.zig").spawnBlocking;
```

---

## Implementation Roadmap

### Phase 1: Foundation (Weeks 1-4)

```
□ Project setup
  □ Repository structure
  □ Build system (build.zig)
  □ CI/CD pipeline
  □ Basic documentation

□ Core runtime
  □ Runtime struct and lifecycle
  □ Configuration system
  □ Basic executor (single-threaded)

□ io_uring backend (Linux)
  □ Basic operations (read, write, open, close)
  □ Network operations (accept, connect, recv, send)
  □ Completion handling
  □ Basic tests
```

### Phase 2: Multi-threading (Weeks 5-8)

```
□ Thread pool
  □ Worker threads
  □ Local queues (lock-free)
  □ Work stealing
  □ Thread parking/waking

□ Task system
  □ Task representation
  □ Waker mechanism
  □ Future implementation

□ Timer wheel
  □ Hierarchical wheels
  □ sleep() implementation
  □ timeout() implementation
```

### Phase 3: Cross-platform (Weeks 9-12)

```
□ kqueue backend (macOS)
  □ Event registration
  □ Completion simulation
  □ Tests on macOS

□ epoll backend (Linux fallback)
  □ Readiness-based operations
  □ Edge-triggered mode

□ IOCP backend (Windows)
  □ Completion port setup
  □ Overlapped operations
```

### Phase 4: Networking & Files (Weeks 13-16)

```
□ TCP implementation
  □ TcpStream
  □ TcpListener
  □ Connection pooling

□ UDP implementation
  □ UdpSocket

□ File I/O
  □ Async file operations
  □ Directory operations

□ DNS resolution
  □ Async resolver
```

### Phase 5: Synchronization (Weeks 17-20)

```
□ Channel
  □ MPMC bounded channel
  □ Oneshot channel

□ Mutex
  □ Async mutex
  □ RwLock

□ Semaphore
□ Barrier
□ Notify (condition variable)
```

### Phase 6: Blitz Integration (Weeks 21-24)

```
□ Bridge module
  □ computeOnBlitz
  □ spawnBlocking
  □ parallelMap

□ Integration tests
  □ Mixed I/O and compute workloads
  □ Stress tests
```

### Phase 7: Polish & Performance (Weeks 25-28)

```
□ Performance optimization
  □ Profiling and benchmarks
  □ Buffer pooling
  □ Registered buffers (io_uring)

□ Documentation
  □ API documentation
  □ Examples
  □ Performance guide

□ std.Io compatibility
  □ Align with Zig 0.16 std.Io
  □ Migration guide
```

---

## Performance Considerations

### Memory Efficiency

| Component | Target Overhead |
|-----------|-----------------|
| Task | 64-256 bytes |
| Future | 32 bytes |
| Channel slot | sizeof(T) + 8 bytes |
| Timer | 24 bytes |

### Syscall Reduction

With io_uring:
- Batch multiple operations per submit
- Use SQPOLL for zero syscall submission
- Register buffers for zero-copy I/O
- Use DEFER_TASKRUN to reduce wake overhead

### Benchmarks to Track

1. **Echo server throughput** (requests/sec)
2. **Concurrent connections** (max stable connections)
3. **Latency percentiles** (p50, p99, p999)
4. **Memory per connection**
5. **Syscalls per operation**
6. **Context switches per second**

### Comparison Targets

- Raw io_uring performance (C baseline)
- Tokio (Rust)
- Go net/http
- zig-aio

---

## Testing Strategy

### Unit Tests

```zig
// Each module has tests
test "LocalQueue push and pop" {
    var queue = LocalQueue.init(testing.allocator);
    defer queue.deinit();

    var task = Task{ ... };
    queue.push(&task);

    try testing.expectEqual(&task, queue.pop());
    try testing.expectEqual(null, queue.pop());
}
```

### Integration Tests

```zig
test "TCP echo server" {
    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    // Start server
    var server = try runtime.spawn(echoServer, .{runtime.io});
    defer server.cancel(runtime.io) catch {};

    // Connect and echo
    var client = try runtime.io.net.tcpConnect(Address.initIpv4(.{127,0,0,1}, 8080));
    defer client.close();

    try client.writeAll(runtime.io, "hello");
    var buf: [5]u8 = undefined;
    _ = try client.read(runtime.io, &buf);

    try testing.expectEqualStrings("hello", &buf);
}
```

### Stress Tests

```zig
test "10K concurrent connections" {
    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var futures: [10_000]Future(void) = undefined;

    for (&futures) |*f| {
        f.* = runtime.io.async(clientTask, .{runtime.io});
    }

    for (&futures) |*f| {
        try f.await(runtime.io);
    }
}
```

### Platform Tests

- Linux (io_uring, epoll)
- macOS (kqueue)
- Windows (IOCP)
- CI matrix for all platforms

---

## References & Prior Art

### Zig Resources

- [Zig's New Async I/O](https://kristoff.it/blog/zig-new-async-io/) - Loris Cro
- [Zig 0.15.1 Release Notes](https://ziglang.org/download/0.15.1/release-notes.html)
- [zig-aio](https://github.com/Cloudef/zig-aio) - Existing Zig async I/O library
- [TigerBeetle I/O](https://github.com/tigerbeetle/tigerbeetle) - Production io_uring usage

### Tokio Resources

- [Tokio Tutorial](https://tokio.rs/tokio/tutorial)
- [tokio-uring Design](https://github.com/tokio-rs/tokio-uring/blob/master/DESIGN.md)
- [Announcing tokio-uring](https://tokio.rs/blog/2021-07-tokio-uring)
- [Mio](https://github.com/tokio-rs/mio) - Cross-platform event loop

### io_uring Resources

- [io_uring and Zig](https://gavinray97.github.io/blog/io-uring-fixed-bufferpool-zig)
- [Lord of the io_uring](https://unixism.net/loti/) - Comprehensive guide
- [liburing](https://github.com/axboe/liburing) - Reference implementation

### General Async I/O

- [Asynchronous Programming in Rust](https://rust-lang.github.io/async-book/)
- [Linux Kernel io_uring](https://kernel.dk/io_uring.pdf)
- [Windows I/O Completion Ports](https://docs.microsoft.com/en-us/windows/win32/fileio/i-o-completion-ports)

---

## Appendix: Project Structure

```
blitz-io/
├── build.zig
├── build.zig.zon
├── README.md
├── CLAUDE.md
├── LICENSE
│
├── src/
│   ├── lib.zig                 # Public API entry point
│   ├── runtime.zig             # Runtime lifecycle
│   ├── config.zig              # Configuration
│   ├── io.zig                  # std.Io implementation
│   ├── future.zig              # Future type
│   ├── time.zig                # Duration, Instant
│   │
│   ├── backend/
│   │   ├── backend.zig         # Backend interface
│   │   ├── detect.zig          # Auto-detection
│   │   ├── io_uring.zig        # Linux io_uring
│   │   ├── epoll.zig           # Linux epoll
│   │   ├── kqueue.zig          # macOS/BSD kqueue
│   │   ├── iocp.zig            # Windows IOCP
│   │   └── poll.zig            # Universal fallback
│   │
│   ├── executor/
│   │   ├── scheduler.zig       # Task scheduling
│   │   ├── worker.zig          # Worker threads
│   │   ├── task.zig            # Task representation
│   │   ├── local_queue.zig     # Lock-free local queue
│   │   └── global_queue.zig    # Global work queue
│   │
│   ├── timer/
│   │   ├── wheel.zig           # Timer wheel
│   │   └── sleep.zig           # sleep, timeout
│   │
│   ├── net/
│   │   ├── tcp.zig             # TcpStream, TcpListener
│   │   ├── udp.zig             # UdpSocket
│   │   └── address.zig         # Address types
│   │
│   ├── fs/
│   │   └── file.zig            # File operations
│   │
│   ├── sync/
│   │   ├── channel.zig         # Channel, Oneshot
│   │   ├── mutex.zig           # Async Mutex
│   │   ├── semaphore.zig       # Semaphore
│   │   └── waiter.zig          # Waiter infrastructure
│   │
│   └── bridge/
│       └── blitz.zig           # Blitz integration
│
├── examples/
│   ├── echo_server.zig
│   ├── http_client.zig
│   ├── file_copy.zig
│   └── mixed_workload.zig
│
├── benchmarks/
│   ├── echo_throughput.zig
│   ├── connection_scaling.zig
│   └── latency.zig
│
└── tests/
    ├── backend_tests.zig
    ├── executor_tests.zig
    ├── net_tests.zig
    └── integration_tests.zig
```

---

*This document serves as the reference specification for blitz-io. Implementation should follow this guide while adapting to discoveries made during development.*
