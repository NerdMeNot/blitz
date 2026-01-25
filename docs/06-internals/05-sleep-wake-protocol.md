# Sleep/Wake Protocol

The Rayon-style JEC (Jobs Event Counter) protocol that coordinates worker sleep/wake efficiently.

## Overview

When workers can't find work, they need to sleep to avoid wasting CPU. When new work arrives, sleeping workers need to be woken. Blitz uses a sophisticated protocol inspired by Rayon that minimizes both missed wakes and unnecessary wake-ups.

## The Problem: Sleep/Wake Races

### The Tickle-Then-Get-Sleepy Race

```
Without protection (RACE!):
  Worker A: if (!hasWork) {      Poster B: postWork();
  Worker A:                      Poster B: wake();  // A not sleeping yet!
  Worker A:   sleep();           // MISSED WAKE - A sleeps forever
```

The worker checks for work, then goes to sleep. But between the check and the sleep, new work might arrive. The poster tries to wake, but the worker isn't sleeping yet. When the worker finally sleeps, no one will wake them.

## Blitz's Solution: JEC Protocol

### Jobs Event Counter (JEC)

The JEC is a 32-bit counter packed into the upper bits of AtomicCounters:

```
AtomicCounters (u64):
├── Bits 0-15:  sleeping_threads
├── Bits 16-31: inactive_threads
└── Bits 32-63: JEC (Jobs Event Counter)
```

**JEC States:**
- **Even (LSB = 0)**: "Sleepy" mode - no new work since last sleepy announcement
- **Odd (LSB = 1)**: "Active" mode - new work has been posted

### The Protocol

**When worker announces intent to sleep (Round 32):**
```zig
// Worker toggles JEC, then saves CURRENT value (not the old value!)
_ = self.counters.incrementJecIfSleepy();
idle.jobs_counter = AtomicCounters.extractJec(self.counters.loadSeqCst());
```

**Why save CURRENT, not old?** If we saved the old value (before toggle), the worker
that toggled JEC would immediately see "JEC changed" when comparing current JEC to
its snapshot—even though no new work arrived. This causes a "partial wake storm"
where workers never reach condvar sleep.

**When poster submits work:**
```zig
// Poster toggles JEC if even (to signal new work)
const old = self.counters.incrementJecIfSleepy();
// Now JEC is odd, sleeping workers will see the change
```

**Before worker actually sleeps:**
```zig
// Worker checks if JEC changed since announcement
const jec_now = AtomicCounters.extractJec(counters);
if (jec_now != idle.jobs_counter) {
    // New work arrived! Don't sleep, go back to looking
    return;
}
// Safe to sleep - JEC unchanged means no new work
```

### Why It Works

```
With JEC (SAFE):
  Worker A: JEC = odd (announce)    // Toggle if even
  Worker A: jec_snapshot = JEC      // Save CURRENT value (after toggle)
  Worker A: if (!hasWork) {         Poster B: postWork();
  Worker A:                         Poster B: JEC++ (toggle again)
  Worker A:   if (JEC != snapshot)  // JEC changed by poster!
  Worker A:     wake();             // Don't sleep, go find work
            }
```

The key insight: by saving JEC *after* toggling and checking it *before* sleeping,
the worker detects any work posted during the transition. Saving after toggle
prevents the worker from "seeing its own toggle" as a change.

## Progressive Sleep

Workers don't immediately sleep when idle. They progress through phases:

```
┌─────────────────────────────────────────────────────────────────┐
│                     Progressive Sleep Protocol                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Rounds 0-31: YIELD PHASE                                       │
│  ─────────────────────────                                      │
│  - Call std.Thread.yield() each round                           │
│  - Check for work between yields                                │
│  - Latency: ~1-5µs to find new work                             │
│  - CPU: Moderate (yields allow other threads to run)            │
│                                                                  │
│  Round 32: ANNOUNCE SLEEPY                                      │
│  ─────────────────────────                                      │
│  - Increment JEC if even (toggle to odd)                        │
│  - Save JEC snapshot for later comparison                       │
│  - One more yield                                               │
│                                                                  │
│  Round 33: PRE-SLEEP YIELD                                      │
│  ─────────────────────────                                      │
│  - Final yield before committing to sleep                       │
│  - Gives job posters one more chance                            │
│                                                                  │
│  Round 34+: ACTUAL SLEEP                                        │
│  ─────────────────────────                                      │
│  1. CAS latch UNSET → SLEEPY                                    │
│  2. Lock worker's mutex                                         │
│  3. CAS latch SLEEPY → SLEEPING                                 │
│  4. Check if JEC changed since snapshot                         │
│     - YES: Unlock, wakeUp(), go to round 32                     │
│  5. CAS to add self to sleeping_threads count                   │
│  6. SeqCst fence                                                │
│  7. Check for injected jobs (double-check pattern)              │
│  8. Block on condvar                                            │
│  9. On wake: wakeUp() latch, reset rounds to 0                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## CoreLatch: 4-State Protocol

Each worker has a CoreLatch to coordinate the sleep/wake handshake:

```
State Machine:

    UNSET (0) ──────────────────────────► SET (3)
        │                                    ▲
        │ getSleepy()                        │ set()
        ▼                                    │
    SLEEPY (1) ─────────────────────────► SET (3)
        │                                    ▲
        │ fallAsleep()                       │ set()
        ▼                                    │
    SLEEPING (2) ───────────────────────► SET (3)
        │
        │ wakeUp() [spurious]
        ▼
    UNSET (0)
```

**State meanings:**
- **UNSET (0)**: Worker is active, not trying to sleep
- **SLEEPY (1)**: Worker announced intent to sleep, doing final checks
- **SLEEPING (2)**: Worker is blocked on condvar
- **SET (3)**: Work has been assigned, worker should wake

**Why 4 states instead of 2?**

With just AWAKE/SLEEPING:
```
Worker: state = SLEEPING    Poster: if (state == SLEEPING) wake();
Worker: wait();             // Poster might not see SLEEPING yet!
```

With SLEEPY intermediate state:
```
Worker: state = SLEEPY      // Announce intent
Worker: final_check()       Poster: if (state >= SLEEPY) wake();
Worker: state = SLEEPING    // Poster sees SLEEPY, will wake
Worker: wait();
```

## Smart Wake Decisions

When new work arrives, the poster decides how many workers to wake:

```zig
fn newJobs(self: *Sleep, num_jobs: u32, queue_was_empty: bool) void {
    // Toggle JEC to signal new work
    const old = self.counters.incrementJecIfSleepy();
    const sleeping = extractSleeping(old);

    if (sleeping == 0) return;  // No one to wake

    const inactive = extractInactive(old);
    const awake_but_idle = inactive -| sleeping;  // Saturating subtract

    const num_to_wake: u32 = if (queue_was_empty) blk: {
        // Queue was empty - only wake if not enough idle workers
        if (awake_but_idle < num_jobs) {
            break :blk @min(num_jobs - awake_but_idle, sleeping);
        }
        break :blk 0;  // Idle workers will find work naturally
    } else blk: {
        // Queue had work - wake some to help clear backlog
        break :blk @min(num_jobs, sleeping);
    };

    self.wakeThreads(num_to_wake);
}
```

**Key insight**: If there are already idle workers (awake but polling), they will naturally find the new work. No need to wake sleeping workers just to have them compete with idle ones.

## SeqCst Fences

Two critical fences prevent races with injected jobs:

### Fence 1: When Injecting Jobs

```zig
pub fn newInjectedJobs(self: *Sleep, ...) void {
    seqCstFence();  // ◄── FENCE
    self.newJobs(...);
}
```

Ensures the injected job is visible before we read sleeping count.

### Fence 2: Before Sleeping

```zig
fn sleep(...) void {
    // ... register as sleeping ...
    seqCstFence();  // ◄── FENCE
    if (pool.hasInjectedJobs()) {
        // Work was injected, don't sleep
        return;
    }
    // Actually block
}
```

Ensures we see any jobs injected before we registered as sleeping.

**Why only for injected jobs?** Internal jobs (pushed to deques) don't need fences because:
- Deque operations use acquire/release semantics
- Thieves synchronize via CAS on deque.top
- The JEC protocol handles the sleep/wake race

## Critical Invariant: Waker Decrements

The thread that wakes a sleeping worker ALSO decrements `sleeping_threads`:

```zig
fn wakeSpecificThread(self: *Sleep, state: *WorkerSleepState) bool {
    state.mutex.lock();
    defer state.mutex.unlock();

    if (state.is_blocked) {
        state.is_blocked = false;
        state.condvar.signal();
        self.counters.subSleepingThread();  // Waker decrements!
        return true;
    }
    return false;
}
```

**Why?** If the sleeper decremented its own count:
1. Sleeper increments sleeping_count
2. Sleeper blocks
3. Poster sees sleeping_count > 0, decides to wake
4. Sleeper wakes, decrements sleeping_count
5. But what if step 4 happens before step 3 completes?

By having the waker decrement, we ensure the count is accurate.

## Performance Characteristics

| Scenario | Latency | CPU Usage |
|----------|---------|-----------|
| Work found in yield phase | ~1-5µs | Moderate |
| JEC detects new work | ~10µs | Low (avoided sleep) |
| Full sleep + wake | ~100-500µs | Near-zero while sleeping |

## Comparison with Alternatives

| Approach | Wake Latency | CPU While Idle | Complexity |
|----------|--------------|----------------|------------|
| Pure spin | ~10ns | 100% (burns CPU) | Simple |
| Mutex + condvar | ~100-300ns | Near-zero | Moderate |
| **JEC + condvar** | ~10-100µs | Near-zero | Complex |

Blitz uses JEC + condvar because:
- Low latency for bursty workloads (yield phase catches quick work)
- Near-zero CPU when truly idle (condvar sleep)
- No missed wakes (JEC protocol guarantees)

## References

1. Rayon sleep implementation: `rayon-core/src/sleep/mod.rs`
2. Rayon sleep protocol explanation: `rayon-core/src/sleep/README.md`
3. Blitz implementation: `pool.zig`
