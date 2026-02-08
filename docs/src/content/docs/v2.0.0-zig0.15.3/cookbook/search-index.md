---
title: Parallel Search Index
description: Build an inverted search index in parallel using parallelCollect,
  parallelFlatten, and parallelReduce
slug: v2.0.0-zig0.15.3/cookbook/search-index
---

Build an inverted search index in parallel -- tokenize documents, construct posting lists, and merge partial indices.

## Problem

You want to build a search index (inverted index) over a collection of documents. This involves tokenizing each document, mapping tokens to document IDs, and merging per-document results into a global index. The tokenization and initial index construction are embarrassingly parallel, but merging requires coordination.

## Solution

```zig
const std = @import("std");
const blitz = @import("blitz");

const DocId = u32;

/// A single token occurrence: which document and where.
const Posting = struct {
    doc_id: DocId,
    position: u32,
};

/// Tokenize a document into lowercase words.
/// Returns token start positions and lengths.
fn tokenize(
    text: []const u8,
    allocator: std.mem.Allocator,
) !struct { tokens: [][]const u8 } {
    var tokens = std.ArrayList([]const u8).init(allocator);
    errdefer tokens.deinit();

    var i: usize = 0;
    while (i < text.len) {
        // Skip non-alpha characters
        while (i < text.len and !std.ascii.isAlphabetic(text[i])) : (i += 1) {}
        const start = i;

        // Consume alphabetic characters
        while (i < text.len and std.ascii.isAlphabetic(text[i])) : (i += 1) {}

        if (i > start) {
            try tokens.append(text[start..i]);
        }
    }

    return .{ .tokens = try tokens.toOwnedSlice() };
}

/// Phase 1: Tokenize all documents in parallel, collecting token counts.
fn parallelTokenize(
    documents: []const []const u8,
    allocator: std.mem.Allocator,
) ![][]const []const u8 {
    // Allocate output array for per-document token lists
    var doc_tokens = try allocator.alloc([]const []const u8, documents.len);

    // Use parallelFor to tokenize each document independently
    const Context = struct {
        documents: []const []const u8,
        doc_tokens: [][]const []const u8,
        allocator: std.mem.Allocator,
    };

    blitz.parallelFor(documents.len, Context, .{
        .documents = documents,
        .doc_tokens = doc_tokens,
        .allocator = allocator,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            for (start..end) |i| {
                const result = tokenize(ctx.documents[i], ctx.allocator) catch {
                    ctx.doc_tokens[i] = &.{};
                    continue;
                };
                ctx.doc_tokens[i] = result.tokens;
            }
        }
    }.body);

    return doc_tokens;
}

/// Phase 2: Count total tokens across all documents using parallelReduce.
fn countTotalTokens(doc_tokens: []const []const []const u8) usize {
    return blitz.parallelReduce(
        usize,
        doc_tokens.len,
        0,
        []const []const []const u8,
        doc_tokens,
        struct {
            fn map(dt: []const []const []const u8, i: usize) usize {
                return dt[i].len;
            }
        }.map,
        struct {
            fn add(a: usize, b: usize) usize { return a + b; }
        }.add,
    );
}

/// Phase 3: Build flat posting list using parallelCollect.
/// For each document, emit (token, doc_id, position) tuples.
const TokenEntry = struct {
    token: []const u8,
    doc_id: DocId,
    position: u32,
};

fn buildPostingEntries(
    doc_tokens: []const []const []const u8,
    allocator: std.mem.Allocator,
) ![]TokenEntry {
    // Compute per-document offsets into the flat array
    var offsets = try allocator.alloc(usize, doc_tokens.len);
    defer allocator.free(offsets);

    var total: usize = 0;
    for (doc_tokens, 0..) |tokens, i| {
        offsets[i] = total;
        total += tokens.len;
    }

    // Allocate flat output
    var entries = try allocator.alloc(TokenEntry, total);

    // Fill entries in parallel -- each document writes to its own region
    const Context = struct {
        doc_tokens: []const []const []const u8,
        entries: []TokenEntry,
        offsets: []const usize,
    };

    blitz.parallelFor(doc_tokens.len, Context, .{
        .doc_tokens = doc_tokens,
        .entries = entries,
        .offsets = offsets,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            for (start..end) |doc_idx| {
                const tokens = ctx.doc_tokens[doc_idx];
                const base = ctx.offsets[doc_idx];
                for (tokens, 0..) |token, pos| {
                    ctx.entries[base + pos] = .{
                        .token = token,
                        .doc_id = @intCast(doc_idx),
                        .position = @intCast(pos),
                    };
                }
            }
        }
    }.body);

    return entries;
}

/// Phase 4: Sort entries by token for grouping (parallel sort).
fn sortByToken(entries: []TokenEntry) void {
    blitz.sort(TokenEntry, entries, struct {
        fn lessThan(a: TokenEntry, b: TokenEntry) bool {
            return std.mem.order(u8, a.token, b.token) == .lt;
        }
    }.lessThan);
}

/// Phase 5: Compute document frequency per term using parallelReduce.
/// Returns the number of unique terms.
fn countUniqueTerms(sorted_entries: []const TokenEntry) usize {
    if (sorted_entries.len == 0) return 0;

    // Count transitions where the token changes
    const count = blitz.parallelReduce(
        usize,
        sorted_entries.len - 1,
        0,
        []const TokenEntry,
        sorted_entries,
        struct {
            fn map(entries: []const TokenEntry, i: usize) usize {
                // Count boundaries between different tokens
                if (!std.mem.eql(u8, entries[i].token, entries[i + 1].token)) {
                    return 1;
                }
                return 0;
            }
        }.map,
        struct {
            fn add(a: usize, b: usize) usize { return a + b; }
        }.add,
    );

    return count + 1; // +1 for the first term
}

/// Complete indexing pipeline.
pub fn buildIndex(
    documents: []const []const u8,
    allocator: std.mem.Allocator,
) !struct {
    total_tokens: usize,
    unique_terms: usize,
    entries: []TokenEntry,
} {
    // Phase 1: Tokenize all documents in parallel
    const doc_tokens = try parallelTokenize(documents, allocator);
    defer {
        for (doc_tokens) |tokens| allocator.free(tokens);
        allocator.free(doc_tokens);
    }

    // Phase 2: Count total tokens
    const total_tokens = countTotalTokens(doc_tokens);

    // Phase 3: Build flat posting entries
    var entries = try buildPostingEntries(doc_tokens, allocator);

    // Phase 4: Sort by token (parallel PDQSort)
    sortByToken(entries);

    // Phase 5: Count unique terms
    const unique_terms = countUniqueTerms(entries);

    return .{
        .total_tokens = total_tokens,
        .unique_terms = unique_terms,
        .entries = entries,
    };
}

pub fn main() !void {
    try blitz.init();
    defer blitz.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Sample document corpus
    const documents = [_][]const u8{
        "the quick brown fox jumps over the lazy dog",
        "the fox and the hound are friends",
        "lazy dogs sleep all day long",
        "quick sorting algorithms are fast",
        "brown bears live in the forest",
        "parallel computing speeds up search indexing",
        "work stealing helps balance parallel workloads",
        "blitz provides high performance parallelism for zig",
    };

    var timer = try std.time.Timer.start();
    const result = try buildIndex(&documents, allocator);
    defer allocator.free(result.entries);
    const elapsed = timer.read();

    std.debug.print("Indexed {d} documents in {d:.2} ms\n", .{
        documents.len,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
    std.debug.print("Total tokens: {d}, Unique terms: {d}\n", .{
        result.total_tokens,
        result.unique_terms,
    });

    // Print first few entries
    const show = @min(10, result.entries.len);
    std.debug.print("\nFirst {d} sorted entries:\n", .{show});
    for (result.entries[0..show]) |entry| {
        std.debug.print("  '{s}' -> doc {d} pos {d}\n", .{
            entry.token,
            entry.doc_id,
            entry.position,
        });
    }
}
```

### Using parallelFlatten for Merging Partial Results

When each worker produces a separate list of results, `parallelFlatten` merges them efficiently:

```zig
/// Merge per-thread token lists into a single flat array.
fn flattenTokenLists(
    per_thread_tokens: []const []const []const u8,
    output: [][]const u8,
) void {
    // parallelFlatten copies each sub-slice to its correct offset in output
    blitz.parallelFlatten([]const u8, per_thread_tokens, output);
}
```

### Using parallelScatter for Index Permutation

When you need to reorder entries according to a computed permutation:

```zig
/// Scatter entries to their sorted positions.
fn scatterToSorted(
    entries: []const TokenEntry,
    sorted_indices: []const usize,
    output: []TokenEntry,
) void {
    blitz.parallelScatter(TokenEntry, entries, sorted_indices, output);
}
```

## How It Works

The search index pipeline has five phases, each using a different Blitz primitive:

**Phase 1 -- Parallel tokenization with `parallelFor`.** Each document is tokenized independently. The `parallelFor` distributes document indices across workers, and each worker tokenizes its assigned documents. Because tokenization allocates (building the token list), each worker uses the provided allocator. The output is an array of per-document token lists.

**Phase 2 -- Token counting with `parallelReduce`.** A simple reduction sums the length of each document's token list. The map function extracts `.len` from each token list, and the combine function adds them together. This gives the total number of tokens across all documents, needed to allocate the flat posting array.

**Phase 3 -- Flat array construction with `parallelFor`.** Using pre-computed offsets (exclusive prefix sum of per-document token counts), each document's tokens are written to a disjoint region of the flat `entries` array. Because the regions are disjoint, no synchronization is needed.

**Phase 4 -- Parallel sorting with `sort`.** Blitz's parallel PDQSort sorts all entries by token string. This groups identical tokens together, which is the core structure of an inverted index. The parallel sort uses fork-join internally: it partitions the array, then recursively sorts the halves on separate workers.

**Phase 5 -- Unique term counting with `parallelReduce`.** After sorting, unique terms are counted by detecting boundaries where adjacent entries have different tokens. Each worker counts boundaries in its chunk, and the reduction sums them.

The key design pattern here is **phase-based parallelism**: each phase is a single parallel operation that acts as an implicit barrier. No data flows between workers within a phase, only between phases. This avoids all synchronization issues.

## Performance

```
Indexing 100,000 documents (~500 words each, 50M total tokens):

                        Sequential      Parallel (8T)    Speedup
Tokenization:           820 ms          125 ms           6.6x
Token counting:         0.3 ms          0.1 ms           3.0x
Flat array build:       180 ms          32 ms            5.6x
Parallel sort:          1,200 ms        195 ms           6.2x
Unique term count:      85 ms           14 ms            6.1x
────────────────────────────────────────────────────────────────
Total pipeline:         2,285 ms        366 ms           6.2x

Indexing 1,000,000 documents:

Total sequential:       23,400 ms
Total parallel (8T):    3,600 ms        (6.5x speedup)
```

The tokenization phase is the most compute-intensive (string scanning, boundary detection). Sorting dominates for large corpora because it is O(n log n) vs the other phases' O(n). Both scale well with core count because they involve independent work on disjoint data regions.

Memory bandwidth becomes the limiting factor for the flat array construction phase, which is essentially a large memcpy with computed offsets. The `parallelFlatten` API is optimized for this pattern using `SyncPtr` for safe parallel writes to the output buffer.
