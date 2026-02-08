---
title: Parallel File Scanning
description: Scan files and directories in parallel with error handling using tryForEach
slug: v1.0.0-zig0.15.2/v2.0.0-zig0.15.3/cookbook/file-scanning
---

Scan files and directories in parallel with graceful error handling.

## Problem

You want to scan a large number of files or directories in parallel -- for example, validating configuration files, checking file integrity, or searching file contents -- and collect results while handling I/O errors gracefully.

## Solution

```zig
const std = @import("std");
const blitz = @import("blitz");

const ScanError = error{
    InvalidFormat,
    AccessDenied,
    FileTooLarge,
    Unexpected,
};

const ScanResult = struct {
    valid_count: usize = 0,
    error_count: usize = 0,
    total_bytes: u64 = 0,
};

/// Scan files in parallel, validating each one.
fn scanFiles(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) ScanError!ScanResult {
    // Phase 1: Validate all files in parallel with tryForEach.
    // Each worker processes a chunk of file paths.
    var valid_flags: []bool = allocator.alloc(bool, paths.len) catch
        return ScanError.Unexpected;
    defer allocator.free(valid_flags);
    @memset(valid_flags, false);

    var file_sizes: []u64 = allocator.alloc(u64, paths.len) catch
        return ScanError.Unexpected;
    defer allocator.free(file_sizes);
    @memset(file_sizes, 0);

    const Context = struct {
        paths: []const []const u8,
        valid_flags: []bool,
        file_sizes: []u64,
    };

    const ctx = Context{
        .paths = paths,
        .valid_flags = valid_flags,
        .file_sizes = file_sizes,
    };

    // tryForEach lets each chunk return an error.
    // All chunks run to completion before any error propagates.
    const result = blitz.tryForEach(
        paths.len,
        ScanError,
        Context,
        ctx,
        struct {
            fn body(c: Context, start: usize, end: usize) ScanError!void {
                for (start..end) |i| {
                    const path = c.paths[i];

                    // Open and stat each file
                    const file = std.fs.cwd().openFile(path, .{}) catch {
                        // Mark as invalid but continue scanning
                        c.valid_flags[i] = false;
                        continue;
                    };
                    defer file.close();

                    const stat = file.stat() catch {
                        c.valid_flags[i] = false;
                        continue;
                    };

                    // Reject files over 100 MB
                    if (stat.size > 100 * 1024 * 1024) {
                        c.valid_flags[i] = false;
                        continue;
                    }

                    c.file_sizes[i] = stat.size;
                    c.valid_flags[i] = true;
                }
            }
        }.body,
    );

    // If tryForEach returned an error, propagate it
    result catch |err| return err;

    // Phase 2: Aggregate results with parallelReduce
    const aggregate = blitz.parallelReduce(
        ScanResult,
        paths.len,
        ScanResult{},
        struct {
            valid_flags: []const bool,
            file_sizes: []const u64,
        },
        .{ .valid_flags = valid_flags, .file_sizes = file_sizes },
        struct {
            fn map(c: @TypeOf(.{
                .valid_flags = valid_flags,
                .file_sizes = file_sizes,
            }), i: usize) ScanResult {
                _ = c;
                if (valid_flags[i]) {
                    return .{
                        .valid_count = 1,
                        .error_count = 0,
                        .total_bytes = file_sizes[i],
                    };
                } else {
                    return .{
                        .valid_count = 0,
                        .error_count = 1,
                        .total_bytes = 0,
                    };
                }
            }
        }.map,
        struct {
            fn combine(a: ScanResult, b: ScanResult) ScanResult {
                return .{
                    .valid_count = a.valid_count + b.valid_count,
                    .error_count = a.error_count + b.error_count,
                    .total_bytes = a.total_bytes + b.total_bytes,
                };
            }
        }.combine,
    );

    return aggregate;
}

pub fn main() !void {
    try blitz.init();
    defer blitz.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const paths = [_][]const u8{
        "config/app.json",
        "config/db.json",
        "config/auth.json",
        "data/users.csv",
        "data/logs.csv",
    };

    const result = try scanFiles(allocator, &paths);

    std.debug.print("Scanned {d} files: {d} valid, {d} errors, {d} bytes total\n", .{
        paths.len,
        result.valid_count,
        result.error_count,
        result.total_bytes,
    });
}
```

A simpler pattern for scanning where you only need to detect the first error:

```zig
const ValidateError = error{ MalformedHeader, Corrupted };

fn validateAllFiles(paths: []const []const u8) ValidateError!void {
    return blitz.tryForEach(
        paths.len,
        ValidateError,
        []const []const u8,
        paths,
        struct {
            fn body(p: []const []const u8, start: usize, end: usize) ValidateError!void {
                for (start..end) |i| {
                    try validateSingleFile(p[i]);
                }
            }
        }.body,
    );
}

fn validateSingleFile(path: []const u8) ValidateError!void {
    _ = path;
    // ... validation logic ...
}
```

## How It Works

This recipe uses two Blitz APIs working together:

1. **`tryForEach`** distributes file scanning across worker threads. Each worker receives a chunk of file indices `[start, end)` and processes them sequentially within that chunk. The key property of `tryForEach` is **error safety**: if any chunk returns an error, all other chunks are allowed to run to completion before the error propagates. This prevents dangling references to stack frames that parallel workers might still be accessing.

2. **`parallelReduce`** aggregates the per-file results into a single `ScanResult`. Each element maps to a small struct (1 valid or 1 error), and the `combine` function sums the fields together. Because addition is associative, the tree reduction produces the correct totals regardless of how work is partitioned.

The two-phase approach (scan then aggregate) avoids shared mutable state. Each worker writes to its own disjoint region of the `valid_flags` and `file_sizes` arrays, then the reduction reads them without contention.

## Performance

```
Scanning 10,000 config files (stat + header check):

Sequential scan:          420 ms
Parallel tryForEach (8T): 68 ms   (6.2x speedup)

Scanning 50,000 files:

Sequential scan:          2,100 ms
Parallel tryForEach (8T): 310 ms  (6.8x speedup)
```

File scanning is well-suited for parallelism because each file is an independent unit of work, and the per-file cost (open, stat, read header) is large enough to overcome fork-join overhead. The `tryForEach` API handles the common case where some files may be missing or unreadable without crashing the entire scan.

For very fast per-file checks (just `stat`), increase the grain size with `parallelForWithGrain` to reduce overhead. For expensive per-file work (parsing, checksumming), the default grain works well.
