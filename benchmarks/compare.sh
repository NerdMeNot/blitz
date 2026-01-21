#!/bin/bash
# Blitz vs Rayon Benchmark Comparison
# Outputs a formatted comparison table

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLITZ_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "                    Blitz vs Rayon Benchmark Comparison"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Check for jq
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required for JSON parsing. Install with: brew install jq"
    exit 1
fi

# Build Blitz benchmark
echo "Building Blitz benchmark..."
cd "$BLITZ_DIR"
zig build-exe -O ReleaseFast --dep blitz -Mroot=benchmarks/rayon_compare.zig -Mblitz=api.zig -lc 2>/dev/null || {
    echo "Error: Failed to build Blitz benchmark"
    exit 1
}

# Build Rayon benchmark
echo "Building Rayon benchmark..."
cd "$SCRIPT_DIR/rayon"
cargo build --release 2>/dev/null || {
    echo "Error: Failed to build Rayon benchmark"
    exit 1
}

echo ""
echo "Running benchmarks (10 workers, 5 warmup, 10 iterations each)..."
echo ""

# Run benchmarks and capture JSON
cd "$BLITZ_DIR"
BLITZ_JSON=$(./root 2>&1)
cd "$SCRIPT_DIR/rayon"
RAYON_JSON=$(./target/release/rayon_compare 2>&1)

# Parse JSON values using jq
get_value() {
    local json="$1"
    local key="$2"
    echo "$json" | jq -r ".[\"$key\"] // \"N/A\""
}

# Calculate ratio (Blitz/Rayon) - lower is better for Blitz
calc_ratio() {
    local blitz="$1"
    local rayon="$2"
    if [[ "$blitz" == "N/A" ]] || [[ "$rayon" == "N/A" ]] || [[ "$rayon" == "0" ]]; then
        echo "N/A"
    else
        awk "BEGIN {printf \"%.2f\", $blitz / $rayon}"
    fi
}

# Print a table row with proper alignment
# The ratio column needs special handling for ANSI colors
print_row() {
    local label="$1"
    local blitz="$2"
    local rayon="$3"
    local unit="$4"
    local ratio="$5"

    if [[ "$ratio" == "N/A" ]]; then
        printf "│ %-31s │ %11s │ %11s │     N/A     │\n" "$label" "N/A" "N/A"
        return
    fi

    local ratio_num=$(echo "$ratio" | awk '{print $1}')
    local color=""
    local indicator=""

    if (( $(echo "$ratio_num < 0.9" | bc -l) )); then
        color="$GREEN"
        indicator="▼"  # Blitz faster
    elif (( $(echo "$ratio_num > 1.1" | bc -l) )); then
        color="$RED"
        indicator="▲"  # Rayon faster
    else
        color="$YELLOW"
        indicator="●"  # Similar
    fi

    # Format values based on unit
    local blitz_fmt rayon_fmt
    case "$unit" in
        "ns")
            blitz_fmt=$(printf "%8.2f ns" "$blitz")
            rayon_fmt=$(printf "%8.2f ns" "$rayon")
            ;;
        "us")
            blitz_fmt=$(printf "%8.1f µs" "$blitz")
            rayon_fmt=$(printf "%8.1f µs" "$rayon")
            ;;
        "ms")
            blitz_fmt=$(printf "%8.2f ms" "$blitz")
            rayon_fmt=$(printf "%8.2f ms" "$rayon")
            ;;
    esac

    # Print with color - pad ratio to 5 chars, then add color codes around it
    printf "│ %-31s │ %11s │ %11s │ %b%5s%b %s │\n" \
        "$label" "$blitz_fmt" "$rayon_fmt" "$color" "${ratio}x" "$NC" "$indicator"
}

# Print table header
echo "┌─────────────────────────────────┬─────────────┬─────────────┬─────────────┐"
echo "│ Benchmark                       │    Blitz    │    Rayon    │   Ratio     │"
echo "├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤"

# Fork-Join benchmarks
for depth in 10 15 20; do
    key="fork_join_depth_$depth"
    blitz=$(get_value "$BLITZ_JSON" "$key")
    rayon=$(get_value "$RAYON_JSON" "$key")
    ratio=$(calc_ratio "$blitz" "$rayon")
    print_row "Fork-Join (depth=$depth)" "$blitz" "$rayon" "ns" "$ratio"
done

echo "├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤"

# Fibonacci benchmarks
for n in 35 40; do
    key="fib_${n}_par_ms"
    blitz=$(get_value "$BLITZ_JSON" "$key")
    rayon=$(get_value "$RAYON_JSON" "$key")
    ratio=$(calc_ratio "$blitz" "$rayon")
    print_row "Fibonacci $n (parallel)" "$blitz" "$rayon" "ms" "$ratio"

    key="fib_${n}_seq_ms"
    blitz=$(get_value "$BLITZ_JSON" "$key")
    rayon=$(get_value "$RAYON_JSON" "$key")
    ratio=$(calc_ratio "$blitz" "$rayon")
    print_row "Fibonacci $n (sequential)" "$blitz" "$rayon" "ms" "$ratio"
done

echo "├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤"

# Parallel Sum
for suffix in "par" "seq"; do
    key="sum_10m_${suffix}_ms"
    blitz=$(get_value "$BLITZ_JSON" "$key")
    rayon=$(get_value "$RAYON_JSON" "$key")
    ratio=$(calc_ratio "$blitz" "$rayon")
    print_row "Sum 10M ($suffix)" "$blitz" "$rayon" "ms" "$ratio"
done

echo "├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤"

# Sort benchmarks
for pattern in "random" "sorted" "reverse" "equal"; do
    key="sort_1m_${pattern}_ms"
    blitz=$(get_value "$BLITZ_JSON" "$key")
    rayon=$(get_value "$RAYON_JSON" "$key")
    ratio=$(calc_ratio "$blitz" "$rayon")
    print_row "Sort 1M ($pattern)" "$blitz" "$rayon" "ms" "$ratio"
done

echo "├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤"

# Find/Any/All benchmarks
key="find_10m_early_us"
blitz=$(get_value "$BLITZ_JSON" "$key")
rayon=$(get_value "$RAYON_JSON" "$key")
ratio=$(calc_ratio "$blitz" "$rayon")
print_row "Find 10M (early exit)" "$blitz" "$rayon" "us" "$ratio"

key="any_10m_early_us"
blitz=$(get_value "$BLITZ_JSON" "$key")
rayon=$(get_value "$RAYON_JSON" "$key")
ratio=$(calc_ratio "$blitz" "$rayon")
print_row "Any 10M (early exit)" "$blitz" "$rayon" "us" "$ratio"

key="any_10m_full_us"
blitz=$(get_value "$BLITZ_JSON" "$key")
rayon=$(get_value "$RAYON_JSON" "$key")
ratio=$(calc_ratio "$blitz" "$rayon")
print_row "Any 10M (full scan)" "$blitz" "$rayon" "us" "$ratio"

key="all_10m_pass_us"
blitz=$(get_value "$BLITZ_JSON" "$key")
rayon=$(get_value "$RAYON_JSON" "$key")
ratio=$(calc_ratio "$blitz" "$rayon")
print_row "All 10M (pass)" "$blitz" "$rayon" "us" "$ratio"

echo "├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤"

# Chunks
key="chunks_10m_1000_ms"
blitz=$(get_value "$BLITZ_JSON" "$key")
rayon=$(get_value "$RAYON_JSON" "$key")
ratio=$(calc_ratio "$blitz" "$rayon")
print_row "Chunks 10M (chunk=1000)" "$blitz" "$rayon" "ms" "$ratio"

echo "├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤"

# Min/Max by key
key="min_by_key_10m_us"
blitz=$(get_value "$BLITZ_JSON" "$key")
rayon=$(get_value "$RAYON_JSON" "$key")
ratio=$(calc_ratio "$blitz" "$rayon")
print_row "MinByKey 10M" "$blitz" "$rayon" "us" "$ratio"

key="max_by_key_10m_us"
blitz=$(get_value "$BLITZ_JSON" "$key")
rayon=$(get_value "$RAYON_JSON" "$key")
ratio=$(calc_ratio "$blitz" "$rayon")
print_row "MaxByKey 10M" "$blitz" "$rayon" "us" "$ratio"

echo "├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤"

# Position
key="position_10m_early_us"
blitz=$(get_value "$BLITZ_JSON" "$key")
rayon=$(get_value "$RAYON_JSON" "$key")
ratio=$(calc_ratio "$blitz" "$rayon")
print_row "Position 10M (early)" "$blitz" "$rayon" "us" "$ratio"

key="position_10m_mid_us"
blitz=$(get_value "$BLITZ_JSON" "$key")
rayon=$(get_value "$RAYON_JSON" "$key")
ratio=$(calc_ratio "$blitz" "$rayon")
print_row "Position 10M (middle)" "$blitz" "$rayon" "us" "$ratio"

echo "├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤"

# Enumerate
key="enumerate_10m_ms"
blitz=$(get_value "$BLITZ_JSON" "$key")
rayon=$(get_value "$RAYON_JSON" "$key")
ratio=$(calc_ratio "$blitz" "$rayon")
print_row "Enumerate 10M" "$blitz" "$rayon" "ms" "$ratio"

echo "├─────────────────────────────────┼─────────────┼─────────────┼─────────────┤"

# Chain/Zip/Flatten
key="chain_2x5m_ms"
blitz=$(get_value "$BLITZ_JSON" "$key")
rayon=$(get_value "$RAYON_JSON" "$key")
ratio=$(calc_ratio "$blitz" "$rayon")
print_row "Chain 2x5M" "$blitz" "$rayon" "ms" "$ratio"

key="zip_10m_ms"
blitz=$(get_value "$BLITZ_JSON" "$key")
rayon=$(get_value "$RAYON_JSON" "$key")
ratio=$(calc_ratio "$blitz" "$rayon")
print_row "Zip 10M" "$blitz" "$rayon" "ms" "$ratio"

key="flatten_1000x10k_ms"
blitz=$(get_value "$BLITZ_JSON" "$key")
rayon=$(get_value "$RAYON_JSON" "$key")
ratio=$(calc_ratio "$blitz" "$rayon")
print_row "Flatten 1000x10K" "$blitz" "$rayon" "ms" "$ratio"

echo "└─────────────────────────────────┴─────────────┴─────────────┴─────────────┘"
echo ""
echo -e "Legend: ${GREEN}▼ Green${NC} = Blitz faster (<0.9x)  ${RED}▲ Red${NC} = Rayon faster (>1.1x)  ${YELLOW}● Yellow${NC} = Similar"
echo "Ratio: Blitz time / Rayon time (lower is better for Blitz)"
echo ""
