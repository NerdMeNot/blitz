use rayon::prelude::*;
use std::time::Instant;

fn main() {
    rayon::ThreadPoolBuilder::new().num_threads(10).build_global().unwrap();
    
    let original: Vec<f64> = (0..1_000_000).map(|i| i as f64).collect();
    
    // Warmup
    for _ in 0..10 { 
        let mut d = original.clone(); 
        d.par_sort_unstable_by(|a, b| a.partial_cmp(b).unwrap()); 
    }
    
    // Benchmark
    let mut total = 0u128;
    for _ in 0..20 {
        let mut d = original.clone();
        let s = Instant::now();
        d.par_sort_unstable_by(|a, b| a.partial_cmp(b).unwrap());
        total += s.elapsed().as_nanos();
    }
    println!("Rayon sorted 1M (isolated): {:.2} ms", total as f64 / 20.0 / 1_000_000.0);
}
