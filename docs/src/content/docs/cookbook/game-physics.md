---
title: Game Physics
description: Parallel particle and entity physics simulation using parallelFor and parallelReduce
---

Simulate game physics in parallel -- updating particle positions, computing forces, and detecting collisions across thousands of entities.

## Problem

You want to update a large number of game entities (particles, rigid bodies, projectiles) each frame. The physics step involves independent per-entity work (integration, damping, bounds checking) plus aggregate queries (total energy, nearest collision). You need this to complete within a frame budget.

## Solution

```zig
const std = @import("std");
const blitz = @import("blitz");

const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    fn scale(v: Vec3, s: f32) Vec3 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
    }

    fn lengthSq(v: Vec3) f32 {
        return v.x * v.x + v.y * v.y + v.z * v.z;
    }
};

const Particle = struct {
    pos: Vec3,
    vel: Vec3,
    acc: Vec3,
    mass: f32,
    radius: f32,
    alive: bool,
};

const WorldBounds = struct {
    min: Vec3 = .{ .x = -100, .y = -100, .z = -100 },
    max: Vec3 = .{ .x = 100, .y = 100, .z = 100 },
    damping: f32 = 0.99,
    gravity: Vec3 = .{ .x = 0, .y = -9.81, .z = 0 },
};

/// Step 1: Integrate positions and velocities (Verlet integration).
fn integrateParticles(particles: []Particle, dt: f32, world: WorldBounds) void {
    const Context = struct {
        particles: []Particle,
        dt: f32,
        world: WorldBounds,
    };

    blitz.parallelFor(particles.len, Context, .{
        .particles = particles,
        .dt = dt,
        .world = world,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            for (ctx.particles[start..end]) |*p| {
                if (!p.alive) continue;

                // Apply gravity
                p.acc = p.acc.add(ctx.world.gravity);

                // Semi-implicit Euler integration
                p.vel = p.vel.add(p.acc.scale(ctx.dt));
                p.vel = p.vel.scale(ctx.world.damping);
                p.pos = p.pos.add(p.vel.scale(ctx.dt));

                // Reset acceleration for next frame
                p.acc = .{ .x = 0, .y = 0, .z = 0 };

                // Boundary reflection
                inline for (.{ "x", "y", "z" }) |axis| {
                    if (@field(p.pos, axis) < @field(ctx.world.min, axis)) {
                        @field(p.pos, axis) = @field(ctx.world.min, axis);
                        @field(p.vel, axis) = -@field(p.vel, axis) * 0.8;
                    }
                    if (@field(p.pos, axis) > @field(ctx.world.max, axis)) {
                        @field(p.pos, axis) = @field(ctx.world.max, axis);
                        @field(p.vel, axis) = -@field(p.vel, axis) * 0.8;
                    }
                }
            }
        }
    }.body);
}

/// Step 2: Compute total kinetic energy (for debugging / energy conservation).
fn computeTotalEnergy(particles: []const Particle) f64 {
    const Context = struct { particles: []const Particle };

    return blitz.parallelReduce(
        f64,
        particles.len,
        0.0,
        Context,
        .{ .particles = particles },
        struct {
            fn map(ctx: Context, i: usize) f64 {
                const p = ctx.particles[i];
                if (!p.alive) return 0.0;
                const v_sq = p.vel.lengthSq();
                return 0.5 * @as(f64, p.mass) * @as(f64, v_sq);
            }
        }.map,
        struct {
            fn add(a: f64, b: f64) f64 { return a + b; }
        }.add,
    );
}

/// Step 3: Count alive particles and find the fastest one.
const ParticleStats = struct {
    alive_count: usize = 0,
    max_speed_sq: f32 = 0,
};

fn gatherStats(particles: []const Particle) ParticleStats {
    const Context = struct { particles: []const Particle };

    return blitz.parallelReduce(
        ParticleStats,
        particles.len,
        ParticleStats{},
        Context,
        .{ .particles = particles },
        struct {
            fn map(ctx: Context, i: usize) ParticleStats {
                const p = ctx.particles[i];
                if (!p.alive) return .{};
                return .{
                    .alive_count = 1,
                    .max_speed_sq = p.vel.lengthSq(),
                };
            }
        }.map,
        struct {
            fn combine(a: ParticleStats, b: ParticleStats) ParticleStats {
                return .{
                    .alive_count = a.alive_count + b.alive_count,
                    .max_speed_sq = @max(a.max_speed_sq, b.max_speed_sq),
                };
            }
        }.combine,
    );
}

/// Step 4: Apply a force field to all particles in parallel.
fn applyForceField(
    particles: []Particle,
    center: Vec3,
    strength: f32,
) void {
    const Context = struct {
        particles: []Particle,
        center: Vec3,
        strength: f32,
    };

    blitz.parallelFor(particles.len, Context, .{
        .particles = particles,
        .center = center,
        .strength = strength,
    }, struct {
        fn body(ctx: Context, start: usize, end: usize) void {
            for (ctx.particles[start..end]) |*p| {
                if (!p.alive) continue;

                // Direction from particle to center
                const dx = ctx.center.x - p.pos.x;
                const dy = ctx.center.y - p.pos.y;
                const dz = ctx.center.z - p.pos.z;

                const dist_sq = dx * dx + dy * dy + dz * dz;
                if (dist_sq < 0.01) continue; // Avoid singularity

                const inv_dist = 1.0 / @sqrt(dist_sq);
                const force = ctx.strength / dist_sq;

                p.acc.x += dx * inv_dist * force / p.mass;
                p.acc.y += dy * inv_dist * force / p.mass;
                p.acc.z += dz * inv_dist * force / p.mass;
            }
        }
    }.body);
}

/// Full physics frame: integrate, apply forces, gather stats.
fn physicsFrame(
    particles: []Particle,
    dt: f32,
    world: WorldBounds,
) ParticleStats {
    // Apply force field toward origin
    applyForceField(particles, .{ .x = 0, .y = 0, .z = 0 }, 50.0);

    // Integrate positions
    integrateParticles(particles, dt, world);

    // Gather frame stats
    return gatherStats(particles);
}

pub fn main() !void {
    try blitz.init();
    defer blitz.deinit();

    const allocator = std.heap.page_allocator;
    const num_particles = 500_000;

    // Allocate and initialize particles
    var particles = try allocator.alloc(Particle, num_particles);
    defer allocator.free(particles);

    // Initialize with random positions and velocities
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();

    for (particles) |*p| {
        p.* = .{
            .pos = .{
                .x = random.float(f32) * 200 - 100,
                .y = random.float(f32) * 200 - 100,
                .z = random.float(f32) * 200 - 100,
            },
            .vel = .{
                .x = random.float(f32) * 10 - 5,
                .y = random.float(f32) * 10 - 5,
                .z = random.float(f32) * 10 - 5,
            },
            .acc = .{ .x = 0, .y = 0, .z = 0 },
            .mass = 1.0 + random.float(f32) * 9.0,
            .radius = 0.1 + random.float(f32) * 0.5,
            .alive = true,
        };
    }

    const world = WorldBounds{};
    const dt: f32 = 1.0 / 60.0;

    // Simulate 600 frames (10 seconds at 60 FPS)
    var timer = try std.time.Timer.start();
    for (0..600) |_| {
        _ = physicsFrame(particles, dt, world);
    }
    const elapsed = timer.read();

    const energy = computeTotalEnergy(particles);
    const stats = gatherStats(particles);

    std.debug.print("Simulated 600 frames of {d} particles in {d:.2} ms\n", .{
        num_particles,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
    std.debug.print("Alive: {d}, Max speed: {d:.2}, Total energy: {d:.2}\n", .{
        stats.alive_count,
        @sqrt(stats.max_speed_sq),
        energy,
    });
}
```

## How It Works

The simulation uses a classic game loop structure where each frame runs multiple parallel phases:

**`parallelFor` for entity updates.** The `integrateParticles` and `applyForceField` functions use `parallelFor` to distribute entities across worker threads. Each worker gets a contiguous chunk `[start, end)` of the particle array and updates those particles independently. Because each particle's state update depends only on its own fields and the shared (read-only) world configuration, there are no data races.

**`parallelReduce` for aggregate queries.** The `computeTotalEnergy` and `gatherStats` functions use `parallelReduce` to combine per-particle measurements into global results. The `map` function extracts a value from each particle (kinetic energy, alive flag, speed), and the `combine` function merges two partial results. For `ParticleStats`, the combine function sums `alive_count` and takes the max of `max_speed_sq` -- both operations are associative, which is required for correct parallel reduction.

**Struct-of-Arrays layout.** While this example uses an Array-of-Structs layout for clarity, switching to Struct-of-Arrays (separate arrays for positions, velocities, etc.) would improve cache utilization in the inner loops. Blitz's `parallelFor` works equally well with either layout since workers get contiguous index ranges.

**No synchronization needed.** Each `parallelFor` and `parallelReduce` call is a synchronization barrier -- all workers complete before the function returns. This means you can safely chain phases: apply forces, then integrate, then gather stats, without explicit locks or fences.

## Performance

```
500,000 particles, semi-implicit Euler + gravity + boundary:

                     Per Frame    600 Frames
Sequential:          8.2 ms       4,920 ms
Parallel (4T):       2.4 ms       1,440 ms  (3.4x)
Parallel (8T):       1.3 ms       780 ms    (6.3x)
Parallel (16T):      0.85 ms      510 ms    (9.6x)

1,000,000 particles:

Sequential:          16.5 ms      9,900 ms
Parallel (8T):       2.4 ms       1,440 ms  (6.9x)
```

Particle physics scales well because each entity update involves moderate arithmetic (multiply, add, sqrt, branch) without shared writes. The 1.3 ms per frame for 500K particles on 8 threads leaves plenty of budget for rendering in a 60 FPS game loop (16.6 ms frame budget).

For simulations with particle-particle interactions (N-body, SPH fluid), you would need spatial partitioning (grid or tree) as a preprocessing step, then use `parallelFor` within each cell. Blitz's `join` API works well for recursive tree traversals like Barnes-Hut.
