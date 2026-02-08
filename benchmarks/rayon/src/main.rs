//! Rayon Comparison Benchmarks - JSON Output
//!
//! Outputs JSON for easy comparison with Blitz benchmarks.

use rayon::prelude::*;
use std::time::Instant;

#[cfg(unix)]
fn get_resource_usage() -> (i64, i64, i64) {
    use std::mem::MaybeUninit;

    let mut rusage = MaybeUninit::<libc::rusage>::uninit();
    unsafe {
        libc::getrusage(libc::RUSAGE_SELF, rusage.as_mut_ptr());
        let ru = rusage.assume_init();
        // macOS reports maxrss in bytes, Linux in KB
        #[cfg(target_os = "macos")]
        let peak_kb = ru.ru_maxrss / 1024;
        #[cfg(not(target_os = "macos"))]
        let peak_kb = ru.ru_maxrss;

        (peak_kb, ru.ru_nvcsw, ru.ru_nivcsw)
    }
}

#[cfg(not(unix))]
fn get_resource_usage() -> (i64, i64, i64) {
    (0, 0, 0)
}

const NUM_WORKERS: usize = 10;
const WARMUP_ITERATIONS: usize = 5;
const BENCHMARK_ITERATIONS: usize = 10;

fn benchmark<T, F: FnMut() -> T>(mut func: F) -> u64 {
    // Warmup
    for _ in 0..WARMUP_ITERATIONS {
        std::hint::black_box(func());
    }

    // Measure
    let mut total = 0u64;
    for _ in 0..BENCHMARK_ITERATIONS {
        let start = Instant::now();
        std::hint::black_box(func());
        total += start.elapsed().as_nanos() as u64;
    }

    total / BENCHMARK_ITERATIONS as u64
}

// Fork-Join
fn recursive_join(depth: usize) -> usize {
    if depth == 0 {
        return 1;
    }
    let (a, b) = rayon::join(
        || recursive_join(depth - 1),
        || recursive_join(depth - 1),
    );
    a + b
}

// Fibonacci
#[inline(never)]
fn fib_seq_inner(n: u64) -> u64 {
    if n <= 1 { return n; }
    fib_seq_inner(std::hint::black_box(n - 1)) + fib_seq_inner(std::hint::black_box(n - 2))
}

fn fib_seq(n: u64) -> u64 {
    fib_seq_inner(std::hint::black_box(n))
}

fn fib_par(n: u64) -> u64 {
    if n <= 20 { return fib_seq(n); }
    let (a, b) = rayon::join(|| fib_par(n - 2), || fib_par(n - 1));
    a + b
}

fn main() {
    rayon::ThreadPoolBuilder::new()
        .num_threads(NUM_WORKERS)
        .build_global()
        .unwrap();

    // System warmup - exercise thread pool before benchmarks
    // This ensures all worker threads are spawned and caches are hot
    {
        // Warmup with fork-join to spawn all threads
        for _ in 0..10 {
            std::hint::black_box(recursive_join(15));
        }
        // Warmup with parallel sum
        let warmup_data: Vec<f64> = (0..1_000_000).map(|i| i as f64).collect();
        for _ in 0..5 {
            let sum: f64 = warmup_data.par_iter().sum();
            std::hint::black_box(sum);
        }
    }

    // Snapshot resource usage after warmup to measure only benchmark portion
    let (_, nvcsw_before, nivcsw_before) = get_resource_usage();

    let mut first = true;
    let mut emit = |key: &str, value: f64| {
        if !first { print!(",\n"); }
        first = false;
        print!("  \"{}\": {:.2}", key, value);
    };

    println!("{{");

    // Fork-Join Overhead
    {
        let ns = benchmark(|| recursive_join(10));
        let num_forks: u64 = (1 << 11) - 1;
        emit("fork_join_depth_10", ns as f64 / num_forks as f64);

        let ns15 = benchmark(|| recursive_join(15));
        let num_forks15: u64 = (1 << 16) - 1;
        emit("fork_join_depth_15", ns15 as f64 / num_forks15 as f64);

        let ns20 = benchmark(|| recursive_join(20));
        let num_forks20: u64 = (1 << 21) - 1;
        emit("fork_join_depth_20", ns20 as f64 / num_forks20 as f64);
    }

    // Fibonacci
    {
        emit("fib_35_par_ms", benchmark(|| fib_par(35)) as f64 / 1_000_000.0);
        emit("fib_35_seq_ms", benchmark(|| fib_seq(35)) as f64 / 1_000_000.0);
        emit("fib_40_par_ms", benchmark(|| fib_par(40)) as f64 / 1_000_000.0);
        emit("fib_40_seq_ms", benchmark(|| fib_seq(40)) as f64 / 1_000_000.0);
    }

    // Parallel Sum
    {
        let data: Vec<f64> = (0..10_000_000).map(|i| (i % 1000) as f64).collect();

        emit("sum_10m_par_ms", benchmark(|| data.par_iter().sum::<f64>()) as f64 / 1_000_000.0);
        emit("sum_10m_seq_ms", benchmark(|| data.iter().sum::<f64>()) as f64 / 1_000_000.0);
    }

    // PDQSort
    {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        fn seeded_random(seed: u64, i: usize) -> f64 {
            let mut hasher = DefaultHasher::new();
            seed.hash(&mut hasher);
            i.hash(&mut hasher);
            (hasher.finish() as f64) / (u64::MAX as f64)
        }

        let original: Vec<f64> = (0..1_000_000).map(|i| seeded_random(12345, i)).collect();

        // Random
        let random_ns = {
            let mut total = 0u64;
            for _ in 0..WARMUP_ITERATIONS {
                let mut data = original.clone();
                data.par_sort_unstable_by(|a, b| a.partial_cmp(b).unwrap());
            }
            for _ in 0..BENCHMARK_ITERATIONS {
                let mut data = original.clone();
                let start = Instant::now();
                data.par_sort_unstable_by(|a, b| a.partial_cmp(b).unwrap());
                total += start.elapsed().as_nanos() as u64;
            }
            total / BENCHMARK_ITERATIONS as u64
        };
        emit("sort_1m_random_ms", random_ns as f64 / 1_000_000.0);

        // Sorted
        let sorted: Vec<f64> = (0..1_000_000).map(|i| i as f64).collect();
        let sorted_ns = {
            let mut total = 0u64;
            for _ in 0..WARMUP_ITERATIONS {
                let mut data = sorted.clone();
                data.par_sort_unstable_by(|a, b| a.partial_cmp(b).unwrap());
            }
            for _ in 0..BENCHMARK_ITERATIONS {
                let mut data = sorted.clone();
                let start = Instant::now();
                data.par_sort_unstable_by(|a, b| a.partial_cmp(b).unwrap());
                total += start.elapsed().as_nanos() as u64;
            }
            total / BENCHMARK_ITERATIONS as u64
        };
        emit("sort_1m_sorted_ms", sorted_ns as f64 / 1_000_000.0);

        // Reverse
        let reverse: Vec<f64> = (0..1_000_000).map(|i| (1_000_000 - i) as f64).collect();
        let reverse_ns = {
            let mut total = 0u64;
            for _ in 0..WARMUP_ITERATIONS {
                let mut data = reverse.clone();
                data.par_sort_unstable_by(|a, b| a.partial_cmp(b).unwrap());
            }
            for _ in 0..BENCHMARK_ITERATIONS {
                let mut data = reverse.clone();
                let start = Instant::now();
                data.par_sort_unstable_by(|a, b| a.partial_cmp(b).unwrap());
                total += start.elapsed().as_nanos() as u64;
            }
            total / BENCHMARK_ITERATIONS as u64
        };
        emit("sort_1m_reverse_ms", reverse_ns as f64 / 1_000_000.0);

        // Equal
        let equal: Vec<f64> = vec![42.0; 1_000_000];
        let equal_ns = {
            let mut total = 0u64;
            for _ in 0..WARMUP_ITERATIONS {
                let mut data = equal.clone();
                data.par_sort_unstable_by(|a, b| a.partial_cmp(b).unwrap());
            }
            for _ in 0..BENCHMARK_ITERATIONS {
                let mut data = equal.clone();
                let start = Instant::now();
                data.par_sort_unstable_by(|a, b| a.partial_cmp(b).unwrap());
                total += start.elapsed().as_nanos() as u64;
            }
            total / BENCHMARK_ITERATIONS as u64
        };
        emit("sort_1m_equal_ms", equal_ns as f64 / 1_000_000.0);
    }

    // Find/Any/All
    {
        let data: Vec<i64> = (0..10_000_000).map(|i| i as i64).collect();

        emit("find_10m_early_us", benchmark(|| data.par_iter().find_any(|&&x| x == 100)) as f64 / 1000.0);
        emit("any_10m_early_us", benchmark(|| data.par_iter().any(|&x| x > 100)) as f64 / 1000.0);
        emit("any_10m_full_us", benchmark(|| data.par_iter().any(|&x| x > 99999999)) as f64 / 1000.0);
        emit("all_10m_pass_us", benchmark(|| data.par_iter().all(|&x| x < 99999999)) as f64 / 1000.0);

        emit("chunks_10m_1000_ms", benchmark(|| {
            data.par_chunks(1000)
                .map(|chunk| chunk.iter().sum::<i64>())
                .sum::<i64>()
        }) as f64 / 1_000_000.0);

        // Min/Max by Key
        emit("min_by_key_10m_us", benchmark(|| {
            data.par_iter().min_by_key(|&x| {
                let mid: i64 = 5_000_000;
                let diff = x - mid;
                if diff < 0 { -diff } else { diff }
            })
        }) as f64 / 1000.0);

        emit("max_by_key_10m_us", benchmark(|| {
            data.par_iter().max_by_key(|&x| *x)
        }) as f64 / 1000.0);

        // Position
        emit("position_10m_early_us", benchmark(|| {
            data.par_iter().position_any(|&x| x == 100)
        }) as f64 / 1000.0);

        emit("position_10m_mid_us", benchmark(|| {
            data.par_iter().position_any(|&x| x == 5_000_000)
        }) as f64 / 1000.0);

        // Enumerate
        emit("enumerate_10m_ms", benchmark(|| {
            data.par_iter().enumerate().for_each(|(_idx, _val)| {
                // Just iterate - measuring overhead
            })
        }) as f64 / 1_000_000.0);
    }

    // Chain/Zip/Flatten
    {
        let data1: Vec<i64> = (0..5_000_000).map(|i| i as i64).collect();
        let data2: Vec<i64> = (0..5_000_000).map(|i| i as i64).collect();

        // Chain
        emit("chain_2x5m_ms", benchmark(|| {
            data1.par_iter().chain(data2.par_iter()).sum::<i64>()
        }) as f64 / 1_000_000.0);

        // Zip
        emit("zip_10m_ms", benchmark(|| {
            data1.par_iter().zip(data2.par_iter())
                .map(|(&a, &b)| a * b)
                .sum::<i64>()
        }) as f64 / 1_000_000.0);

        // Flatten: 1000 chunks of 10000 elements
        let chunks: Vec<Vec<i64>> = (0..1000)
            .map(|chunk_idx| {
                (0..10_000).map(|i| (chunk_idx * 10_000 + i) as i64).collect()
            })
            .collect();

        emit("flatten_1000x10k_ms", benchmark(|| {
            chunks.par_iter().flatten().sum::<i64>()
        }) as f64 / 1_000_000.0);
    }

    // Resource usage (delta: benchmark portion only, excludes startup/warmup)
    {
        let (peak_kb, nvcsw_after, nivcsw_after) = get_resource_usage();
        emit("peak_memory_kb", peak_kb as f64); // Peak is cumulative, not delta
        emit("voluntary_ctx_switches", (nvcsw_after - nvcsw_before) as f64);
        emit("involuntary_ctx_switches", (nivcsw_after - nivcsw_before) as f64);
    }

    println!("\n}}");
}
