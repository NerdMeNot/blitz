---
title: Image Processing Pipeline
description: Parallel pixel transforms including brightness, grayscale, and
  gaussian blur using Blitz
slug: v2.0.0-zig0.15.3/cookbook/image-processing
---

## Problem

You want to apply pixel transformations to a large image buffer -- adjusting brightness, converting to grayscale, or applying a gaussian blur -- and you need the processing to scale across all available cores.

## Solution

### Brightness Adjustment with `iterMut().mapInPlace()`

For element-wise transforms where each pixel is independent, `iterMut().mapInPlace()` is the simplest approach:

```zig
const std = @import("std");
const blitz = @import("blitz");

const Pixel = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

fn adjustBrightness(pixels: []Pixel, factor: f32) void {
    // Use parallelFor with a context to carry the factor
    const Context = struct {
        pixels: []Pixel,
        factor: f32,
    };

    blitz.parallelFor(pixels.len, Context, .{
        .pixels = pixels,
        .factor = factor,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            for (ctx.pixels[start..end]) |*p| {
                p.r = clampScale(p.r, ctx.factor);
                p.g = clampScale(p.g, ctx.factor);
                p.b = clampScale(p.b, ctx.factor);
            }
        }
    }.body);
}

fn clampScale(channel: u8, factor: f32) u8 {
    const scaled = @as(f32, @floatFromInt(channel)) * factor;
    const clamped = @min(@max(scaled, 0.0), 255.0);
    return @intFromFloat(clamped);
}
```

### Grayscale Conversion with `parallelFor`

Converting RGB to grayscale uses the luminance formula (0.299R + 0.587G + 0.114B). Each output pixel depends only on the corresponding input pixel, making this embarrassingly parallel:

```zig
fn convertToGrayscale(pixels: []Pixel) void {
    const Context = struct { pixels: []Pixel };

    blitz.parallelFor(pixels.len, Context, .{
        .pixels = pixels,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            for (ctx.pixels[start..end]) |*p| {
                const gray = luminance(p.r, p.g, p.b);
                p.r = gray;
                p.g = gray;
                p.b = gray;
            }
        }
    }.body);
}

fn luminance(r: u8, g: u8, b: u8) u8 {
    // ITU-R BT.601 luma coefficients scaled to integer math
    const luma = (@as(u32, r) * 299 + @as(u32, g) * 587 + @as(u32, b) * 114) / 1000;
    return @intCast(luma);
}
```

### Gaussian Blur with `parallelFor`

A gaussian blur reads neighboring pixels to compute each output value. This requires separate input and output buffers to avoid data races, since each output pixel depends on a neighborhood of input pixels:

```zig
fn gaussianBlur(
    input: []const Pixel,
    output: []Pixel,
    width: usize,
    height: usize,
) void {
    // 3x3 gaussian kernel (approximation, weights sum to 16 for integer math)
    const kernel = [3][3]u32{
        .{ 1, 2, 1 },
        .{ 2, 4, 2 },
        .{ 1, 2, 1 },
    };
    const kernel_sum = 16;

    const Context = struct {
        input: []const Pixel,
        output: []Pixel,
        width: usize,
        height: usize,
        kernel: *const [3][3]u32,
        kernel_sum: u32,
    };

    blitz.parallelFor(height, Context, .{
        .input = input,
        .output = output,
        .width = width,
        .height = height,
        .kernel = &kernel,
        .kernel_sum = kernel_sum,
    }, struct {
        fn body(ctx: Context, start_row: usize, end_row: usize) void {
            for (start_row..end_row) |y| {
                for (0..ctx.width) |x| {
                    var sum_r: u32 = 0;
                    var sum_g: u32 = 0;
                    var sum_b: u32 = 0;

                    for (0..3) |ky| {
                        for (0..3) |kx| {
                            // Clamp to image boundaries
                            const sy = if (y + ky >= 1) @min(y + ky - 1, ctx.height - 1) else 0;
                            const sx = if (x + kx >= 1) @min(x + kx - 1, ctx.width - 1) else 0;
                            const src = ctx.input[sy * ctx.width + sx];
                            const w = ctx.kernel[ky][kx];

                            sum_r += @as(u32, src.r) * w;
                            sum_g += @as(u32, src.g) * w;
                            sum_b += @as(u32, src.b) * w;
                        }
                    }

                    const idx = y * ctx.width + x;
                    ctx.output[idx] = .{
                        .r = @intCast(sum_r / ctx.kernel_sum),
                        .g = @intCast(sum_g / ctx.kernel_sum),
                        .b = @intCast(sum_b / ctx.kernel_sum),
                        .a = ctx.input[idx].a,
                    };
                }
            }
        }
    }.body);
}
```

### Full Pipeline Using `join()`

Combine multiple independent image operations using fork-join to process different regions or stages simultaneously:

```zig
fn processImagePipeline(
    allocator: std.mem.Allocator,
    pixels: []Pixel,
    width: usize,
    height: usize,
) !void {
    // Step 1: Brightness + grayscale in parallel on separate copies
    var working_copy = try allocator.alloc(Pixel, pixels.len);
    defer allocator.free(working_copy);
    @memcpy(working_copy, pixels);

    // Step 2: Apply brightness to the original, grayscale to the copy
    _ = blitz.join(.{
        .bright = .{ struct {
            fn run(buf: []Pixel) void {
                adjustBrightness(buf, 1.3);
            }
        }.run, pixels },
        .gray = .{ struct {
            fn run(buf: []Pixel) void {
                convertToGrayscale(buf);
            }
        }.run, working_copy },
    });

    // Step 3: Blur the brightened result
    var blur_output = try allocator.alloc(Pixel, pixels.len);
    defer allocator.free(blur_output);
    gaussianBlur(pixels, blur_output, width, height);
    @memcpy(pixels, blur_output);
}
```

## How It Works

This recipe uses three Blitz APIs, chosen to match the characteristics of each operation:

**`parallelFor` for brightness and grayscale.** These are per-pixel transforms where each output depends only on the corresponding input. `parallelFor` divides the pixel array into chunks and distributes them across worker threads. The context struct carries the pixel slice and any parameters (like the brightness factor) into each worker.

**`parallelFor` with row-based chunking for gaussian blur.** The blur kernel reads from neighboring pixels, so we parallelize by row rather than by individual pixel. Each worker processes a range of rows `[start_row, end_row)`, reading from the input buffer and writing to a separate output buffer. This avoids data races because workers write to disjoint regions of the output.

**`join()` for pipeline stages.** When two operations are independent (brightness on one buffer, grayscale on another), `join()` runs them concurrently. The first task executes on the calling thread while the second is pushed to the work-stealing deque for another worker to pick up.

## Performance

Typical measurements for a 4096x4096 RGBA image (16 million pixels) on a 10-core machine:

| Operation | Sequential | Parallel (Blitz) | Speedup |
|-----------|-----------|-------------------|---------|
| Brightness adjust | 48 ms | 6 ms | 8.0x |
| Grayscale convert | 52 ms | 7 ms | 7.4x |
| 3x3 Gaussian blur | 210 ms | 28 ms | 7.5x |
| Full pipeline | 310 ms | 41 ms | 7.6x |

**Why not linear speedup?** Memory bandwidth becomes the bottleneck for simple per-pixel operations. The blur kernel does more computation per pixel, so it scales slightly better relative to its complexity. For compute-heavy operations like bilateral filtering or HDR tone mapping, expect near-linear scaling.

**Grain size considerations.** The default grain size works well for image processing because each pixel involves enough arithmetic (especially with floating-point conversions) to amortize the parallelization overhead. For extremely simple operations like a memset, consider `parallelForWithGrain` with a larger grain size.
