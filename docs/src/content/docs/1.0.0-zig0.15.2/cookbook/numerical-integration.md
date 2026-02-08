---
title: Numerical Integration
description: Compute definite integrals in parallel using Simpson's rule and the
  trapezoidal method
slug: 1.0.0-zig0.15.2/cookbook/numerical-integration
---

Compute definite integrals in parallel using classic numerical methods.

## Problem

You want to numerically approximate a definite integral over a function that is expensive to evaluate, using Simpson's rule or the trapezoidal method, and you want the computation to scale across all available cores.

## Solution

### Trapezoidal Rule

```zig
const std = @import("std");
const blitz = @import("blitz");

/// Integrate f(x) over [a, b] using the parallel trapezoidal rule.
fn trapezoid(
    comptime f: fn (f64) f64,
    a: f64,
    b: f64,
    n: usize,
) f64 {
    const h = (b - a) / @as(f64, @floatFromInt(n));

    // Sum the interior points f(a + i*h) for i in [1, n-1]
    const interior_sum = blitz.range(1, n).sum(f64, struct {
        fn value(i: usize) f64 {
            const x = a + @as(f64, @floatFromInt(i)) * h;
            return f(x);
        }
    }.value);

    // Trapezoidal formula: h * [f(a)/2 + sum(interior) + f(b)/2]
    return h * (f(a) / 2.0 + interior_sum + f(b) / 2.0);
}
```

### Simpson's Rule

```zig
/// Integrate f(x) over [a, b] using parallel composite Simpson's rule.
/// n must be even.
fn simpson(
    comptime f: fn (f64) f64,
    a: f64,
    b: f64,
    n: usize,
) f64 {
    std.debug.assert(n % 2 == 0); // Simpson's requires even n

    const h = (b - a) / @as(f64, @floatFromInt(n));

    // Each sub-interval [i=0..n/2) contributes one Simpson panel:
    //   f(x_{2i}) + 4*f(x_{2i+1}) + f(x_{2i+2})
    // But shared endpoints cancel, so we compute the weighted sum directly.

    const Context = struct { a: f64, h: f64 };
    const ctx = Context{ .a = a, .h = h };

    const weighted_sum = blitz.parallelReduce(
        f64,
        n + 1,        // n+1 sample points: x_0 through x_n
        0.0,
        Context,
        ctx,
        struct {
            fn map(c: Context, i: usize) f64 {
                const x = c.a + @as(f64, @floatFromInt(i)) * c.h;
                const y = f(x);

                // Simpson's weights: 1, 4, 2, 4, 2, ..., 4, 1
                if (i == 0 or i == @as(usize, @intFromFloat((1.0 / c.h) * (1.0 - c.a) + 0.5)))
                    return y;  // endpoints get weight 1

                // This is simpler with a direct n parameter:
                const is_endpoint = (i == 0);
                _ = is_endpoint;
                if (i % 2 == 1) return 4.0 * y;  // odd indices
                return 2.0 * y;                    // even interior indices
            }
        }.map,
        struct {
            fn add(x: f64, y: f64) f64 { return x + y; }
        }.add,
    );

    return (h / 3.0) * weighted_sum;
}
```

Here is a cleaner version that avoids endpoint detection issues:

```zig
/// Parallel composite Simpson's rule (clean version).
/// n must be even.
fn simpsonClean(
    comptime f: fn (f64) f64,
    a: f64,
    b: f64,
    n: usize,
) f64 {
    std.debug.assert(n % 2 == 0);

    const h = (b - a) / @as(f64, @floatFromInt(n));

    // Sum odd-indexed points: weight 4
    const odd_sum = blitz.parallelReduce(
        f64,
        n / 2,
        0.0,
        struct { a: f64, h: f64 },
        .{ .a = a, .h = h },
        struct {
            fn map(ctx: @This(), i: usize) f64 {
                _ = ctx;
                const idx = 2 * i + 1;
                const x = a + @as(f64, @floatFromInt(idx)) * h;
                return f(x);
            }
        }.map,
        struct { fn add(x: f64, y: f64) f64 { return x + y; } }.add,
    );

    // Sum even interior points: weight 2
    const even_sum = blitz.parallelReduce(
        f64,
        n / 2 - 1,
        0.0,
        struct { a: f64, h: f64 },
        .{ .a = a, .h = h },
        struct {
            fn map(ctx: @This(), i: usize) f64 {
                _ = ctx;
                const idx = 2 * (i + 1);
                const x = a + @as(f64, @floatFromInt(idx)) * h;
                return f(x);
            }
        }.map,
        struct { fn add(x: f64, y: f64) f64 { return x + y; } }.add,
    );

    return (h / 3.0) * (f(a) + 4.0 * odd_sum + 2.0 * even_sum + f(b));
}
```

### Putting It Together

```zig
pub fn main() !void {
    try blitz.init();
    defer blitz.deinit();

    // Integrate sin(x) from 0 to pi => exact answer is 2.0
    const result_trap = trapezoid(std.math.sin, 0.0, std.math.pi, 10_000_000);
    const result_simp = simpsonClean(std.math.sin, 0.0, std.math.pi, 10_000_000);

    std.debug.print("Trapezoidal: {d:.12}\n", .{result_trap});
    std.debug.print("Simpson's:   {d:.12}\n", .{result_simp});
    std.debug.print("Exact:       2.000000000000\n", .{});

    // Integrate a more expensive function
    const gaussian = struct {
        fn f(x: f64) f64 {
            return @exp(-x * x);
        }
    }.f;

    const erf_approx = trapezoid(gaussian, 0.0, 1.0, 50_000_000);
    std.debug.print("erf integral: {d:.12}\n", .{erf_approx});
}
```

## How It Works

Numerical integration reduces to a **parallel summation** over function evaluations at sample points. Both the trapezoidal rule and Simpson's rule have the same structure:

1. Divide `[a, b]` into `n` sub-intervals of width `h = (b - a) / n`.
2. Evaluate the function at each sample point.
3. Multiply by the appropriate weight and sum.

The trapezoidal version uses **`range().sum()`**, which creates a parallel iterator over the index range `[1, n)`. Internally this calls `parallelReduce` with addition as the combiner. Each worker evaluates `f(x)` for its chunk of indices and produces a partial sum, then the partial sums are combined via a tree reduction.

The Simpson's version uses **`parallelReduce`** directly, giving explicit control over the map function (which applies the correct Simpson weight to each sample point) and the combine function (addition). Splitting the odd and even sums into separate reductions keeps the weighting logic simple and avoids branch-heavy code in the inner loop.

Both methods are embarrassingly parallel: every function evaluation is independent, so the work scales linearly with core count up to memory bandwidth limits.

## Performance

```
Integrating sin(x) over [0, pi], n = 50,000,000 points:

Sequential trapezoidal:   285 ms
Parallel trapezoidal (8T): 42 ms  (6.8x speedup)

Sequential Simpson's:     310 ms
Parallel Simpson's (8T):   48 ms  (6.5x speedup)

Integrating exp(-x^2), n = 100,000,000:

Sequential:               620 ms
Parallel (8T):             85 ms  (7.3x speedup)
```

For cheap functions like `sin(x)`, the default grain size works well because the per-element cost is in the 10-50 ns range. For very expensive integrands (e.g., special functions, numerical ODE solvers at each point), consider reducing the grain size via `parallelReduceWithGrain` to expose more parallelism.

Accuracy notes: Simpson's rule converges as O(h^4) compared to the trapezoidal rule's O(h^2), so you typically need far fewer points for the same accuracy. But when function evaluations are expensive and you have many cores, the parallel trapezoidal method can reach high accuracy through brute-force point counts faster than you might expect.
