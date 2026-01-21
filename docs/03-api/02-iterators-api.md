# Iterators API Reference

Rayon-style parallel iterators.

## Creating Iterators

### `iter(T, slice) ParIter(T)`

Create immutable parallel iterator.

```zig
const it = blitz.iter(i64, data);
```

### `iterMut(T, slice) ParIterMut(T)`

Create mutable parallel iterator.

```zig
var it = blitz.iterMut(i64, data);
```

### `range(start, end) RangeIter`

Create iterator over index range `[start, end)`.

```zig
const it = blitz.range(0, 1000);
```

---

## ParIter(T) Methods

### Aggregations

| Method | Signature | Description |
|--------|-----------|-------------|
| `sum()` | `fn() T` | SIMD-optimized sum |
| `min()` | `fn() ?T` | SIMD-optimized minimum |
| `max()` | `fn() ?T` | SIMD-optimized maximum |
| `count()` | `fn() usize` | Element count |

```zig
const it = blitz.iter(i64, data);
const sum = it.sum();
const min = it.min();  // Returns ?i64
```

### General Reduce

```zig
fn reduce(identity: T, comptime reducer: fn(T, T) T) T
```

```zig
const product = it.reduce(1, struct {
    fn mul(a: i64, b: i64) i64 { return a * b; }
}.mul);
```

---

### Find Operations

| Method | Returns | Description |
|--------|---------|-------------|
| `findAny(pred)` | `?T` | Any matching element (fast) |
| `findFirst(pred)` | `?FindResult(T)` | First matching with index |
| `findLast(pred)` | `?FindResult(T)` | Last matching with index |
| `position(pred)` | `?usize` | Index of first match |
| `rposition(pred)` | `?usize` | Index of last match |

```zig
// FindResult(T) = struct { index: usize, value: T }

const found = it.findAny(isNegative);           // ?i64
const first = it.findFirst(isNegative);         // ?{index, value}
const pos = it.position(isNegative);            // ?usize
```

**Predicate signature:** `fn(T) bool`

---

### Predicates

| Method | Returns | Description |
|--------|---------|-------------|
| `any(pred)` | `bool` | True if any match (early exit) |
| `all(pred)` | `bool` | True if all match (early exit) |

```zig
const hasNeg = it.any(struct { fn p(x: i64) bool { return x < 0; } }.p);
const allPos = it.all(struct { fn p(x: i64) bool { return x > 0; } }.p);
```

---

### Min/Max by Comparator or Key

```zig
fn minBy(comptime cmp: fn(T, T) std.math.Order) ?T
fn maxBy(comptime cmp: fn(T, T) std.math.Order) ?T
fn minByKey(comptime K: type, comptime key_fn: fn(T) K) ?T
fn maxByKey(comptime K: type, comptime key_fn: fn(T) K) ?T
```

**Examples:**
```zig
// By custom comparator
const smallest = it.minBy(struct {
    fn cmp(a: Person, b: Person) std.math.Order {
        return std.math.order(a.age, b.age);
    }
}.cmp);

// By key function
const youngest = it.minByKey(u32, struct {
    fn key(p: Person) u32 { return p.age; }
}.key);
```

---

### Transformations

```zig
fn map(comptime func: fn(T) T) MappedIter(T)
fn forEach(comptime func: fn(T) void) void
fn collect(allocator: Allocator) ![]T
```

```zig
// Map creates lazy transformed iterator
const squared = it.map(struct { fn f(x: i64) i64 { return x * x; } }.f);
const sum_of_squares = squared.sum();

// forEach executes for each element
it.forEach(struct { fn f(x: i64) void { process(x); } }.f);

// collect allocates new array
const copy = try it.collect(allocator);
```

---

### Sub-Iterators

```zig
fn chunks_iter(chunk_size: usize) ChunksIter(T)
fn enumerate_iter() EnumerateIter(T)
fn enumerateFrom(offset: usize) EnumerateIter(T)
```

---

## ChunksIter(T) Methods

```zig
fn count() usize
fn forEach(comptime func: fn([]const T) void) void
fn reduce(comptime R: type, identity: R, chunkFn, combineFn) R
```

```zig
const chunks = it.chunks_iter(1000);
const n = chunks.count();

chunks.forEach(struct {
    fn process(chunk: []const i64) void { ... }
}.process);

const total = chunks.reduce(i64, 0,
    struct { fn sum(c: []const i64) i64 { ... } }.sum,
    struct { fn add(a: i64, b: i64) i64 { return a + b; } }.add,
);
```

---

## EnumerateIter(T) Methods

```zig
fn any(comptime pred: fn(usize, T) bool) bool
fn all(comptime pred: fn(usize, T) bool) bool
fn forEach(comptime func: fn(usize, T) void) void
```

```zig
const enum_it = it.enumerate_iter();

const found = enum_it.any(struct {
    fn pred(idx: usize, val: i64) bool {
        return idx == @as(usize, @intCast(val));
    }
}.pred);
```

---

## ParIterMut(T) Methods

All `ParIter` methods plus:

```zig
fn mapInPlace(comptime func: fn(T) T) void
fn fill(value: T) void
```

```zig
var it = blitz.iterMut(i64, data);
it.mapInPlace(struct { fn double(x: i64) i64 { return x * 2; } }.double);
it.fill(0);
```

---

## RangeIter Methods

```zig
fn sum(comptime T: type, comptime valueFn: fn(usize) T) T
fn forEach(comptime func: fn(usize) void) void
fn collect(comptime T: type, allocator: Allocator, comptime valueFn: fn(usize) T) ![]T
```

```zig
const range_it = blitz.range(0, 1000);

const sum = range_it.sum(i64, struct {
    fn val(i: usize) i64 { return @intCast(i); }
}.val);

range_it.forEach(struct {
    fn process(i: usize) void { doWork(i); }
}.process);
```
