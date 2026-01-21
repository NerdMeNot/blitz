#!/bin/bash
# Blitz vs Rayon Comparison Benchmark Runner
#
# This script builds and runs both the Blitz and Rayon benchmarks
# side-by-side for easy comparison.
#
# Usage: ./run_comparison.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================================="
echo "Building Blitz benchmark..."
echo "=============================================================="
cd "$SCRIPT_DIR/.."
zig build-exe -O ReleaseFast -lc -femit-bin=benchmarks/blitz_bench --dep blitz -Mroot=benchmarks/rayon_compare.zig -Mblitz=api.zig 2>&1 || {
    echo "Failed to build Blitz benchmark"
    exit 1
}

echo ""
echo "=============================================================="
echo "Building Rayon benchmark..."
echo "=============================================================="
cd benchmarks/rayon
cargo build --release 2>&1 || {
    echo "Failed to build Rayon benchmark"
    exit 1
}
cd ../..

echo ""
echo ""
echo "=============================================================="
echo "                    BLITZ BENCHMARK"
echo "=============================================================="
echo ""
./benchmarks/blitz_bench

echo ""
echo ""
echo "=============================================================="
echo "                    RAYON BENCHMARK"
echo "=============================================================="
echo ""
./benchmarks/rayon/target/release/rayon_compare

echo ""
echo ""
echo "=============================================================="
echo "                    COMPARISON COMPLETE"
echo "=============================================================="
echo ""
echo "Both benchmarks have been run. Compare the results above."
echo ""
